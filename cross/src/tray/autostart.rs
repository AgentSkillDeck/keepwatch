//! "Open at login": `~/.config/autostart/keepwatch-tray.desktop` (or under
//! `$XDG_CONFIG_HOME`). Written atomically as 0600; a symlink is never
//! written through or removed.

use std::path::{Path, PathBuf};

const FILE: &str = "keepwatch-tray.desktop";

fn dir() -> Option<PathBuf> {
    let config = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .or_else(|| keepwatch::util::home_dir().map(|h| Path::new(&h).join(".config")))?;
    config.is_absolute().then(|| config.join("autostart"))
}

/// The `Exec=` value for `exe`, or None if the path can't be written safely
/// (relative, a deleted binary, or characters that need Desktop Entry escaping).
pub fn exec_line(exe: &Path) -> Option<String> {
    let s = exe.to_str()?;
    let unsafe_char = |c: char| c.is_control() || matches!(c, '"' | '`' | '$' | '\\' | '%' | '\'');
    if !exe.is_absolute() || s.ends_with(" (deleted)") || s.chars().any(unsafe_char) || s.len() > 4096 {
        return None;
    }
    Some(if s.contains(' ') { format!("\"{s}\"") } else { s.to_string() })
}

pub fn entry(exec: &str) -> String {
    format!(
        "[Desktop Entry]\nType=Application\nName=Keepwatch\nComment=Keep this computer awake for AI agents\n\
         Exec={exec}\nTerminal=false\nX-GNOME-Autostart-enabled=true\nX-Keepwatch=1\n"
    )
}

/// Whether "Open at login" is on (a regular file, not a link).
pub fn enabled() -> bool {
    dir().and_then(|d| std::fs::symlink_metadata(d.join(FILE)).ok()).is_some_and(|m| m.is_file())
}

/// Turn "Open at login" on or off.
pub fn set(on: bool) -> Result<(), String> {
    let dir = dir().ok_or("no home folder")?;
    let path = dir.join(FILE);
    if on {
        let exe = std::env::current_exe().map_err(|e| format!("can't find keepwatch-tray itself: {e}"))?;
        let exec = exec_line(&exe).ok_or("keepwatch-tray's path can't go in a .desktop file")?;
        let dir = keepwatch::util::own_dir(&dir).ok_or("~/.config/autostart isn't a private folder of yours")?;
        keepwatch::util::write_atomic(&dir, FILE, entry(&exec).as_bytes()).map_err(|e| e.to_string())
    } else {
        match std::fs::symlink_metadata(&path) {
            Ok(m) if m.is_file() => std::fs::remove_file(&path).map_err(|e| e.to_string()),
            Ok(_) => Err(format!("{} isn't a regular file; leaving it alone", path.display())),
            Err(_) => Ok(()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exec_lines_are_safe() {
        assert_eq!(
            exec_line(Path::new("/home/me/.local/bin/keepwatch-tray")).as_deref(),
            Some("/home/me/.local/bin/keepwatch-tray")
        );
        assert_eq!(
            exec_line(Path::new("/opt/Keep Watch/keepwatch-tray")).as_deref(),
            Some("\"/opt/Keep Watch/keepwatch-tray\"")
        );
        for bad in [
            "relative/tray",
            "/x/keepwatch-tray (deleted)",
            "/x/$HOME",
            "/x/a\"b",
            "/x/a%u",
            "/x/a\nExec=evil",
            "/x/a\\b",
            "/x/`id`",
        ] {
            assert_eq!(exec_line(Path::new(bad)), None, "{bad:?}");
        }
        let e = entry("/x/keepwatch-tray");
        assert!(e.starts_with("[Desktop Entry]\n") && e.contains("\nExec=/x/keepwatch-tray\n"));
    }

    #[test]
    fn toggles_without_following_links() {
        let base = std::env::temp_dir().join(format!("kw-autostart-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        std::env::set_var("XDG_CONFIG_HOME", &base);
        assert!(!enabled());
        set(true).unwrap();
        assert!(enabled());
        let text = std::fs::read_to_string(base.join("autostart").join(FILE)).unwrap();
        assert!(text.contains("X-Keepwatch=1"));
        set(false).unwrap();
        assert!(!enabled());
        set(false).unwrap();
        // A link someone planted: neither followed nor removed.
        let victim = base.join("victim");
        std::fs::write(&victim, "keep").unwrap();
        std::os::unix::fs::symlink(&victim, base.join("autostart").join(FILE)).unwrap();
        assert!(!enabled());
        assert!(set(false).is_err());
        set(true).unwrap();
        assert_eq!(std::fs::read_to_string(&victim).unwrap(), "keep");
        assert!(enabled(), "replaced by a real file");
        std::env::remove_var("XDG_CONFIG_HOME");
        let _ = std::fs::remove_dir_all(&base);
    }
}
