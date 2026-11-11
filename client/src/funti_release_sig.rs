//! FUNTIDESK (ADR-018): the signature of a release. The owner signs
//! SHA256SUMS.txt on his own computer with
//! `ssh-keygen -Y sign -n funtidesk-release`; the private key is never on
//! GitHub. This checks that OpenSSH signature (PROTOCOL.sshsig) against the
//! public keys built into the client: Ed25519 over SHA-512 only.

use hbb_common::sodiumoxide::{
    base64,
    crypto::{hash::sha512, sign},
};

/// What the signature is for; a signature made for anything else is refused.
pub const NAMESPACE: &str = "funtidesk-release";

/// Public keys that may sign a release (the 32 bytes of an ssh-ed25519 key).
/// More than one only while a key is being replaced. Empty until the owner's
/// first key is added: releases are then checked by SHA-256 alone, as before.
pub const RELEASE_KEYS: &[[u8; 32]] = &[];

const MAGIC: &[u8] = b"SSHSIG";
const KEY_TYPE: &[u8] = b"ssh-ed25519";
const HASH: &[u8] = b"sha512";
const BEGIN: &str = "-----BEGIN SSH SIGNATURE-----";
const END: &str = "-----END SSH SIGNATURE-----";
const MAX_ARMORED: usize = 4096;

struct Reader<'a>(&'a [u8]);

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        if self.0.len() < n {
            return None;
        }
        let (head, rest) = self.0.split_at(n);
        self.0 = rest;
        Some(head)
    }

    fn u32(&mut self) -> Option<u32> {
        let b = self.take(4)?;
        Some(u32::from_be_bytes([b[0], b[1], b[2], b[3]]))
    }

    fn string(&mut self) -> Option<&'a [u8]> {
        let n = self.u32()? as usize;
        self.take(n)
    }
}

fn put_string(out: &mut Vec<u8>, value: &[u8]) {
    out.extend_from_slice(&(value.len() as u32).to_be_bytes());
    out.extend_from_slice(value);
}

/// "ssh-ed25519" and one more field of exactly `N` bytes, nothing after.
fn typed<const N: usize>(blob: &[u8]) -> Option<[u8; N]> {
    let mut r = Reader(blob);
    if r.string()? != KEY_TYPE {
        return None;
    }
    let value: [u8; N] = r.string()?.try_into().ok()?;
    r.0.is_empty().then_some(value)
}

/// True when `armored` is a signature of `message` for `namespace` made by
/// one of `keys`.
pub fn verify(armored: &str, message: &[u8], namespace: &str, keys: &[[u8; 32]]) -> bool {
    verify_(armored, message, namespace, keys).unwrap_or(false)
}

fn verify_(armored: &str, message: &[u8], namespace: &str, keys: &[[u8; 32]]) -> Option<bool> {
    if armored.len() > MAX_ARMORED {
        return None;
    }
    let body = armored.trim().strip_prefix(BEGIN)?.strip_suffix(END)?;
    let body: String = body.chars().filter(|c| !c.is_ascii_whitespace()).collect();
    let blob = base64::decode(body, base64::Variant::Original).ok()?;
    let mut r = Reader(&blob);
    if r.take(MAGIC.len())? != MAGIC || r.u32()? != 1 {
        return None;
    }
    let pk: [u8; 32] = typed(r.string()?)?;
    let signed_namespace = r.string()?;
    let reserved = r.string()?;
    let hash = r.string()?;
    let signature: [u8; 64] = typed(r.string()?)?;
    if !r.0.is_empty()
        || signed_namespace != namespace.as_bytes()
        || !reserved.is_empty()
        || hash != HASH
        || !keys.contains(&pk)
    {
        return None;
    }
    let mut signed = MAGIC.to_vec();
    put_string(&mut signed, signed_namespace);
    put_string(&mut signed, reserved);
    put_string(&mut signed, hash);
    put_string(&mut signed, sha512::hash(message).as_ref());
    let pk = sign::PublicKey::from_slice(&pk)?;
    let signature = sign::Signature::try_from(&signature[..]).ok()?;
    Some(sign::verify_detached(&signature, &signed, &pk))
}

