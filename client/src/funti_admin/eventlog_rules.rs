//! FUNTIDESK (ADR-024, stage 5): Windows event logs — the request, the
//! query and what is taken from an event. Only std and serde_json here, so
//! this file is also built and tested on its own.

use serde_json::{json, Value};

/// Events in one answer at most.
pub const COUNT_MAX: usize = 500;
const COUNT_DEFAULT: usize = 200;
/// A longer message is cut: the window shows it, it is not an archive.
const MESSAGE_MAX: usize = 4000;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Log {
    System,
    Application,
    Security,
}

impl Log {
    pub fn channel(self) -> &'static str {
        match self {
            Log::System => "System",
            Log::Application => "Application",
            Log::Security => "Security",
        }
    }

    fn from_id(id: &str) -> Option<Self> {
        [Log::System, Log::Application, Log::Security]
            .into_iter()
            .find(|l| l.channel().eq_ignore_ascii_case(id))
    }
}

/// Which events: everything, warnings and worse, or errors and worse.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Level {
    All,
    Warning,
    Error,
}

impl Level {
    fn from_id(id: &str) -> Option<Self> {
        match id {
            "" | "all" => Some(Level::All),
            "warning" => Some(Level::Warning),
            "error" => Some(Level::Error),
            _ => None,
        }
    }

    fn id(self) -> &'static str {
        match self {
            Level::All => "all",
            Level::Warning => "warning",
            Level::Error => "error",
        }
    }

    /// XPath of the event log query. Level 1 is critical, 2 error,
    /// 3 warning; the Security log marks failures by keyword, not level.
    pub fn query(self) -> &'static str {
        match self {
            Level::All => "*",
            Level::Warning => "*[System[(Level=1 or Level=2 or Level=3)]]",
            Level::Error => "*[System[(Level=1 or Level=2)]]",
        }
    }
}

#[derive(Debug, PartialEq)]
pub struct Request {
    pub log: Log,
    pub level: Level,
    pub count: usize,
}

/// `{"op":"eventlog","log":"System","level":"error","count":200}`; None if
/// it is not a request we know.
pub fn parse_request(v: &Value) -> Option<Request> {
    if v["op"] != "eventlog" {
        return None;
    }
    let log = Log::from_id(v["log"].as_str().unwrap_or("System"))?;
    let level = Level::from_id(v["level"].as_str().unwrap_or(""))?;
    let count = v["count"].as_u64().map_or(COUNT_DEFAULT, |c| c as usize).clamp(1, COUNT_MAX);
    Some(Request { log, level, count })
}

#[derive(Debug, Default, PartialEq)]
pub struct Event {
    /// UTC, as the log keeps it: "2026-11-13T10:12:01.1234567Z".
    pub time: String,
    /// 0 information (or "audit"), 1 critical, 2 error, 3 warning, 4 information.
    pub level: u8,
    pub source: String,
    pub id: u32,
    /// Security: 0x10000000000000 is "audit failure".
    pub failure: bool,
    pub message: String,
}

/// The fields of the `<System>` part of an event in XML, as `EvtRender`
/// gives it. Missing fields stay empty.
pub fn parse_system(xml: &str) -> Event {
    let keywords = element(xml, "Keywords")
        .and_then(|k| u64::from_str_radix(k.trim_start_matches("0x"), 16).ok())
        .unwrap_or(0);
    Event {
        time: attribute(xml, "TimeCreated", "SystemTime").unwrap_or_default(),
        level: element(xml, "Level").and_then(|l| l.parse().ok()).unwrap_or(0),
        source: attribute(xml, "Provider", "Name").unwrap_or_default(),
        id: element(xml, "EventID").and_then(|i| i.parse().ok()).unwrap_or(0),
        failure: keywords & 0x0010_0000_0000_0000 != 0,
        message: String::new(),
    }
}

/// The text of `<name ...>text</name>`.
fn element(xml: &str, name: &str) -> Option<String> {
    let open = format!("<{name}");
    let mut from = 0;
    while let Some(i) = xml[from..].find(&open) {
        let start = from + i + open.len();
        let rest = &xml[start..];
        // `<Level>` must not match `<LevelX>`.
        if rest.starts_with('>') || rest.starts_with(' ') {
            let body = &rest[rest.find('>')? + 1..];
            if rest[..rest.find('>')?].ends_with('/') {
                return Some(String::new());
            }
            let end = body.find(&format!("</{name}>"))?;
            return Some(unescape(&body[..end]));
        }
        from = start;
    }
    None
}

