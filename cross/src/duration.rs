//! Keep-awake lengths typed by people and agents: "45m", "1h30m", "1.5h",
//! "3 days", "2w". A port of `AwakeDuration.swift`: pure, bounded, tested.

use chrono::{DateTime, Days, Duration, LocalResult, TimeZone};

/// Longest timed keep-awake (30 days). Longer than that, use "until turned off".
pub const MAX_SECONDS: f64 = 30.0 * 86_400.0;
/// `MAX_SECONDS` in whole minutes (43 200).
pub const MAX_MINUTES: u32 = 30 * 24 * 60;
/// Input longer than this (in characters) is rejected before parsing.
const MAX_INPUT_CHARS: usize = 64;

fn unit_seconds(unit: &str) -> Option<f64> {
    Some(match unit {
        "m" | "min" | "mins" | "minute" | "minutes" => 60.0,
        "h" | "hr" | "hrs" | "hour" | "hours" => 3_600.0,
        "d" | "day" | "days" => 86_400.0,
        "w" | "wk" | "wks" | "week" | "weeks" => 604_800.0,
        _ => return None,
    })
}

/// Seconds for `text`, clamped to `MAX_SECONDS`, or None if it isn't a
/// positive duration with a unit on every number.
pub fn parse(text: &str) -> Option<f64> {
    if text.chars().count() > MAX_INPUT_CHARS {
        return None;
    }
    let chars: Vec<char> = text.to_lowercase().chars().filter(|c| !c.is_whitespace()).collect();
    if chars.is_empty() {
        return None;
    }
    let mut total = 0.0_f64;
    let mut i = 0;
    while i < chars.len() {
        let mut number = String::new();
        while let Some(&c) = chars.get(i) {
            if !(c.is_ascii_digit() || c == '.') {
                break;
            }
            number.push(c);
            i += 1;
        }
        let mut unit = String::new();
        while let Some(&c) = chars.get(i) {
            if !c.is_ascii_alphabetic() {
                break;
            }
            unit.push(c);
            i += 1;
        }
        // Only digits and '.' reach here, so "inf"/"nan" can't parse as numbers.
        let value: f64 = number.parse().ok()?;
        let scale = unit_seconds(&unit)?;
        if !value.is_finite() || value < 0.0 {
            return None;
        }
        total += value * scale;
        if !total.is_finite() {
            return None;
        }
    }
    if total < 1.0 {
        return None;
    }
    Some(total.min(MAX_SECONDS))
}

/// Whole minutes for `seconds`, rounded up, at least 1, at most `MAX_MINUTES`.
pub fn minutes(seconds: f64) -> u32 {
    if !seconds.is_finite() || seconds <= 0.0 {
        return 1;
    }
    let m = (seconds.min(MAX_SECONDS) / 60.0).ceil();
    // m is finite and within 0..=MAX_MINUTES after the min() above, so the cast is exact.
    (m as u32).clamp(1, MAX_MINUTES)
}

/// "45 min", "2 h 5 min", "3 d 4 h", "2 w 1 d".
pub fn describe(seconds: f64) -> String {
    if !seconds.is_finite() {
        return "0 s".into();
    }
    // Clamped to 0..=60 days, so the cast can't overflow.
    let s = seconds.clamp(0.0, MAX_SECONDS * 2.0) as u64;
    let (w, d, h, m) = (s / 604_800, (s % 604_800) / 86_400, (s % 86_400) / 3_600, (s % 3_600) / 60);
    if w > 0 {
        return if d > 0 { format!("{w} w {d} d") } else { format!("{w} w") };
    }
    if d > 0 {
        return if h > 0 { format!("{d} d {h} h") } else { format!("{d} d") };
    }
    if h > 0 {
        return if m > 0 { format!("{h} h {m} min") } else { format!("{h} h") };
    }
    if m > 0 {
        format!("{m} min")
    } else {
        format!("{s} s")
    }
}

