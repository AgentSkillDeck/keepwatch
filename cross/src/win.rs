//! Windows system calls. The only `unsafe` in keepwatch is here: two Win32
//! calls that take plain values or a pointer to a local struct.
#![allow(unsafe_code)]

use windows_sys::Win32::System::Power::{
    GetSystemPowerStatus, SetThreadExecutionState, ES_CONTINUOUS, ES_DISPLAY_REQUIRED, ES_SYSTEM_REQUIRED,
    SYSTEM_POWER_STATUS,
};

/// Hold (or, with `on == false`, release) the keep-awake state for the
/// calling thread. Windows clears it when the thread or process ends.
pub fn keep_awake(on: bool, display: bool) -> bool {
    let mut flags = ES_CONTINUOUS;
    if on {
        flags |= ES_SYSTEM_REQUIRED;
        if display {
            flags |= ES_DISPLAY_REQUIRED;
        }
    }
    // SAFETY: SetThreadExecutionState takes a flags value and touches no
    // memory of ours; it returns 0 on failure.
    let previous = unsafe { SetThreadExecutionState(flags) };
    previous != 0
}

pub fn power_status() -> Option<crate::power::WinPowerStatus> {
    let mut s = SYSTEM_POWER_STATUS {
        ACLineStatus: 255,
        BatteryFlag: 255,
        BatteryLifePercent: 255,
        SystemStatusFlag: 0,
        BatteryLifeTime: u32::MAX,
        BatteryFullLifeTime: u32::MAX,
    };
    // SAFETY: `s` is a valid, initialised SYSTEM_POWER_STATUS on our stack,
    // which the call fills in; it lives until after the call returns.
    let ok = unsafe { GetSystemPowerStatus(&mut s) };
    (ok != 0).then_some(crate::power::WinPowerStatus {
        ac_line_status: s.ACLineStatus,
        battery_flag: s.BatteryFlag,
        battery_life_percent: s.BatteryLifePercent,
        system_status_flag: s.SystemStatusFlag,
        battery_life_time: s.BatteryLifeTime,
    })
}

/// Apps using `capability` ("microphone" or "webcam") right now, from the
/// current user's consent store. None if the store can't be read.
pub fn consent_users(capability: &str) -> Option<Vec<String>> {
    use winreg::enums::HKEY_CURRENT_USER;
    use winreg::RegKey;
    const MAX_KEYS: usize = 1_024;
    let base =
        format!("Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\{capability}");
    let root = RegKey::predef(HKEY_CURRENT_USER).open_subkey(&base).ok()?;
    let mut users = Vec::new();
    let mut scan = |key: &RegKey, non_packaged: bool| {
        for name in key.enum_keys().take(MAX_KEYS).flatten() {
            if !non_packaged && name == "NonPackaged" {
                continue;
            }
            let Ok(app) = key.open_subkey(&name) else {
                continue;
            };
            let start: Option<u64> = app.get_value("LastUsedTimeStart").ok();
            let stop: Option<u64> = app.get_value("LastUsedTimeStop").ok();
            if crate::privacy::consent_in_use(start, stop) {
                users.push(crate::privacy::consent_app_name(&name, non_packaged));
            }
        }
    };
    scan(&root, false);
    if let Ok(np) = root.open_subkey("NonPackaged") {
        scan(&np, true);
    }
    users.sort();
    users.dedup();
    Some(users)
}
