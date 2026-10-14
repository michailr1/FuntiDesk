use anyhow::{bail, Context, Result};
use std::{
    net::{IpAddr, SocketAddr},
    path::PathBuf,
};

pub const ORIGIN: &str = "https://desk.funti.cc";
pub const API: &str = "/api/account/v1";
pub const SESSION_COOKIE: &str = "__Host-funti-account";
pub const LOGIN_COOKIE: &str = "__Host-funti-login";
pub const CODE_TTL: i64 = 300;
pub const SESSION_TTL: i64 = 30 * 24 * 60 * 60;

pub struct Config {
    pub listen: SocketAddr,
    pub database: PathBuf,
    pub key: [u8; 32],
    pub registry_socket: PathBuf,
    pub smtp_host: String,
    pub smtp_port: u16,
    pub trusted_proxies: Vec<IpAddr>,
}

impl Config {
    pub fn from_env() -> Result<Self> {
        let secret_path = PathBuf::from(
            std::env::var("FUNTI_ACCOUNT_KEY_FILE")
                .context("FUNTI_ACCOUNT_KEY_FILE is required")?,
        );
        let key = read_key(&secret_path)?;
        let proxies = std::env::var("FUNTI_ACCOUNT_TRUSTED_PROXIES")
            .unwrap_or_else(|_| "127.0.0.1,::1".to_owned());
        Ok(Self {
            listen: std::env::var("FUNTI_ACCOUNT_LISTEN")
                .unwrap_or_else(|_| "127.0.0.1:21800".to_owned())
                .parse()?,
            database: std::env::var("FUNTI_ACCOUNT_DATABASE")
                .unwrap_or_else(|_| "/data/account.sqlite3".to_owned())
                .into(),
            key,
            registry_socket: std::env::var("FUNTI_ACCOUNT_REGISTRY_SOCKET")
                .unwrap_or_else(|_| "/run/funtidesk-identity/hbbs.sock".to_owned())
                .into(),
            smtp_host: std::env::var("FUNTI_ACCOUNT_SMTP_HOST")
                .unwrap_or_else(|_| "funtidesk-mail".to_owned()),
            smtp_port: std::env::var("FUNTI_ACCOUNT_SMTP_PORT")
                .unwrap_or_else(|_| "2525".to_owned())
                .parse()?,
            trusted_proxies: proxies
                .split(',')
                .map(|p| p.trim().parse())
                .collect::<std::result::Result<_, _>>()?,
        })
    }
}

pub fn read_key(secret_path: &std::path::Path) -> Result<[u8; 32]> {
    let metadata = std::fs::metadata(secret_path)?;
    if !metadata.is_file() {
        bail!("account key must be a file");
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if metadata.permissions().mode() & 0o077 != 0 {
            bail!("account key permissions must exclude group and others");
        }
    }
    let bytes = hex::decode(std::fs::read_to_string(secret_path)?.trim())
        .context("invalid account key encoding")?;
    let key: [u8; 32] = bytes
        .try_into()
        .map_err(|_| anyhow::anyhow!("account key must contain 32 bytes"))?;
    Ok(key)
}
