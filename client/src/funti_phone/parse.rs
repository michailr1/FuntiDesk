//! FUNTIDESK (ADR-026, stage 3): what an Android phone can tell about itself
//! without anyone at it — memory, storage, battery, model — read from
//! /proc, /sys, `getprop` and `df`. Only std here, so this file is also
//! built and tested on its own.

/// (total, available) in bytes from /proc/meminfo.
pub fn meminfo(text: &str) -> Option<(u64, u64)> {
    let field = |name: &str| {
        text.lines()
            .find(|l| l.starts_with(name))
            .and_then(|l| l.split_whitespace().nth(1))
            .and_then(|v| v.parse::<u64>().ok())
            .map(|kb| kb * 1024)
    };
    let total = field("MemTotal:")?;
    let available = field("MemAvailable:").or_else(|| field("MemFree:"))?;
    Some((total, available.min(total)))
}

/// (total, used) in bytes from `df -k <path>` (toybox prints 1K blocks).
pub fn df(text: &str) -> Option<(u64, u64)> {
    let line = text.lines().skip(1).find(|l| !l.trim().is_empty())?;
    let cols: Vec<&str> = line.split_whitespace().collect();
    let total = cols.get(1)?.parse::<u64>().ok()? * 1024;
    let used = cols.get(2)?.parse::<u64>().ok()? * 1024;
    Some((total, used.min(total)))
}

/// The value of `[name]: [value]` in `getprop` output.
pub fn getprop<'a>(text: &'a str, name: &str) -> &'a str {
    let key = format!("[{name}]: [");
    text.lines()
        .find_map(|l| l.strip_prefix(key.as_str()))
        .and_then(|rest| rest.strip_suffix(']'))
        .unwrap_or("")
}

/// Battery level 0–100 and whether it is charging, from
/// /sys/class/power_supply/battery/{capacity,status}.
pub fn battery(capacity: &str, status: &str) -> Option<(u8, bool)> {
    let level = capacity.trim().parse::<u8>().ok()?.min(100);
    let charging = matches!(status.trim(), "Charging" | "Full");
    Some((level, charging))
}

/// Seconds since start from /proc/uptime.
pub fn uptime(text: &str) -> u64 {
    text.split_whitespace()
        .next()
        .and_then(|v| v.parse::<f64>().ok())
        .map_or(0, |s| s as u64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn memory() {
        let t = "MemTotal:        7811256 kB\nMemFree:          212340 kB\nMemAvailable:    3021000 kB\n";
        assert_eq!(meminfo(t), Some((7811256 * 1024, 3021000 * 1024)));
        assert_eq!(meminfo("MemTotal: 100 kB\nMemFree: 40 kB\n"), Some((102400, 40960)));
        assert_eq!(meminfo("garbage"), None);
    }

    #[test]
    fn storage() {
        let t = "Filesystem     1K-blocks     Used Available Use% Mounted on\n/dev/block/dm-48 115268400 60123456 55014944  53% /data\n";
        assert_eq!(df(t), Some((115268400 * 1024, 60123456 * 1024)));
        assert_eq!(df("Filesystem\n"), None);
    }

    #[test]
    fn props() {
        let t = "[ro.product.model]: [Seeker]\n[ro.build.version.release]: [14]\n[ro.product.manufacturer]: [Solana Mobile]\n";
        assert_eq!(getprop(t, "ro.product.model"), "Seeker");
        assert_eq!(getprop(t, "ro.build.version.release"), "14");
        assert_eq!(getprop(t, "ro.missing"), "");
    }

    #[test]
    fn power() {
        assert_eq!(battery("85\n", "Charging\n"), Some((85, true)));
        assert_eq!(battery("40", "Discharging"), Some((40, false)));
        assert_eq!(battery("x", "Full"), None);
        assert_eq!(uptime("12345.67 9876.5\n"), 12345);
    }
}
