//! FUNTIDESK: which log files go into the archive — the newest first, each
//! cut to its last part, until the archive would get too large. Only std
//! here, so this file is also built and tested on its own.

/// The archive takes this much of log text at most.
pub const TOTAL_MAX: u64 = 8 * 1024 * 1024;
/// Of one file, the end is kept: the newest lines.
pub const FILE_MAX: u64 = 2 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq)]
pub struct Candidate {
    /// Name inside the archive, e.g. "server/FuntiDesk_rCURRENT.log".
    pub name: String,
    pub size: u64,
    /// Seconds since the epoch; newer first.
    pub modified: u64,
}

/// (name, bytes to keep from the end) of the files to take.
pub fn choose(mut files: Vec<Candidate>) -> Vec<(String, u64)> {
    files.sort_by(|a, b| b.modified.cmp(&a.modified).then(a.name.cmp(&b.name)));
    let mut left = TOTAL_MAX;
    let mut out = Vec::new();
    for f in files {
        if left == 0 {
            break;
        }
        if f.size == 0 {
            continue;
        }
        let take = f.size.min(FILE_MAX).min(left);
        left -= take;
        out.push((f.name, take));
    }
    out
}

/// Only log files: "*.log" (flexi_logger names them so).
pub fn is_log(name: &str) -> bool {
    name.to_ascii_lowercase().ends_with(".log")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn c(name: &str, size: u64, modified: u64) -> Candidate {
        Candidate { name: name.into(), size, modified }
    }

    #[test]
    fn newest_first_and_capped() {
        let files = vec![
            c("old.log", 1000, 1),
            c("new.log", 5 * 1024 * 1024, 9),
            c("mid.log", 100, 5),
            c("empty.log", 0, 10),
        ];
        assert_eq!(
            choose(files),
            vec![("new.log".into(), FILE_MAX), ("mid.log".into(), 100), ("old.log".into(), 1000)]
        );
    }

    #[test]
    fn total_limit() {
        let files: Vec<_> = (0..10).map(|i| c(&format!("{i}.log"), FILE_MAX, i)).collect();
        let chosen = choose(files);
        assert_eq!(chosen.len(), (TOTAL_MAX / FILE_MAX) as usize);
        assert_eq!(chosen[0].0, "9.log");
        assert_eq!(chosen.iter().map(|x| x.1).sum::<u64>(), TOTAL_MAX);
    }

    #[test]
    fn names() {
        assert!(is_log("FuntiDesk_rCURRENT.LOG"));
        assert!(!is_log("config.toml"));
    }
}
