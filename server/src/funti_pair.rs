// FUNTIDESK (ADR-008): pairing by code alone.
//
// The computer showing a pairing code registers "code -> its ID" here, signed
// with its device key (the key it registered for that ID). The computer that
// enters the code looks the ID up. Codes live 5 minutes, in memory only, and
// are dropped after the first successful lookup. Lookups are limited per
// address, and wrong codes for the whole server: at most WRONG_PER_MINUTE,
// so even a botnet checks at most ~500 of a million codes while one lives
// (owner decision 2026-10-12, instead of a confirmation on the computer).

use hbb_common::rendezvous_proto::{funti_pair_response, FuntiPairOffer};
use sodiumoxide::crypto::sign;
use std::{
    collections::HashMap,
    net::IpAddr,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

pub const CODE_TTL: Duration = Duration::from_secs(300);
const OFFER_MAX_SKEW_SECS: i64 = 300;
const LOOKUPS_PER_MINUTE: usize = 5;
const LOOKUPS_PER_HOUR: usize = 30;
/// Wrong codes from all addresses together.
const WRONG_PER_MINUTE: usize = 100;

/// What the offering device signs. Must match the client (funti_family.rs).
pub fn offer_message(id: &str, code: &str, time: i64) -> Vec<u8> {
    format!("funtidesk-pair-offer-v1\n{id}\n{code}\n{time}").into_bytes()
}

fn is_code(code: &str) -> bool {
    code.len() == 6 && code.bytes().all(|b| b.is_ascii_digit())
}

/// Signature over a fresh offer, by the device key registered for the ID.
pub fn verify_offer(pk: &[u8], offer: &FuntiPairOffer) -> bool {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or_default();
    if !is_code(&offer.code) || (now - offer.time).abs() > OFFER_MAX_SKEW_SECS {
        return false;
    }
    let (Some(pk), Ok(sig)) = (
        sign::PublicKey::from_slice(pk),
        sign::Signature::try_from(&offer.signature[..]),
    ) else {
        return false;
    };
    sign::verify_detached(&sig, &offer_message(&offer.id, &offer.code, offer.time), &pk)
}

#[derive(Default)]
pub struct PairCodes {
    codes: HashMap<String, (String, Instant)>,
    by_id: HashMap<String, String>,
    lookups: HashMap<IpAddr, Vec<Instant>>,
    wrong: Vec<Instant>,
}

impl PairCodes {
    fn prune(&mut self) {
        let by_id = &mut self.by_id;
        self.codes.retain(|_, (id, at)| {
            let alive = at.elapsed() < CODE_TTL;
            if !alive {
                by_id.remove(id);
            }
            alive
        });
        self.lookups.retain(|_, times| {
            times.retain(|t| t.elapsed() < Duration::from_secs(3600));
            !times.is_empty()
        });
        self.wrong.retain(|t| t.elapsed() < Duration::from_secs(60));
    }

    /// Registers a verified offer; a new code from the same ID replaces the
    /// old one. False when another computer holds the same code right now.
    pub fn offer(&mut self, id: &str, code: &str) -> bool {
        self.prune();
        if let Some(old) = self.by_id.remove(id) {
            self.codes.remove(&old);
        }
        if self.codes.contains_key(code) {
            return false;
        }
        self.codes.insert(code.to_owned(), (id.to_owned(), Instant::now()));
        self.by_id.insert(id.to_owned(), code.to_owned());
        true
    }

    /// One lookup from `ip`: the ID for `code`, used up on success.
    pub fn lookup(&mut self, ip: IpAddr, code: &str) -> Result<String, funti_pair_response::Result> {
        self.prune();
        let times = self.lookups.entry(ip).or_default();
        let last_minute = times
            .iter()
            .filter(|t| t.elapsed() < Duration::from_secs(60))
            .count();
        if last_minute >= LOOKUPS_PER_MINUTE
            || times.len() >= LOOKUPS_PER_HOUR
            || self.wrong.len() >= WRONG_PER_MINUTE
        {
            return Err(funti_pair_response::Result::TOO_MANY_ATTEMPTS);
        }
        times.push(Instant::now());
        match self.codes.remove(code).filter(|_| is_code(code)) {
            Some((id, _)) => {
                self.by_id.remove(&id);
                Ok(id)
            }
            None => {
                self.wrong.push(Instant::now());
                Err(funti_pair_response::Result::NOT_FOUND)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn code_is_one_time_and_per_id() {
        let mut p = PairCodes::default();
        let ip: IpAddr = "1.2.3.4".parse().unwrap();
        assert!(p.offer("111", "123456"));
        assert!(!p.offer("222", "123456"));
        assert!(p.offer("111", "654321"));
        assert_eq!(p.lookup(ip, "123456"), Err(funti_pair_response::Result::NOT_FOUND));
        assert_eq!(p.lookup(ip, "654321"), Ok("111".to_owned()));
        assert_eq!(p.lookup(ip, "654321"), Err(funti_pair_response::Result::NOT_FOUND));
    }

    #[test]
    fn lookups_are_limited() {
        let mut p = PairCodes::default();
        let ip: IpAddr = "1.2.3.4".parse().unwrap();
        for _ in 0..LOOKUPS_PER_MINUTE {
            assert!(p.lookup(ip, "000000").is_err());
        }
        assert!(p.offer("111", "123456"));
        assert_eq!(
            p.lookup(ip, "123456"),
            Err(funti_pair_response::Result::TOO_MANY_ATTEMPTS)
        );
        let other: IpAddr = "5.6.7.8".parse().unwrap();
        assert_eq!(p.lookup(other, "123456"), Ok("111".to_owned()));
    }

    #[test]
    fn wrong_codes_are_limited_for_the_whole_server() {
        let mut p = PairCodes::default();
        for i in 0..WRONG_PER_MINUTE {
            let ip: IpAddr = format!("10.0.{}.{}", i / 250, i % 250).parse().unwrap();
            assert_eq!(p.lookup(ip, "000000"), Err(funti_pair_response::Result::NOT_FOUND));
        }
        assert!(p.offer("111", "123456"));
        let fresh: IpAddr = "9.9.9.9".parse().unwrap();
        assert_eq!(
            p.lookup(fresh, "123456"),
            Err(funti_pair_response::Result::TOO_MANY_ATTEMPTS)
        );
    }

    #[test]
    fn offer_signature() {
        let (pk, sk) = sign::gen_keypair();
        let time = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs() as i64;
        let mut offer = FuntiPairOffer {
            id: "111".to_owned(),
            code: "123456".to_owned(),
            time,
            ..Default::default()
        };
        offer.signature = sign::sign_detached(&offer_message("111", "123456", time), &sk)
            .to_bytes()
            .to_vec()
            .into();
        assert!(verify_offer(&pk.0, &offer));
        offer.code = "123457".to_owned();
        assert!(!verify_offer(&pk.0, &offer));
    }
}
