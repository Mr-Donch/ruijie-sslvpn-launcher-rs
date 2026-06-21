use anyhow::{Context, Result, anyhow, bail};
use chrono::Local;
use clap::{Parser, Subcommand};
use ruijie_sslvpn_launcher_rs::{
    AdapterSnapshot, AppConfig, TriggerKind, build_elevated_args, dns_needs_fix,
    ext_route_looks_connected, resolve_config_path, trigger_can_fix_dns,
};
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Instant, SystemTime};
use windows_sys::Win32::Foundation::HWND;
use windows_sys::Win32::UI::Shell::ShellExecuteW;
use windows_sys::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;

#[derive(Debug, Parser)]
#[command(
    version,
    about = "Launch RuiJie SSLVPN and fix its virtual adapter DNS"
)]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,

    #[arg(long, default_value = "ruijie-sslvpn-launcher-rs.toml", global = true)]
    config: PathBuf,

    #[arg(long)]
    no_start: bool,

    #[arg(long = "dns")]
    preferred_dns: Vec<String>,

    #[arg(long)]
    allow_adapter_fallback: bool,

    #[arg(long)]
    timeout_seconds: Option<u64>,

    #[arg(long)]
    dry_run: bool,

    #[arg(long)]
    yes: bool,

    #[arg(long)]
    no_elevate: bool,
}

