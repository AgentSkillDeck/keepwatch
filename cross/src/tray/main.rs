//! `keepwatch-tray`: the Keepwatch tray icon for Linux desktops
//! (StatusNotifierItem: KDE, GNOME with the AppIndicator extension, XFCE,
//! Cinnamon, …). On other platforms it only says it is Linux only.
#![deny(unsafe_code)]

#[cfg(target_os = "linux")]
mod app;
#[cfg(target_os = "linux")]
mod autostart;
#[cfg(target_os = "linux")]
mod icon;
#[cfg(target_os = "linux")]
mod notify;

#[cfg(target_os = "linux")]
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        None => std::process::exit(app::run()),
        Some("--version" | "version") => println!("keepwatch-tray {}", keepwatch::VERSION),
        Some("--help" | "-h" | "help") => println!(
            "keepwatch-tray: the Keepwatch tray icon. Run it from your desktop session (no arguments).\n\
             It holds keep-awake and lid-closed sessions like 'keepwatch awake' and 'keepwatch lid start';\n\
             'keepwatch awake --off' and 'keepwatch lid end' stop them too. GNOME needs the AppIndicator extension."
        ),
        Some(other) => {
            eprintln!("keepwatch-tray: unexpected argument '{}'", keepwatch::util::clean_line(other, 64));
            std::process::exit(1);
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("keepwatch-tray is Linux only. On Windows, use the keepwatch command.");
    std::process::exit(1);
}
