//! Battery and power source. Linux: `/sys/class/power_supply`, lid from
//! `/proc/acpi/button/lid`. Windows: `GetSystemPowerStatus`. Unknowns are None.
// The pure Linux parsers are compiled (and tested) everywhere, used live on Linux only.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

/// What we know about power; field meanings match `StatusReport.Power`.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Power {
    pub battery_percent: Option<i64>,
    pub on_battery: Option<bool>,
    pub charging: Option<bool>,
    pub minutes_remaining: Option<i64>,
    pub health_percent: Option<i64>,
    pub cycle_count: Option<i64>,
    pub low_power_mode: Option<bool>,
    pub lid_closed: Option<bool>,
}

/// One `/sys/class/power_supply/<name>` device, as key -> trimmed value.
pub type Supply = std::collections::BTreeMap<String, String>;

fn num(s: &Supply, key: &str) -> Option<i64> {
    s.get(key)?.trim().parse::<i64>().ok().filter(|v| *v >= 0)
}

fn is_battery(s: &Supply) -> bool {
    s.get("type").is_some_and(|t| t == "Battery") && s.get("scope").is_none_or(|sc| sc != "Device")
}

fn ratio_percent(num: i64, den: i64) -> Option<i64> {
    if den <= 0 {
        return None;
    }
    // i128 so huge sysfs values can't overflow; the result is small.
    let p = (i128::from(num) * 100 + i128::from(den) / 2) / i128::from(den);
    i64::try_from(p).ok()
}

/// Combine the system batteries (summed, for laptops with BAT0 and BAT1) and
/// mains adapters into a `Power`. Peripherals (`scope=Device`) are ignored.
pub fn from_supplies(supplies: &[Supply]) -> Power {
    let batteries: Vec<&Supply> = supplies.iter().filter(|s| is_battery(s)).collect();
    let mains_online = supplies
        .iter()
        .filter(|s| s.get("type").is_some_and(|t| t == "Mains" || t == "USB"))
        .filter_map(|s| num(s, "online"))
        .max();
    let mut p = Power::default();
    if batteries.is_empty() {
        // A machine without a battery runs on mains power.
        p.on_battery = Some(false);
        p.charging = Some(false);
        return p;
    }
    let statuses: Vec<&str> = batteries.iter().filter_map(|b| b.get("status").map(String::as_str)).collect();
    let charging = statuses.contains(&"Charging");
    let discharging = statuses.contains(&"Discharging");
    p.charging = Some(charging);
    p.on_battery = match mains_online {
        Some(online) => Some(online == 0),
        None if discharging || charging || statuses.contains(&"Full") => Some(discharging),
        None => None,
    };
    // Energy (µWh) or charge (µAh) counters, summed across batteries.
    let sum = |keys: [&str; 2]| -> Option<i64> {
        batteries.iter().try_fold(0i64, |acc, b| acc.checked_add(num(b, keys[0]).or_else(|| num(b, keys[1]))?))
    };
    let now = sum(["energy_now", "charge_now"]);
    let full = sum(["energy_full", "charge_full"]);
    let design = sum(["energy_full_design", "charge_full_design"]);
    let rate = sum(["power_now", "current_now"]);
    p.battery_percent = match (now, full) {
        (Some(n), Some(f)) if batteries.len() > 1 => ratio_percent(n, f),
        _ => batteries
            .iter()
            .filter_map(|b| num(b, "capacity"))
            .next()
            .or_else(|| now.zip(full).and_then(|(n, f)| ratio_percent(n, f))),
    }
    .map(|v| v.clamp(0, 100));
    p.health_percent = full.zip(design).and_then(|(f, d)| ratio_percent(f, d)).filter(|h| (1..=200).contains(h));
    // Many drivers report 0 when they don't count cycles; 0 is "unknown".
    p.cycle_count = batteries.iter().filter_map(|b| num(b, "cycle_count")).max().filter(|c| *c > 0);
    if discharging {
        p.minutes_remaining = now.zip(rate).and_then(|(n, r)| {
            if r <= 0 {
                return None;
            }
            i64::try_from(i128::from(n) * 60 / i128::from(r)).ok()
        });
    }
    p
}