#[derive(Debug, Subcommand)]
enum Commands {
    Run,
    InitConfig {
        #[arg(long)]
        force: bool,
    },
    PrintConfig,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct FileState {
    exists: bool,
    modified: Option<SystemTime>,
    len: u64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_arg_can_be_used_after_print_config_subcommand() {
        let cli = Cli::try_parse_from([
            "launcher",
            "print-config",
            "--config",
            r"C:\tools\ruijie\config.toml",
        ])
        .expect("cli should parse");

        assert_eq!(cli.config, PathBuf::from(r"C:\tools\ruijie\config.toml"));
        assert!(matches!(cli.command, Some(Commands::PrintConfig)));
    }
}

fn main() {
    let mut cli = Cli::parse();
    if let Ok(resolved_config) = default_resolved_config_path(&cli.config) {
        cli.config = resolved_config;
    }
    let result = match cli.command.as_ref().unwrap_or(&Commands::Run) {
        Commands::Run => run(&cli),
        Commands::InitConfig { force } => init_config(&cli.config, *force),
        Commands::PrintConfig => print_config(&cli),
    };

    if let Err(err) = result {
        eprintln!("ERROR: {err:?}");
        if should_pause_on_error(&cli.config) {
            pause("Press Enter to exit...");
        }
        std::process::exit(1);
    }
}

fn default_resolved_config_path(requested: &Path) -> Result<PathBuf> {
    let current_dir = std::env::current_dir().context("failed to get current directory")?;
    let exe = std::env::current_exe().context("failed to get current executable path")?;
    let exe_dir = exe.parent().unwrap_or_else(|| Path::new("."));
    Ok(resolve_config_path(requested, &current_dir, exe_dir))
}

fn run(cli: &Cli) -> Result<()> {
    let config_base_dir = config_base_dir(&cli.config)?;
    let mut cfg = load_or_default_config(&cli.config)?;
    cfg.resolve_paths(&config_base_dir);
    apply_overrides(&mut cfg, cli);

    if !is_elevated()? {
        if cfg.auto_elevate && !cli.no_elevate {
            println!("Requesting administrator privileges via UAC...");
            relaunch_elevated()?;
            return Ok(());
        }

        bail!("Run as administrator. DNS changes require elevated privileges.");
    }

    let mut logger = Logger::new(&cfg.log_path)?;

    logger.info("launcher started")?;
    logger.info(&format!("config path: {}", cli.config.display()))?;
    logger.info(&format!("preferred dns: {}", cfg.preferred_dns.join(",")))?;

    validate_config(&cfg)?;

    if cfg.start_vpn && detect_existing_vpn_process(&cfg.vpn_process_name)? {
        logger.info(&format!(
            "detected existing SSLVPN process: {}",
            cfg.vpn_process_name
        ))?;
        if !cli.yes
            && !ask_yes_no(
                &format!(
                    "SSLVPN is already running (process: {}). Fix DNS now?",
                    cfg.vpn_process_name
                ),
            )?
        {
            logger.info("user declined immediate DNS fix; exiting")?;
            return Ok(());
        }

        logger.info("user confirmed immediate DNS fix")?;
        if try_fix_dns(&cfg, &mut logger, cli.dry_run)? {
            logger.info("completed successfully")?;
            if cfg.pause_on_success {
                pause("DNS fixed. Press Enter to exit...");
            }
        } else {
            logger.warn("immediate DNS fix failed")?;
            if cfg.pause_on_error {
                pause("DNS fix failed. Press Enter to exit...");
            }
        }
        return Ok(());
    }

    if cfg.start_vpn {
        start_vpn(&cfg, &mut logger)?;
    } else {
        logger.info("start_vpn=false; monitoring existing SSLVPN session")?;
    }

    let mut ext_route_state = file_state(&cfg.ext_route_path);
    let deadline = Instant::now() + cfg.timeout();
    logger.info(&format!(
        "monitoring ext_route={} timeout={}s allow_adapter_fallback={}",
        cfg.ext_route_path.display(),
        cfg.timeout_seconds,
        cfg.allow_adapter_fallback
    ))?;

    while Instant::now() < deadline {
        let mut trigger: Option<(TriggerKind, String)> = None;
        let new_state = file_state(&cfg.ext_route_path);

        if ext_route_changed(&ext_route_state, &new_state) {
            match fs::read_to_string(&cfg.ext_route_path) {
                Ok(content) if ext_route_looks_connected(&content) => {
                    trigger = Some((
                        TriggerKind::ExtRoute,
                        "ext_route updated and contains VPN routes".to_string(),
                    ));
                }
                Ok(_) => {
                    logger.warn("ext_route changed but content does not look connected")?;
                    if cfg.confirm_uncertain
                        && !cli.yes
                        && ask_yes_no(
                            "ext_route changed but content is uncertain. Try fixing DNS?",
                        )?
                    {
                        trigger = Some((TriggerKind::ExtRoute, "manual confirmation".to_string()));
                    }
                }
                Err(err) => {
                    logger.warn(&format!("failed to read ext_route: {err}"))?;
                }
            }
        }
        ext_route_state = new_state;

        if trigger.is_none() && cfg.allow_adapter_fallback {
            let adapter = get_adapter_snapshot().context("failed to query SSLVPN adapter")?;
            if adapter.is_connected() && dns_needs_fix(&adapter.dns_servers, &cfg.preferred_dns) {
                trigger = Some((
                    TriggerKind::Adapter,
                    format!("adapter connected: {}", adapter.interface_alias),
                ));
            }
        }

        if let Some((kind, reason)) = trigger {
            logger.info(&format!("trigger detected: {reason}"))?;
            if !trigger_can_fix_dns(kind, cfg.allow_adapter_fallback) {
                logger.info("trigger is diagnostic only; continuing")?;
                thread::sleep(cfg.poll_interval());
                continue;
            }

            if try_fix_dns(&cfg, &mut logger, cli.dry_run)? {
                logger.info("completed successfully")?;
                if cfg.pause_on_success {
                    pause("DNS fixed. Press Enter to exit...");
                }
                return Ok(());
            }

            logger.warn("trigger was too early or DNS fix failed; continuing to monitor")?;
        }

        thread::sleep(cfg.poll_interval());
    }

    bail!(
        "Timed out after {} seconds waiting for SSLVPN connection.",
        cfg.timeout_seconds
    )
}

fn init_config(path: &Path, force: bool) -> Result<()> {
    if path.exists() && !force {
        bail!(
            "config already exists: {}. Use --force to overwrite.",
            path.display()
        );
    }

    let cfg = AppConfig::default();
    let text = toml::to_string_pretty(&cfg).context("failed to serialize default config")?;
    fs::write(path, text).with_context(|| format!("failed to write {}", path.display()))?;
    println!("Wrote config: {}", path.display());
    Ok(())
}

fn print_config(cli: &Cli) -> Result<()> {
    let config_base_dir = config_base_dir(&cli.config)?;
    let mut cfg = load_or_default_config(&cli.config)?;
    cfg.resolve_paths(&config_base_dir);
    apply_overrides(&mut cfg, cli);
    println!("{}", toml::to_string_pretty(&cfg)?);
    Ok(())
}

fn config_base_dir(config_path: &Path) -> Result<PathBuf> {
    if let Some(parent) = config_path.parent()
        && !parent.as_os_str().is_empty()
    {
        return Ok(parent.to_path_buf());
    }

    std::env::current_dir().context("failed to get current directory for config base")
}

fn load_or_default_config(path: &Path) -> Result<AppConfig> {
    if !path.exists() {
        return Ok(AppConfig::default());
    }

    let text =
        fs::read_to_string(path).with_context(|| format!("failed to read {}", path.display()))?;
    toml::from_str(&text).with_context(|| format!("failed to parse {}", path.display()))
}

fn apply_overrides(cfg: &mut AppConfig, cli: &Cli) {
    if cli.no_start {
        cfg.start_vpn = false;
    }
    if !cli.preferred_dns.is_empty() {
        cfg.preferred_dns = cli.preferred_dns.clone();
    }
    if cli.allow_adapter_fallback {
        cfg.allow_adapter_fallback = true;
    }
    if let Some(timeout) = cli.timeout_seconds {
        cfg.timeout_seconds = timeout;
    }
}

fn validate_config(cfg: &AppConfig) -> Result<()> {
    if cfg.start_vpn && !cfg.vpn_exe_path.exists() {
        bail!(
            "SSLVPN executable not found: {}",
            cfg.vpn_exe_path.display()
        );
    }
    if !cfg.cleaner_script_path.exists() {
        bail!(
            "cleaner script not found: {}",
            cfg.cleaner_script_path.display()
        );
    }
    if cfg.preferred_dns.is_empty() {
        bail!("preferred_dns must contain at least one DNS server");
    }
    Ok(())
}

fn start_vpn(cfg: &AppConfig, logger: &mut Logger) -> Result<()> {
    logger.info(&format!("starting SSLVPN: {}", cfg.vpn_exe_path.display()))?;
    let working_dir = cfg
        .vpn_exe_path
        .parent()
        .ok_or_else(|| anyhow!("invalid vpn_exe_path: {}", cfg.vpn_exe_path.display()))?;

    Command::new(&cfg.vpn_exe_path)
        .current_dir(working_dir)
        .spawn()
        .with_context(|| format!("failed to start {}", cfg.vpn_exe_path.display()))?;

    Ok(())
}

fn detect_existing_vpn_process(process_name: &str) -> Result<bool> {
    let name = process_name.trim();
    if name.is_empty() {
        return Ok(false);
    }

    let name = name.strip_suffix(".exe").unwrap_or(name);

    let output = Command::new("powershell")
        .args([
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            &format!(
                "(Get-Process -Name '{}' -ErrorAction SilentlyContinue | Measure-Object).Count",
                name.replace('\'', "''")
            ),
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .context("failed to query existing VPN process")?;

    if !output.status.success() {
        return Ok(false);
    }

    let count = String::from_utf8_lossy(&output.stdout)
        .trim()
        .parse::<u32>()
        .unwrap_or(0);

    Ok(count > 0)
}

fn file_state(path: &Path) -> FileState {
    match fs::metadata(path) {
        Ok(metadata) => FileState {
            exists: true,
            modified: metadata.modified().ok(),
            len: metadata.len(),
        },
        Err(_) => FileState {
            exists: false,
            modified: None,
            len: 0,
        },
    }
}

fn ext_route_changed(old: &FileState, new: &FileState) -> bool {
    new.exists && (!old.exists || old.modified != new.modified || old.len != new.len)
}

fn get_adapter_snapshot() -> Result<AdapterSnapshot> {
    let script = r#"
$vpn = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
  Where-Object { $_.InterfaceDescription -eq 'RuiJie SSLVPN Virtual Network Card' } |
  Select-Object -First 1
if (-not $vpn) {
  [pscustomobject]@{ Found = $false; Status = '<missing>'; InterfaceAlias = ''; IPv4 = @(); DnsServers = @() } | ConvertTo-Json -Compress
  exit 0
}
$ipv4 = @(Get-NetIPAddress -InterfaceIndex $vpn.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object { $_.IPAddress -notlike '169.254.*' } |
  Select-Object -ExpandProperty IPAddress)
$dns = @(Get-DnsClientServerAddress -InterfaceIndex $vpn.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Select-Object -ExpandProperty ServerAddresses)
[pscustomobject]@{
  Found = $true
  Status = $vpn.Status.ToString()
  InterfaceAlias = $vpn.Name
  IPv4 = $ipv4
  DnsServers = $dns
} | ConvertTo-Json -Compress
"#;

    let output = Command::new("powershell")
        .args([
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            script,
        ])
        .output()
        .context("failed to run PowerShell adapter query")?;

    if !output.status.success() {
        bail!(
            "adapter query failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    serde_json::from_str(stdout.trim()).context("failed to parse adapter query JSON")
}

fn try_fix_dns(cfg: &AppConfig, logger: &mut Logger, dry_run: bool) -> Result<bool> {
    let wanted = cfg.preferred_dns.join(",");

    for attempt in 1..=cfg.max_fix_attempts {
        thread::sleep(cfg.fix_delay());

        let snapshot = get_adapter_snapshot().context("failed to query adapter before DNS fix")?;
        if !snapshot.found {
            logger.warn(&format!(
                "DNS fix attempt {attempt} skipped: adapter not found"
            ))?;
            continue;
        }
        if !snapshot.is_connected() {
            logger.warn(&format!(
                "DNS fix attempt {attempt} skipped: adapter status={} ipv4={:?}",
                snapshot.status, snapshot.ipv4
            ))?;
            continue;
        }
        if !dns_needs_fix(&snapshot.dns_servers, &cfg.preferred_dns) {
            logger.info(&format!("DNS already set to {wanted}"))?;
            return Ok(true);
        }

        logger.info(&format!(
            "DNS fix attempt {attempt}: current={} target={wanted}",
            snapshot.dns_servers.join(",")
        ))?;

        if dry_run {
            logger.info("dry-run enabled; not changing DNS")?;
            return Ok(true);
        }

        let status = Command::new("powershell")
            .arg("-NoProfile")
            .arg("-ExecutionPolicy")
            .arg("Bypass")
            .arg("-File")
            .arg(&cfg.cleaner_script_path)
            .arg("-Action")
            .arg("set")
            .arg("-ServerAddresses")
            .args(&cfg.preferred_dns)
            .status()
            .context("failed to run cleaner script")?;

        if !status.success() {
            logger.warn(&format!("cleaner exit code: {status}"))?;
            continue;
        }

        let after = get_adapter_snapshot().context("failed to query adapter after DNS fix")?;
        if !dns_needs_fix(&after.dns_servers, &cfg.preferred_dns) {
            logger.info(&format!("DNS fixed to {wanted}"))?;
            return Ok(true);
        }

        logger.warn(&format!(
            "DNS fix attempt {attempt} did not stick: current={} target={wanted}",
            after.dns_servers.join(",")
        ))?;
    }

    Ok(false)
}

fn is_elevated() -> Result<bool> {
    let output = Command::new("powershell")
        .args([
            "-NoProfile",
            "-Command",
            "([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)",
        ])
        .stdout(Stdio::piped())
        .output()
        .context("failed to check administrator privileges")?;

    Ok(String::from_utf8_lossy(&output.stdout)
        .trim()
        .eq_ignore_ascii_case("True"))
}

fn relaunch_elevated() -> Result<()> {
    let exe = std::env::current_exe().context("failed to get current executable path")?;
    let args = std::env::args().collect::<Vec<_>>();
    let params = build_elevated_args(&args);

    let exe_wide = to_wide_null(exe.as_os_str().to_string_lossy().as_ref());
    let params_wide = to_wide_null(&params);
    let runas_wide = to_wide_null("runas");

    let result = unsafe {
        ShellExecuteW(
            0 as HWND,
            runas_wide.as_ptr(),
            exe_wide.as_ptr(),
            params_wide.as_ptr(),
            std::ptr::null(),
            SW_SHOWNORMAL,
        )
    };

    if result as isize <= 32 {
        bail!("failed to request administrator privileges; ShellExecuteW returned {result:?}");
    }

    Ok(())
}

fn to_wide_null(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

fn ask_yes_no(prompt: &str) -> Result<bool> {
    print!("{prompt} [y/N] ");
    io::stdout().flush()?;

    let mut input = String::new();
    io::stdin().read_line(&mut input)?;
    Ok(matches!(
        input.trim().to_ascii_lowercase().as_str(),
        "y" | "yes"
    ))
}

fn pause(prompt: &str) {
    eprintln!("{prompt}");
    let mut input = String::new();
    let _ = io::stdin().read_line(&mut input);
}

fn should_pause_on_error(config_path: &Path) -> bool {
    load_or_default_config(config_path)
        .map(|cfg| cfg.pause_on_error)
        .unwrap_or(true)
}

struct Logger {
    path: PathBuf,
}

impl Logger {
    fn new(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("failed to create log directory {}", parent.display()))?;
        }
        Ok(Self {
            path: path.to_path_buf(),
        })
    }

    fn info(&mut self, message: &str) -> Result<()> {
        self.write("INFO", message)
    }

    fn warn(&mut self, message: &str) -> Result<()> {
        self.write("WARN", message)
    }

    fn write(&mut self, level: &str, message: &str) -> Result<()> {
        let line = format!(
            "{} [{level}] {message}\n",
            Local::now().format("%Y-%m-%dT%H:%M:%S")
        );
        print!("{line}");
        OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)
            .with_context(|| format!("failed to open log file {}", self.path.display()))?
            .write_all(line.as_bytes())
            .context("failed to write log")
    }
}