/// The value of `attribute` of the first `<name ...>`, quoted either way.
fn attribute(xml: &str, name: &str, attribute: &str) -> Option<String> {
    let open = format!("<{name} ");
    let tag = &xml[xml.find(&open)? + open.len()..];
    let tag = &tag[..tag.find('>')?];
    let key = format!("{attribute}=");
    let value = &tag[tag.find(&key)? + key.len()..];
    let quote = value.chars().next().filter(|c| *c == '\'' || *c == '"')?;
    let value = &value[1..];
    Some(unescape(&value[..value.find(quote)?]))
}

fn unescape(s: &str) -> String {
    s.replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
        .replace("&amp;", "&")
}

pub fn clip_message(message: &str) -> String {
    let message = message.trim();
    match message.char_indices().nth(MESSAGE_MAX) {
        Some((i, _)) => format!("{}…", &message[..i]),
        None => message.to_owned(),
    }
}

pub fn events_json(request: &Request, events: &[Event]) -> Value {
    json!({
        "op": "eventlog",
        "log": request.log.channel(),
        "level": request.level.id(),
        "events": events.iter().map(|e| json!({
            "time": e.time,
            "level": e.level,
            "source": e.source,
            "id": e.id,
            "failure": e.failure,
            "message": e.message,
        })).collect::<Vec<_>>(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requests() {
        let r = parse_request(&json!({"op": "eventlog"})).unwrap();
        assert_eq!(r, Request { log: Log::System, level: Level::All, count: COUNT_DEFAULT });
        let r = parse_request(&json!({"op": "eventlog", "log": "security", "level": "error", "count": 9999}))
            .unwrap();
        assert_eq!(r, Request { log: Log::Security, level: Level::Error, count: COUNT_MAX });
        assert_eq!(parse_request(&json!({"op": "eventlog", "log": "Setup"})), None);
        assert_eq!(parse_request(&json!({"op": "eventlog", "level": "debug"})), None);
        assert_eq!(parse_request(&json!({"op": "status"})), None);
    }

    #[test]
    fn queries() {
        assert_eq!(Level::All.query(), "*");
        assert!(Level::Error.query().contains("Level=2"));
        assert!(!Level::Error.query().contains("Level=3"));
        assert!(Level::Warning.query().contains("Level=3"));
    }

    #[test]
    fn system_part() {
        let xml = "<Event xmlns='http://schemas.microsoft.com/win/2004/08/events/event'><System>\
            <Provider Name='Microsoft-Windows-Kernel-Power' Guid='{331c}'/>\
            <EventID Qualifiers='0'>41</EventID><Version>9</Version><Level>1</Level>\
            <Task>63</Task><Keywords>0x8000400000000002</Keywords>\
            <TimeCreated SystemTime='2026-11-13T10:12:01.1234567Z'/>\
            <Computer>PC &amp; Co</Computer></System></Event>";
        let e = parse_system(xml);
        assert_eq!(e.source, "Microsoft-Windows-Kernel-Power");
        assert_eq!(e.id, 41);
        assert_eq!(e.level, 1);
        assert_eq!(e.time, "2026-11-13T10:12:01.1234567Z");
        assert!(!e.failure);
        assert_eq!(element(xml, "Computer").unwrap(), "PC & Co");
    }

    #[test]
    fn audit_failure() {
        let xml = "<System><Provider Name=\"Microsoft-Windows-Security-Auditing\"/>\
            <EventID>4625</EventID><Level>0</Level><Keywords>0x8010000000000000</Keywords></System>";
        let e = parse_system(xml);
        assert_eq!((e.id, e.level, e.failure), (4625, 0, true));
        assert_eq!(e.source, "Microsoft-Windows-Security-Auditing");
    }

    #[test]
    fn broken_xml() {
        assert_eq!(parse_system("<System><Level>"), Event::default());
        assert_eq!(parse_system(""), Event::default());
    }

    #[test]
    fn messages() {
        assert_eq!(clip_message("  text \r\n"), "text");
        let long = "я".repeat(MESSAGE_MAX + 10);
        assert_eq!(clip_message(&long).chars().count(), MESSAGE_MAX + 1);
    }
}
