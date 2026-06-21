use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::Duration;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AppConfig {
    pub vpn_exe_path: PathBuf,
    pub vpn_process_name: String,
    pub ext_route_path: PathBuf,
    pub sslvpn_log_dir: PathBuf,
    pub client_log_path: PathBuf,
    pub cleaner_script_path: PathBuf,
    pub preferred_dns: Vec<String>,
    pub timeout_seconds: u64,
    pub poll_interval_ms: u64,
    pub fix_delay_ms: u64,
    pub max_fix_attempts: u32,
    pub start_vpn: bool,
    pub allow_adapter_fallback: bool,
    pub confirm_uncertain: bool,
    pub pause_on_error: bool,
    pub pause_on_success: bool,
    pub auto_elevate: bool,
    pub log_path: PathBuf,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            vpn_exe_path: PathBuf::from(r"C:\Program Files\RG-SSLVPN\RG-SSLVPN.exe"),
            vpn_process_name: "RG-SSLVPN".to_string(),
            ext_route_path: PathBuf::from(r"C:\Program Files\RG-SSLVPN\ext_route"),
            sslvpn_log_dir: PathBuf::from(r"C:\Program Files\RG-SSLVPN\log"),
            client_log_path: PathBuf::from(r"C:\Program Files\RG SSL VPN Client\SslVpnWin.log"),
            cleaner_script_path: PathBuf::from("scripts/clear-ruijie-sslvpn-dns.ps1"),
            preferred_dns: vec!["114.114.114.114".to_string()],
            timeout_seconds: 120,
            poll_interval_ms: 500,
            fix_delay_ms: 800,
            max_fix_attempts: 3,
            start_vpn: true,
            allow_adapter_fallback: false,
            confirm_uncertain: true,
            pause_on_error: true,
            pause_on_success: false,
            auto_elevate: true,
            log_path: PathBuf::from("log/ruijie-sslvpn-launcher-rs.log"),
        }
    }
}

impl AppConfig {
    pub fn timeout(&self) -> Duration {
        Duration::from_secs(self.timeout_seconds)
    }

    pub fn poll_interval(&self) -> Duration {
        Duration::from_millis(self.poll_interval_ms)
    }

    pub fn fix_delay(&self) -> Duration {
        Duration::from_millis(self.fix_delay_ms)
    }

    pub fn resolve_paths(&mut self, base_dir: &Path) {
        self.cleaner_script_path = resolve_relative_path(base_dir, &self.cleaner_script_path);
        self.log_path = resolve_relative_path(base_dir, &self.log_path);
    }
}

pub fn resolve_relative_path(base_dir: &Path, path: &Path) -> PathBuf {
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        base_dir.join(path)
    }
}

pub fn quote_windows_arg(arg: &str) -> String {
    if arg.is_empty() || arg.chars().any(|ch| ch.is_whitespace() || ch == '"') {
        let escaped = arg.replace('"', "\\\"");
        format!("\"{escaped}\"")
    } else {
        arg.to_string()
    }
}

pub fn build_elevated_args(args: &[String]) -> String {
    args.iter()
        .skip(1)
        .map(|arg| quote_windows_arg(arg))
        .collect::<Vec<_>>()
        .join(" ")
}

