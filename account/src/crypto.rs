use anyhow::{bail, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use ed25519_dalek::{Signature, VerifyingKey};
use hmac::{Hmac, Mac};
use rand::{rngs::OsRng, Rng, RngCore};
use sha2::{Digest, Sha256};

pub fn token() -> String {
    let mut bytes = [0_u8; 32];
    OsRng.fill_bytes(&mut bytes);
    hex::encode(bytes)
}

pub fn code() -> String {
    format!("{:06}", OsRng.gen_range(0..1_000_000_u32))
}

pub fn digest(value: &[u8]) -> String {
    hex::encode(Sha256::digest(value))
}

pub fn tag(key: &[u8; 32], purpose: &str, values: &[&str]) -> String {
    // HMAC accepts every key length; this fixed-size constructor cannot fail.
    let Ok(mut mac) = Hmac::<Sha256>::new_from_slice(key) else {
        return String::new();
    };
    for value in std::iter::once(purpose).chain(values.iter().copied()) {
        mac.update(&(value.len() as u64).to_be_bytes());
        mac.update(value.as_bytes());
    }
    hex::encode(mac.finalize().into_bytes())
}

pub fn matches(key: &[u8; 32], purpose: &str, values: &[&str], expected: &str) -> bool {
    let (Ok(mut mac), Ok(expected)) = (Hmac::<Sha256>::new_from_slice(key), hex::decode(expected))
    else {
        return false;
    };
    for value in std::iter::once(purpose).chain(values.iter().copied()) {
        mac.update(&(value.len() as u64).to_be_bytes());
        mac.update(value.as_bytes());
    }
    mac.verify_slice(&expected).is_ok()
}

pub fn is_token(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}

pub fn valid_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

pub fn public_key(value: &str) -> Result<[u8; 32]> {
    let bytes: [u8; 32] = STANDARD
        .decode(value)?
        .try_into()
        .map_err(|_| anyhow::anyhow!("invalid key"))?;
    if STANDARD.encode(bytes) != value || VerifyingKey::from_bytes(&bytes)?.is_weak() {
        bail!("invalid key");
    }
    Ok(bytes)
}

pub fn signature(pk: &str, message: &[u8], encoded: &str) -> bool {
    let Ok(bytes) = public_key(pk) else {
        return false;
    };
    let (Ok(key), Ok(bytes)) = (VerifyingKey::from_bytes(&bytes), STANDARD.decode(encoded)) else {
        return false;
    };
    let Ok(sig) = Signature::from_slice(&bytes) else {
        return false;
    };
    key.verify_strict(message, &sig).is_ok()
}