/// `/proc/acpi/button/lid/*/state` text ("state:      open") -> closed?
pub fn parse_lid_state(text: &str) -> Option<bool> {
    let value = text.split_once(':')?.1.trim();
    match value {
        "open" => Some(false),
        "closed" => Some(true),
        _ => None,
    }
}

/// Fields of the Windows `SYSTEM_POWER_STATUS` struct we use.
#[derive(Debug, Clone, Copy)]
#[cfg_attr(not(windows), allow(dead_code))]
pub struct WinPowerStatus {
    pub ac_line_status: u8,
    pub battery_flag: u8,
    pub battery_life_percent: u8,
    pub system_status_flag: u8,
    pub battery_life_time: u32,
}

/// Interpret `GetSystemPowerStatus`: 255 / 0xFFFFFFFF mean unknown, flag 128 no battery.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn from_windows(s: WinPowerStatus) -> Power {
    let no_battery = s.battery_flag != 255 && s.battery_flag & 128 != 0;
    let unknown_flag = s.battery_flag == 255;
    Power {
        battery_percent: (!no_battery && s.battery_life_percent <= 100).then_some(i64::from(s.battery_life_percent)),
        on_battery: match s.ac_line_status {
            0 => Some(true),
            1 => Some(false),
            _ => None,
        },
        charging: if unknown_flag { None } else { Some(s.battery_flag & 8 != 0) },
        minutes_remaining: (s.ac_line_status == 0 && s.battery_life_time != u32::MAX)
            .then_some(i64::from(s.battery_life_time / 60)),
        health_percent: None,
        cycle_count: None,
        // SystemStatusFlag 1 = battery saver on.
        low_power_mode: Some(s.system_status_flag == 1),
        lid_closed: None,
    }
}

/// `busctl get-property … LidClosed` / `Docked` output ("b true") -> bool.
pub fn parse_busctl_bool(text: &str) -> Option<bool> {
    let mut it = text.split_whitespace();
    if it.next()? != "b" {
        return None;
    }
    let v = match it.next()? {
        "true" => true,
        "false" => false,
        _ => return None,
    };
    it.next().is_none().then_some(v)
}

/// A `thermal_zone*/temp` value (millidegrees Celsius). Values outside
/// -50..=200 °C are sensor junk and ignored.
pub fn parse_temp(text: &str) -> Option<i64> {
    text.trim().parse::<i64>().ok().filter(|t| (-50_000..=200_000).contains(t))
}

#[cfg(target_os = "linux")]
fn supplies_root() -> std::path::PathBuf {
    crate::util::test_path("POWER_SUPPLY").unwrap_or_else(|| "/sys/class/power_supply".into())
}

#[cfg(target_os = "linux")]
pub fn current() -> Power {
    use std::path::Path;
    let mut p = battery();
    p.lid_closed = lid_closed();
    // power-profiles-daemon: "power-saver" is the closest thing to Low Power Mode.
    if let Some(ppd) = crate::util::system_program("powerprofilesctl") {
        p.low_power_mode = crate::util::run_capture(&ppd, &["get"], std::time::Duration::from_secs(2))
            .map(|s| s.trim() == "power-saver");
    } else if let Some(profile) = crate::util::read_value(Path::new("/sys/firmware/acpi/platform_profile")) {
        p.low_power_mode = Some(profile == "low-power");
    }
    p
}

/// Battery and adapter only (no lid, no power profile): cheap enough for every rule tick.
#[cfg(target_os = "linux")]
pub fn battery() -> Power {
    const MAX_SUPPLIES: usize = 64;
    const KEYS: &[&str] = &[
        "type",
        "scope",
        "status",
        "online",
        "capacity",
        "cycle_count",
        "energy_now",
        "energy_full",
        "energy_full_design",
        "charge_now",
        "charge_full",
        "charge_full_design",
        "power_now",
        "current_now",
    ];
    let mut supplies = Vec::new();
    if let Ok(dir) = std::fs::read_dir(supplies_root()) {
        for entry in dir.flatten().take(MAX_SUPPLIES) {
            let mut s = Supply::new();
            for key in KEYS {
                if let Some(v) = crate::util::read_value(&entry.path().join(key)) {
                    s.insert(key.to_string(), v);
                }
            }
            supplies.push(s);
        }
    }
    from_supplies(&supplies)
}

