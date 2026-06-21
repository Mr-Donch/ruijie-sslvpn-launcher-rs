fn main() {
    if !cfg!(target_os = "windows") {
        return;
    }

    if std::env::var("PROFILE").as_deref() != Ok("release") {
        return;
    }

    println!("cargo:rustc-link-arg-bin=ruijie-sslvpn-launcher-rs=/MANIFEST:EMBED");
    println!("cargo:rustc-link-arg-bin=ruijie-sslvpn-launcher-rs=/MANIFESTUAC:level='requireAdministrator' uiAccess='false'");
}