/// The next time the clock reads `hh:mm` ("18:30", "6:05") strictly after
/// `now`, today or tomorrow, in `now`'s time zone. A time skipped by a DST
/// change moves to the next existing time, like Foundation's `.nextTime`.
pub fn next_occurrence<Tz: TimeZone>(text: &str, now: &DateTime<Tz>) -> Option<DateTime<Tz>> {
    let mut parts = text.trim().split(':');
    let (h, m) = (parts.next()?, parts.next()?);
    if parts.next().is_some() {
        return None;
    }
    let field = |s: &str| -> Option<u32> {
        if (1..=2).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_digit()) {
            s.parse().ok()
        } else {
            None
        }
    };
    let (hour, minute) = (field(h)?, field(m)?);
    if hour >= 24 || minute >= 60 {
        return None;
    }
    let tz = now.timezone();
    let today = now.date_naive();
    for offset in 0..=2u64 {
        let day = today.checked_add_days(Days::new(offset))?;
        let naive = day.and_hms_opt(hour, minute, 0)?;
        let candidate = match tz.from_local_datetime(&naive) {
            LocalResult::Single(t) => t,
            LocalResult::Ambiguous(first, _) => first,
            LocalResult::None => match tz.from_local_datetime(&naive.checked_add_signed(Duration::hours(1))?) {
                LocalResult::Single(t) | LocalResult::Ambiguous(t, _) => t,
                LocalResult::None => continue,
            },
        };
        if candidate > *now {
            return Some(candidate);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{FixedOffset, Utc};

    #[test]
    fn parses_lengths() {
        assert_eq!(parse("45m"), Some(2_700.0));
        assert_eq!(parse("1.5h"), Some(5_400.0));
        assert_eq!(parse("1h30m"), Some(5_400.0));
        assert_eq!(parse("3 Days"), Some(259_200.0));
        assert_eq!(parse("1w 1d"), Some(691_200.0));
        assert_eq!(parse("52w"), Some(MAX_SECONDS));
    }

    #[test]
    fn rejects_junk() {
        let long = "1".repeat(65) + "m";
        for b in [
            "",
            "3",
            "h",
            "0m",
            "1.2.3h",
            "3 fortnights",
            "-1h",
            "1e400h",
            "1h junk",
            "١h",
            &long,
            "nan h",
            "inf h",
            ".h",
            "  ",
        ] {
            assert_eq!(parse(b), None, "{b}");
        }
        // A huge but short number stays finite and is capped.
        assert_eq!(parse(&("9".repeat(60) + "w")), Some(MAX_SECONDS));
    }

    #[test]
    fn describe_and_minutes() {
        assert_eq!(describe(7_200.0), "2 h");
        assert_eq!(describe(7_500.0), "2 h 5 min");
        assert_eq!(describe(90_000.0), "1 d 1 h");
        assert_eq!(describe(691_200.0), "1 w 1 d");
        assert_eq!(describe(f64::NAN), "0 s");
        assert_eq!(describe(-5.0), "0 s");
        assert_eq!(minutes(61.0), 2);
        assert_eq!(minutes(f64::INFINITY), 1);
        assert_eq!(minutes(1e12), MAX_MINUTES);
        assert_eq!(minutes(-3.0), 1);
    }

    #[test]
    fn next_occurrence_today_or_tomorrow() {
        let now = Utc.with_ymd_and_hms(2026, 10, 16, 17, 0, 0).single().unwrap();
        let t = next_occurrence("18:30", &now).unwrap();
        assert_eq!((t - now).num_minutes(), 90);
        let t = next_occurrence("6:05", &now).unwrap();
        assert_eq!((t - now).num_minutes(), 13 * 60 + 5);
        // Exactly now is not "after now": tomorrow.
        assert_eq!((next_occurrence("17:00", &now).unwrap() - now).num_hours(), 24);
        let tz = FixedOffset::east_opt(5 * 3600 + 1800).unwrap();
        let local = tz.with_ymd_and_hms(2026, 10, 16, 23, 50, 0).single().unwrap();
        assert_eq!((next_occurrence("00:10", &local).unwrap() - local).num_minutes(), 20);
        for b in ["", ":", "1:2:3", "123:00", "18:3x", " 18 : 30 ", "+1:00"] {
            assert!(next_occurrence(b, &now).is_none(), "{b}");
        }
    }
}
