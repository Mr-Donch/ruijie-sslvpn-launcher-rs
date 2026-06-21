fn main() {
    if !cfg!(target_os = "windows") {
        return;
    }

    embed_application_icon();

    if std::env::var("PROFILE").as_deref() != Ok("release") {
        return;
    }

    println!("cargo:rustc-link-arg-bin=ruijie-sslvpn-launcher-rs=/MANIFEST:EMBED");
    println!("cargo:rustc-link-arg-bin=ruijie-sslvpn-launcher-rs=/MANIFESTUAC:level='requireAdministrator' uiAccess='false'");
}

fn embed_application_icon() {
    let mut res = winres::WindowsResource::new();
    res.set_icon("assets/RG-SSLVPN.ico");
    if let Err(err) = res.compile() {
        eprintln!("warning: failed to compile icon resource: {err}");
    }
}