/// The 32 key bytes of an `ssh-ed25519 AAAA... comment` line.
pub fn parse_public_key(line: &str) -> Option<[u8; 32]> {
    let mut parts = line.split_whitespace();
    if parts.next()?.as_bytes() != KEY_TYPE {
        return None;
    }
    typed(&base64::decode(parts.next()?, base64::Variant::Original).ok()?)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Made with OpenSSH 9.6: `ssh-keygen -t ed25519`, then
    // `ssh-keygen -Y sign -f key -n funtidesk-release SHA256SUMS.txt`.
    const PUBLIC: &str =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOhsnml13nPgGlrw4xmvvXm0LEYNwDjsa8rmYBo6J8Ck test";
    const MESSAGE: &[u8] = b"abc  FuntiDesk-windows-x64.zip\n";
    const SIGNATURE: &str = "-----BEGIN SSH SIGNATURE-----
U1NIU0lHAAAAAQAAADMAAAALc3NoLWVkMjU1MTkAAAAg6GyeaXXec+AaWvDjGa+9ebQsRg
3AOOxryuZgGjonwKQAAAARZnVudGlkZXNrLXJlbGVhc2UAAAAAAAAABnNoYTUxMgAAAFMA
AAALc3NoLWVkMjU1MTkAAABA9vO3ZL6BE8sMxK7/t8w6LuZeA9blOUOl70C5u2CxpGyNt+
vVFnfSSeG72bR617P8hXKPe020JZTuBYMcz+B2Bg==
-----END SSH SIGNATURE-----
";

    fn key() -> [u8; 32] {
        parse_public_key(PUBLIC).unwrap()
    }

    #[test]
    fn openssh_signature_is_accepted() {
        assert!(verify(SIGNATURE, MESSAGE, NAMESPACE, &[key()]));
        assert!(verify(SIGNATURE, MESSAGE, NAMESPACE, &[[1; 32], key()]));
        assert!(verify(
            &SIGNATURE.replace('\n', "\r\n"),
            MESSAGE,
            NAMESPACE,
            &[key()]
        ));
    }

    #[test]
    fn anything_else_is_refused() {
        let k = [key()];
        // Another file, another purpose, another or no key.
        assert!(!verify(
            SIGNATURE,
            b"abd  FuntiDesk-windows-x64.zip\n",
            NAMESPACE,
            &k
        ));
        assert!(!verify(SIGNATURE, MESSAGE, "file", &k));
        assert!(!verify(SIGNATURE, MESSAGE, NAMESPACE, &[[1; 32]]));
        assert!(!verify(SIGNATURE, MESSAGE, NAMESPACE, &[]));
        // A changed signature, a cut one, junk, and one that is too long.
        assert!(!verify(
            &SIGNATURE.replace("9vO3", "9vO4"),
            MESSAGE,
            NAMESPACE,
            &k
        ));
        assert!(!verify(
            &SIGNATURE[..SIGNATURE.len() / 2],
            MESSAGE,
            NAMESPACE,
            &k
        ));
        assert!(!verify("", MESSAGE, NAMESPACE, &k));
        assert!(!verify(
            "-----BEGIN SSH SIGNATURE-----\n-----END SSH SIGNATURE-----",
            MESSAGE,
            NAMESPACE,
            &k
        ));
        assert!(!verify(
            &format!("{SIGNATURE}{}", " ".repeat(MAX_ARMORED)),
            MESSAGE,
            NAMESPACE,
            &k
        ));
    }

    #[test]
    fn public_key_line() {
        assert!(parse_public_key(PUBLIC).is_some());
        assert!(parse_public_key("ssh-rsa AAAAB3NzaC1yc2E test").is_none());
        assert!(parse_public_key("ssh-ed25519 AAAA").is_none());
        assert!(parse_public_key("").is_none());
    }
}
