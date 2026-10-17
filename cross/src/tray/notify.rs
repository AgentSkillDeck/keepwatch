//! Desktop notifications through `org.freedesktop.Notifications`, on the
//! session bus, with the zbus that ksni already uses. Best effort: with no
//! notification daemon, nothing happens.

use std::collections::HashMap;

pub struct Notifier {
    conn: Option<zbus::blocking::Connection>,
}

impl Notifier {
    pub fn new() -> Self {
        Notifier { conn: zbus::blocking::Connection::session().ok() }
    }

    pub fn send(&self, summary: &str, body: &str) {
        let Some(conn) = &self.conn else {
            return;
        };
        let summary = keepwatch::util::clean_line(summary, 120);
        let body = keepwatch::util::clean_line(body, 400);
        let hints: HashMap<&str, zbus::zvariant::Value> = HashMap::new();
        let actions: Vec<&str> = Vec::new();
        let _ = conn.call_method(
            Some("org.freedesktop.Notifications"),
            "/org/freedesktop/Notifications",
            Some("org.freedesktop.Notifications"),
            "Notify",
            &("Keepwatch", 0u32, "", summary.as_str(), body.as_str(), actions, hints, 8000i32),
        );
    }
}