/// Whether the lid is closed: `/proc/acpi/button/lid/*/state`, else logind's
/// `LidClosed`. None if neither can be read (desktops, containers).
/// Debug builds read `KEEPWATCH_TEST_LID_STATE` (a file like the /proc one) instead.
#[cfg(target_os = "linux")]
pub fn lid_closed() -> Option<bool> {
    if let Some(path) = crate::util::test_path("LID_STATE") {
        return crate::util::read_regular_capped(&path, 4096).and_then(|t| parse_lid_state(&t));
    }
    if let Ok(dir) = std::fs::read_dir("/proc/acpi/button/lid") {
        let found = dir
            .flatten()
            .take(8)
            .filter_map(|e| crate::util::read_regular_capped(&e.path().join("state"), 4096))
            .find_map(|t| parse_lid_state(&t));
        if found.is_some() {
            return found;
        }
    }
    logind_bool("LidClosed")
}

/// Whether logind counts the machine as docked (an external display or a
/// dock); then logind itself ignores the lid by default, so keepwatch doesn't
/// suspend it either. None if unknown.
#[cfg(target_os = "linux")]
pub fn docked() -> Option<bool> {
    if crate::util::test_path("LID_STATE").is_some() {
        // A stand-in lid: never ask the real logind about the real machine.
        return crate::util::test_override("DOCKED").map(|v| v == "1");
    }
    logind_bool("Docked")
}

#[cfg(target_os = "linux")]
fn logind_bool(property: &str) -> Option<bool> {
    let busctl = crate::util::system_program("busctl")?;
    let args = [
        "get-property",
        "org.freedesktop.login1",
        "/org/freedesktop/login1",
        "org.freedesktop.login1.Manager",
        property,
    ];
    parse_busctl_bool(&crate::util::run_capture(&busctl, &args, std::time::Duration::from_secs(2))?)
}

/// The hottest thermal zone, in millidegrees Celsius, or None if none can be read.
/// Debug builds read `KEEPWATCH_TEST_THERMAL` instead of `/sys/class/thermal`.
#[cfg(target_os = "linux")]
pub fn max_temp_millic() -> Option<i64> {
    let root = crate::util::test_path("THERMAL").unwrap_or_else(|| "/sys/class/thermal".into());
    let dir = std::fs::read_dir(root).ok()?;
    dir.flatten()
        .filter(|e| e.file_name().to_string_lossy().starts_with("thermal_zone"))
        .take(64)
        .filter_map(|e| crate::util::read_regular_capped(&e.path().join("temp"), 4096).and_then(|t| parse_temp(&t)))
        .max()
}

#[cfg(windows)]
pub fn current() -> Power {
    crate::win::power_status().map(from_windows).unwrap_or_default()
}