pub fn resolve_config_path(requested: &Path, current_dir: &Path, exe_dir: &Path) -> PathBuf {
    if requested.is_absolute() {
        return requested.to_path_buf();
    }

    let cwd_path = current_dir.join(requested);
    if cwd_path.exists() {
        return cwd_path;
    }

    let exe_path = exe_dir.join(requested);
    if exe_path.exists() {
        return exe_path;
    }

    cwd_path
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TriggerKind {
    ExtRoute,
    Adapter,
    Log,
}

pub fn trigger_can_fix_dns(kind: TriggerKind, allow_adapter_fallback: bool) -> bool {
    match kind {
        TriggerKind::ExtRoute => true,
        TriggerKind::Adapter => allow_adapter_fallback,
        TriggerKind::Log => false,
    }
}

pub fn ext_route_looks_connected(content: &str) -> bool {
    if content.trim().is_empty() {
        return false;
    }

    let has_vpn_gateway = content.contains("172.16.10.1");
    let has_private_route = content.contains("10.0.0.0;")
        || content.contains("172.16.0.0;")
        || content.contains("192.168.0.0;");

    has_vpn_gateway && has_private_route
}

pub fn dns_needs_fix(current: &[String], preferred: &[String]) -> bool {
    current != preferred
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AdapterSnapshot {
    #[serde(default, rename = "Found")]
    pub found: bool,
    #[serde(default, rename = "Status")]
    pub status: String,
    #[serde(default, rename = "InterfaceAlias")]
    pub interface_alias: String,
    #[serde(default, rename = "IPv4")]
    pub ipv4: Vec<String>,
    #[serde(default, rename = "DnsServers")]
    pub dns_servers: Vec<String>,
}

impl AdapterSnapshot {
    pub fn is_connected(&self) -> bool {
        self.found
            && self.status.eq_ignore_ascii_case("Up")
            && self
                .ipv4
                .iter()
                .any(|ip| !ip.starts_with("169.254.") && !ip.trim().is_empty())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_config_uses_ext_route_first_and_common_dns() {
        let cfg = AppConfig::default();

        assert_eq!(cfg.preferred_dns, vec!["114.114.114.114"]);
        assert!(!cfg.allow_adapter_fallback);
        assert!(cfg.confirm_uncertain);
        assert!(cfg.auto_elevate);
        assert_eq!(cfg.timeout(), Duration::from_secs(120));
        assert_eq!(cfg.vpn_process_name, "RG-SSLVPN");
        assert_eq!(
            cfg.cleaner_script_path,
            PathBuf::from("scripts/clear-ruijie-sslvpn-dns.ps1")
        );
        assert_eq!(
            cfg.log_path,
            PathBuf::from("log/ruijie-sslvpn-launcher-rs.log")
        );
    }

    #[test]
    fn config_relative_paths_resolve_against_config_directory() {
        let mut cfg = AppConfig::default();
        cfg.resolve_paths(Path::new(r"C:\tools\ruijie"));

        assert_eq!(
            cfg.cleaner_script_path,
            PathBuf::from(r"C:\tools\ruijie\scripts\clear-ruijie-sslvpn-dns.ps1")
        );
        assert_eq!(
            cfg.log_path,
            PathBuf::from(r"C:\tools\ruijie\log\ruijie-sslvpn-launcher-rs.log")
        );
    }

    #[test]
    fn elevated_args_skip_exe_and_quote_spaces() {
        let args = vec![
            r"C:\tools\launcher.exe".to_string(),
            "--config".to_string(),
            r"C:\tools with spaces\config.toml".to_string(),
            "--dns".to_string(),
            "198.18.0.2".to_string(),
        ];

        assert_eq!(
            build_elevated_args(&args),
            r#"--config "C:\tools with spaces\config.toml" --dns 198.18.0.2"#
        );
    }

    #[test]
    fn config_path_prefers_existing_exe_dir_file_when_cwd_missing() {
        let temp_root =
            std::env::temp_dir().join(format!("ruijie-config-path-test-{}", std::process::id()));
        let cwd = temp_root.join("cwd");
        let exe_dir = temp_root.join("bin");
        std::fs::create_dir_all(&cwd).unwrap();
        std::fs::create_dir_all(&exe_dir).unwrap();
        std::fs::write(exe_dir.join("ruijie-sslvpn-launcher-rs.toml"), "").unwrap();

        let resolved =
            resolve_config_path(Path::new("ruijie-sslvpn-launcher-rs.toml"), &cwd, &exe_dir);

        assert_eq!(resolved, exe_dir.join("ruijie-sslvpn-launcher-rs.toml"));

        let _ = std::fs::remove_dir_all(temp_root);
    }

    #[test]
    fn ext_route_with_vpn_gateway_and_private_route_is_connected() {
        let content = "\
192.168.0.0;255.255.0.0;172.16.10.1;5;7;\n\
10.0.0.0;255.0.0.0;172.16.10.1;5;7;\n\
114.114.114.114;255.255.255.255;172.16.10.1;5;7;\n";

        assert!(ext_route_looks_connected(content));
    }

    #[test]
    fn empty_ext_route_is_not_connected() {
        assert!(!ext_route_looks_connected(""));
    }

    #[test]
    fn only_ext_route_can_trigger_fix_by_default() {
        assert!(trigger_can_fix_dns(TriggerKind::ExtRoute, false));
        assert!(!trigger_can_fix_dns(TriggerKind::Adapter, false));
        assert!(!trigger_can_fix_dns(TriggerKind::Log, false));
        assert!(trigger_can_fix_dns(TriggerKind::Adapter, true));
    }

    #[test]
    fn adapter_connected_requires_up_and_non_link_local_ipv4() {
        let connected = AdapterSnapshot {
            found: true,
            status: "Up".to_string(),
            interface_alias: "local".to_string(),
            ipv4: vec!["10.1.2.3".to_string()],
            dns_servers: vec![],
        };
        let link_local = AdapterSnapshot {
            ipv4: vec!["169.254.1.2".to_string()],
            ..connected.clone()
        };
        let disconnected = AdapterSnapshot {
            status: "Disconnected".to_string(),
            ..connected.clone()
        };

        assert!(connected.is_connected());
        assert!(!link_local.is_connected());
        assert!(!disconnected.is_connected());
    }

    #[test]
    fn dns_needs_fix_compares_exact_ordered_list() {
        assert!(dns_needs_fix(
            &["198.18.0.2".to_string(), "114.114.114.114".to_string()],
            &["114.114.114.114".to_string()]
        ));
        assert!(!dns_needs_fix(
            &["114.114.114.114".to_string()],
            &["114.114.114.114".to_string()]
        ));
    }
}
