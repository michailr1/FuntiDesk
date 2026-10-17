//! FUNTIDESK (ADR-009/010): the service constructs the signed message itself.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

pub fn token(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

pub fn payload_hash(value: &Value) -> Result<String, serde_json::Error> {
    fn ordered(value: &Value) -> Value {
        match value {
            Value::Object(object) => {
                let mut names: Vec<_> = object.keys().collect();
                names.sort_unstable();
                let mut result = serde_json::Map::new();
                for name in names {
                    result.insert(name.clone(), ordered(&object[name]));
                }
                Value::Object(result)
            }
            Value::Array(array) => Value::Array(array.iter().map(ordered).collect()),
            _ => value.clone(),
        }
    }
    Ok(hex::encode(Sha256::digest(serde_json::to_vec(&ordered(
        value,
    ))?)))
}

fn library_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

pub fn merge_local_favorites(
    cloud: &[Value],
    previous: &[String],
    local: &[(String, String)],
) -> Vec<Value> {
    let mut merged: Vec<_> = cloud
        .iter()
        .filter(|row| {
            !previous
                .iter()
                .any(|id| row["funti_id"] == *id && !local.iter().any(|(current, _)| current == id))
        })
        .cloned()
        .collect();
    for (id, name) in local {
        if merged.len() < 128
            && library_id(id)
            && !previous.contains(id)
            && !merged.iter().any(|row| row["funti_id"] == *id)
        {
            merged.push(serde_json::json!({"funti_id":id,"name":name}));
        }
    }
    merged
}

/// Import only the address, label and last-use time from a local recent peer.
pub fn local_history_entry(
    account: &str,
    source: &str,
    id: &str,
    name: &str,
    connected_at: i64,
    now: i64,
) -> Option<Value> {
    if !token(account)
        || !token(source)
        || !library_id(id)
        || name.len() > 256
        || name.chars().any(char::is_control)
        || connected_at <= now - 90 * 86400
        || connected_at > now + 300
    {
        return None;
    }
    Some(serde_json::json!({
        "event_id": payload_hash(&serde_json::json!(["local-history-v1", account, source, id, connected_at])).ok()?,
        "funti_id": id, "name": name, "connected_at": connected_at
    }))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Nonce {
    pub nonce: String,
    pub account_id: String,
    pub device_id: Option<String>,
    pub action: String,
    pub funti_id: String,
    pub pk: String,
    pub payload_hash: String,
    pub expires_at: i64,
}

impl Nonce {
    #[allow(clippy::too_many_arguments)]
    pub fn message(
        &self,
        action: &str,
        account: &str,
        device: Option<&str>,
        funti_id: &str,
        pk: &str,
        hash: &str,
        now: i64,
    ) -> Option<Vec<u8>> {
        if !token(&self.nonce)
            || !token(account)
            || self.action != action
            || self.account_id != account
            || self.device_id.as_deref() != device
            || self.funti_id != funti_id
            || self.pk != pk
            || self.payload_hash != hash
            || self.expires_at <= now
            // The server gives a nonce 300 seconds. Allow up to 300 seconds of
            // local clock lag; the server still enforces its expiry and one use.
            || self.expires_at > now + 600
            || !["bind", "family", "sync", "ack"].contains(&action)
        {
            return None;
        }
        Some(if action == "bind" && device.is_none() && hash.is_empty() {
            format!("funtidesk-account-v1\nbind\n{account}\n{funti_id}\n{pk}\n{}\n{}", self.nonce, self.expires_at)
        } else if action != "bind" && device.map(token) == Some(true) && token(hash) {
            format!("funtidesk-account-v1\n{action}\n{account}\n{}\n{funti_id}\n{pk}\n{hash}\n{}\n{}", device.unwrap_or_default(), self.nonce, self.expires_at)
        } else {
            return None;
        }.into_bytes())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Event {
    pub event_id: i64,
    pub kind: String,
    pub target_pk: String,
    pub created_at: i64,
}

#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Ledger {
    pub after: i64,
    pub pending_ack: Vec<i64>,
    pub notices: Vec<Event>,
}

/// Called under the family mutation lock and saved with the family list.
pub fn apply_events<T>(
    family: &mut Vec<T>,
    key: impl Fn(&T) -> &str,
    ledger: &mut Ledger,
    events: &[Event],
) -> Result<Vec<String>, &'static str> {
    if events.len() > 128 || ledger.after < 0 || ledger.pending_ack.len() > 128 {
        return Err("invalid_events");
    }
    let mut last = 0;
    for event in events {
        if event.event_id <= last || event.created_at <= 0 {
            return Err("invalid_events");
        }
        last = event.event_id;
        if event.kind == "remove" {
            if !canonical_pk(&event.target_pk) {
                return Err("invalid_events");
            }
        } else if event.kind != "login" || !event.target_pk.is_empty() {
            return Err("invalid_events");
        }
    }
    let fresh = events.iter().filter(|e| e.event_id > ledger.after).count();
    if fresh + ledger.pending_ack.len() > 128 {
        return Err("ack_required");
    }
    let mut removed = Vec::new();
    for event in events {
        if event.event_id <= ledger.after {
            continue;
        }
        if event.kind == "remove" {
            family.retain(|member| key(member) != event.target_pk);
            removed.push(event.target_pk.clone());
        }
        ledger.after = event.event_id;
        ledger.pending_ack.push(event.event_id);
        ledger.notices.push(event.clone());
    }
    let excess = ledger.notices.len().saturating_sub(20);
    ledger.notices.drain(..excess);
    Ok(removed)
}

fn canonical_pk(value: &str) -> bool {
    // Canonical padded standard Base64 for exactly 32 bytes.
    value.len() == 44
        && value.as_bytes()[43] == b'='
        && value.as_bytes()[..43]
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || *b == b'+' || *b == b'/')
        && "AEIMQUYcgkosw048".contains(value.as_bytes()[42] as char)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nonce_is_bound_to_every_locally_expected_field() {
        let account = "a".repeat(64);
        let device = "b".repeat(64);
        let hash = "c".repeat(64);
        let mut nonce = Nonce {
            nonce: "d".repeat(64),
            account_id: account.clone(),
            device_id: Some(device.clone()),
            action: "sync".into(),
            funti_id: "111111".into(),
            pk: "local-key".into(),
            payload_hash: hash.clone(),
            expires_at: 1300,
        };
        let check = |n: &Nonce| {
            n.message(
                "sync",
                &account,
                Some(&device),
                "111111",
                "local-key",
                &hash,
                1000,
            )
        };
        assert!(check(&nonce).is_some());
        nonce.action = "family".into();
        assert!(check(&nonce).is_none());
        nonce.action = "sync".into();
        nonce.payload_hash = "e".repeat(64);
        assert!(check(&nonce).is_none());
        nonce.payload_hash = hash.clone();
        nonce.expires_at = 1601;
        assert!(check(&nonce).is_none());
    }

    #[test]
    fn removal_matches_key_and_replay_preserves_explicit_new_pairing() {
        let old = "A".repeat(43) + "=";
        let new = "B".repeat(42) + "A=";
        let mut family = vec![("111111", old.clone()), ("111111", new.clone())];
        let mut ledger = Ledger::default();
        let event = Event {
            event_id: 7,
            kind: "remove".into(),
            target_pk: old.clone(),
            created_at: 1000,
        };
        apply_events(
            &mut family,
            |m| &m.1,
            &mut ledger,
            std::slice::from_ref(&event),
        )
        .unwrap();
        assert_eq!(family, vec![("111111", new.clone())]);
        // Persist and reload exactly the marker the service stores with the family.
        ledger = serde_json::from_str(&serde_json::to_string(&ledger).unwrap()).unwrap();
        family.push(("222222", old.clone()));
        apply_events(&mut family, |m| &m.1, &mut ledger, &[event]).unwrap();
        assert_eq!(family.len(), 2);
        assert_eq!(ledger.pending_ack, vec![7]);
        let next = Event {
            event_id: 8,
            kind: "remove".into(),
            target_pk: old,
            created_at: 1001,
        };
        apply_events(&mut family, |m| &m.1, &mut ledger, &[next]).unwrap();
        assert_eq!(family, vec![("111111", new)]);
    }

    #[test]
    fn invalid_batch_never_partially_mutates_family_or_cursor() {
        let pk = "A".repeat(43) + "=";
        let mut family = vec![pk.clone()];
        let mut ledger = Ledger::default();
        let events = vec![
            Event {
                event_id: 1,
                kind: "remove".into(),
                target_pk: pk.clone(),
                created_at: 1000,
            },
            Event {
                event_id: 2,
                kind: "add".into(),
                target_pk: pk.clone(),
                created_at: 1000,
            },
        ];
        assert!(apply_events(&mut family, |m| m.as_str(), &mut ledger, &events).is_err());
        assert_eq!(family, vec![pk]);
        assert_eq!(ledger.after, 0);
    }
}