#[cfg(not(any(target_os = "linux", windows)))]
pub fn current() -> Power {
    Power::default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn supply(pairs: &[(&str, &str)]) -> Supply {
        pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
    }

    #[test]
    fn laptop_on_battery() {
        let bat = supply(&[
            ("type", "Battery"),
            ("status", "Discharging"),
            ("capacity", "57"),
            ("energy_now", "28500000"),
            ("energy_full", "50000000"),
            ("energy_full_design", "57000000"),
            ("power_now", "9500000"),
            ("cycle_count", "312"),
        ]);
        let ac = supply(&[("type", "Mains"), ("online", "0")]);
        let mouse = supply(&[("type", "Battery"), ("scope", "Device"), ("status", "Charging"), ("capacity", "5")]);
        let p = from_supplies(&[ac, bat, mouse]);
        assert_eq!(p.battery_percent, Some(57));
        assert_eq!(p.on_battery, Some(true));
        assert_eq!(p.charging, Some(false), "a charging mouse doesn't count");
        assert_eq!(p.health_percent, Some(88));
        assert_eq!(p.cycle_count, Some(312));
        assert_eq!(p.minutes_remaining, Some(180));
    }

    #[test]
    fn charge_counters_and_two_batteries() {
        let b0 = supply(&[
            ("type", "Battery"),
            ("status", "Charging"),
            ("charge_now", "1000"),
            ("charge_full", "2000"),
            ("charge_full_design", "2000"),
            ("cycle_count", "0"),
        ]);
        let b1 = supply(&[
            ("type", "Battery"),
            ("status", "Full"),
            ("charge_now", "2000"),
            ("charge_full", "2000"),
            ("charge_full_design", "4000"),
        ]);
        let p = from_supplies(&[b0, b1]);
        assert_eq!(p.battery_percent, Some(75));
        assert_eq!(p.health_percent, Some(67));
        assert_eq!(p.charging, Some(true));
        assert_eq!(p.on_battery, Some(false));
        assert_eq!(p.cycle_count, None, "0 cycles means the driver doesn't count");
        assert_eq!(p.minutes_remaining, None);
    }

    #[test]
    fn junk_and_zero_values_are_unknown() {
        let bat = supply(&[
            ("type", "Battery"),
            ("status", "Discharging"),
            ("capacity", "abc"),
            ("energy_now", "-5"),
            ("energy_full", "0"),
            ("energy_full_design", "0"),
            ("power_now", "0"),
        ]);
        let p = from_supplies(&[bat]);
        assert_eq!(p.battery_percent, None);
        assert_eq!(p.health_percent, None);
        assert_eq!(p.minutes_remaining, None);
        assert_eq!(p.on_battery, Some(true));
        let huge = supply(&[
            ("type", "Battery"),
            ("energy_full", "9223372036854775807"),
            ("energy_full_design", "1"),
            ("capacity", "250"),
        ]);
        let p = from_supplies(&[huge.clone(), huge]);
        assert_eq!(p.health_percent, None, "sum overflows: unknown");
        assert_eq!(p.on_battery, None, "no status and no adapter: unknown");
    }

    #[test]
    fn desktop_without_battery() {
        let p = from_supplies(&[]);
        assert_eq!(p.battery_percent, None);
        assert_eq!(p.on_battery, Some(false));
    }

    #[test]
    fn lid_state() {
        assert_eq!(parse_lid_state("state:      open\n"), Some(false));
        assert_eq!(parse_lid_state("state:      closed\n"), Some(true));
        assert_eq!(parse_lid_state("garbage"), None);
        assert_eq!(parse_lid_state(""), None);
    }

    #[test]
    fn busctl_and_thermal_values() {
        assert_eq!(parse_busctl_bool("b true\n"), Some(true));
        assert_eq!(parse_busctl_bool("b false"), Some(false));
        for bad in ["", "b", "s true", "b yes", "b true extra", "true"] {
            assert_eq!(parse_busctl_bool(bad), None, "{bad}");
        }
        assert_eq!(parse_temp("45000\n"), Some(45_000));
        assert_eq!(parse_temp("95000"), Some(95_000));
        assert_eq!(parse_temp("-273000"), None, "junk sensor");
        assert_eq!(parse_temp("999999999999999999999"), None);
        assert_eq!(parse_temp("hot"), None);
        assert_eq!(parse_temp(""), None);
    }

    #[test]
    fn windows_power_status() {
        let s = WinPowerStatus {
            ac_line_status: 0,
            battery_flag: 0,
            battery_life_percent: 64,
            system_status_flag: 1,
            battery_life_time: 5400,
        };
        let p = from_windows(s);
        assert_eq!(
            (p.battery_percent, p.on_battery, p.charging, p.minutes_remaining, p.low_power_mode),
            (Some(64), Some(true), Some(false), Some(90), Some(true))
        );
        let desktop = from_windows(WinPowerStatus {
            ac_line_status: 1,
            battery_flag: 128,
            battery_life_percent: 255,
            system_status_flag: 0,
            battery_life_time: u32::MAX,
        });
        assert_eq!((desktop.battery_percent, desktop.on_battery, desktop.minutes_remaining), (None, Some(false), None));
        let unknown = from_windows(WinPowerStatus {
            ac_line_status: 255,
            battery_flag: 255,
            battery_life_percent: 255,
            system_status_flag: 0,
            battery_life_time: u32::MAX,
        });
        assert_eq!((unknown.on_battery, unknown.charging, unknown.battery_percent), (None, None, None));
        let charging = from_windows(WinPowerStatus {
            ac_line_status: 1,
            battery_flag: 8 | 1,
            battery_life_percent: 80,
            system_status_flag: 0,
            battery_life_time: u32::MAX,
        });
        assert_eq!((charging.charging, charging.minutes_remaining), (Some(true), None));
    }
}
