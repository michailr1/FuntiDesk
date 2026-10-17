use crate::{
    config::{CODE_TTL, SESSION_TTL},
    crypto,
};
use anyhow::{bail, Result};
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use serde::Serialize;
use std::{fs::File, path::Path, time::Duration};

pub struct Store {
    pub(crate) db: Connection,
    pub(crate) key: [u8; 32],
    _file_lock: Option<File>,
}

#[derive(Clone)]
pub struct Auth {
    pub account: String,
    pub hash: String,
    pub browser: bool,
}

#[derive(Serialize)]
pub struct SessionInfo {
    pub account_id: String,
    pub email: String,
    pub expires_at: i64,
}

pub struct Issued {
    pub token: String,
    pub account: String,
}

pub enum SessionRequest<'a> {
    Native,
    Browser { previous_hash: Option<&'a str> },
}

impl Store {
    pub fn open(path: &Path, key: [u8; 32]) -> Result<Self> {
        let mut options = std::fs::OpenOptions::new();
        options.create(true).truncate(false).read(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let lock = options.open(path.with_extension("lock"))?;
        fs2::FileExt::try_lock_exclusive(&lock)?;
        #[cfg(unix)]
        {
            use std::{
                fs::OpenOptions,
                os::unix::fs::{OpenOptionsExt, PermissionsExt},
            };
            OpenOptions::new()
                .create(true)
                .truncate(false)
                .read(true)
                .write(true)
                .mode(0o600)
                .open(path)?;
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
        }
        let mut store = Self::from_connection(Connection::open(path)?, key)?;
        store._file_lock = Some(lock);
        Ok(store)
    }

    pub fn memory(key: [u8; 32]) -> Result<Self> {
        Self::from_connection(Connection::open_in_memory()?, key)
    }

    fn from_connection(db: Connection, key: [u8; 32]) -> Result<Self> {
        db.busy_timeout(Duration::from_secs(5))?;
        db.execute_batch(
            "PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA secure_delete=ON;",
        )?;
        let version: i64 = db.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        if version > 4 {
            bail!("unsupported database version");
        }
        if version == 0 {
            db.execute_batch(include_str!("schema.sql"))?;
        }
        if version < 3 {
            db.execute_batch(include_str!("schema-library.sql"))?;
        }
        if version < 4 {
            db.execute_batch(include_str!("schema-local.sql"))?;
        }
        Ok(Self {
            db,
            key,
            _file_lock: None,
        })
    }

    pub fn begin_login(
        &mut self,
        email: &str,
        scope: &str,
        ip: &str,
        code: &str,
        now: i64,
    ) -> Result<Option<String>> {
        let id = crypto::token();
        let email_tag = crypto::tag(&self.key, "email-index", &[email]);
        let scope_tag = crypto::tag(&self.key, "login-scope", &[scope]);
        let ip_tag = crypto::tag(&self.key, "ip-index", &[ip]);
        let code_tag = crypto::tag(&self.key, "email-code", &[&id, &scope_tag, code]);
        let tx = self.db.transaction()?;
        let allowed = quotas(
            &tx,
            now,
            &[
                ("send:global", 60, 20),
                ("send:global", 3600, 200),
                (&format!("send:ip:{ip_tag}"), 60, 5),
                (&format!("send:ip:{ip_tag}"), 3600, 30),
                (&format!("send:email:{email_tag}"), 60, 1),
                (&format!("send:email:{email_tag}"), 3600, 5),
                (&format!("send:scope:{scope_tag}"), 60, 1),
                (&format!("send:scope:{scope_tag}"), 3600, 5),
            ],
        )?;
        if !allowed {
            tx.commit()?;
            return Ok(None);
        }
        tx.execute(
            "UPDATE challenges SET pending=0 WHERE scope_hash=?1 AND pending=1",
            [&scope_tag],
        )?;
        tx.execute("DELETE FROM challenges WHERE expires_at < ?1", [now - 3600])?;
        tx.execute("INSERT INTO challenges(id,email,email_hash,scope_hash,code_hash,expires_at) VALUES (?1,?2,?3,?4,?5,?6)", params![id, email, email_tag, scope_tag, code_tag, now + CODE_TTL])?;
        tx.commit()?;
        Ok(Some(id))
    }

    pub fn cancel_challenge(&mut self, id: &str) -> Result<()> {
        self.db
            .execute("UPDATE challenges SET pending=0 WHERE id=?1", [id])?;
        Ok(())
    }

    pub fn challenge_pending(&self, id: &str, now: i64) -> Result<bool> {
        Ok(self.db.query_row(
            "SELECT EXISTS(SELECT 1 FROM challenges WHERE id=?1 AND pending=1 AND expires_at>?2)",
            params![id, now],
            |r| r.get(0),
        )?)
    }

    pub fn maintain(&mut self, now: i64) -> Result<()> {
        let tx = self.db.transaction()?;
        tx.execute("DELETE FROM challenges WHERE expires_at<=?1", [now])?;
        tx.execute("DELETE FROM nonces WHERE expires_at<=?1", [now])?;
        tx.execute(
            "DELETE FROM connection_history WHERE connected_at<=?1",
            [now - 90 * 86400],
        )?;
        tx.execute("DELETE FROM sessions WHERE expires_at<=?1", [now])?;
        tx.execute(
            "DELETE FROM rate_limits WHERE window_start<?1",
            [now - 86400],
        )?;
        tx.commit()?;
        Ok(())
    }

    pub fn verify_login(
        &mut self,
        id: &str,
        scope: &str,
        code: &str,
        ip: &str,
        session: SessionRequest<'_>,
        now: i64,
    ) -> Result<Option<Issued>> {
        let (browser, old_hash) = match session {
            SessionRequest::Native => (false, None),
            SessionRequest::Browser { previous_hash } => (true, previous_hash),
        };
        let scope_hash = crypto::tag(&self.key, "login-scope", &[scope]);
        let ip_hash = crypto::tag(&self.key, "ip-index", &[ip]);
        let tx = self.db.transaction()?;
        if !quotas(
            &tx,
            now,
            &[
                ("verify:global", 60, 100),
                (&format!("verify:ip:{ip_hash}"), 60, 30),
            ],
        )? {
            tx.commit()?;
            return Ok(None);
        }
        let challenge = tx.query_row("SELECT email,email_hash,scope_hash,code_hash,expires_at,attempts,pending FROM challenges WHERE id=?1", [id], |r| Ok((r.get::<_,String>(0)?, r.get::<_,String>(1)?, r.get::<_,String>(2)?, r.get::<_,String>(3)?, r.get::<_,i64>(4)?, r.get::<_,i64>(5)?, r.get::<_,i64>(6)?))).optional()?;
        let Some((email, email_hash, context, hash, expiry, attempts, pending)) = challenge else {
            tx.commit()?;
            return Ok(None);
        };
        if context != scope_hash || expiry <= now || attempts >= 5 || pending != 1 {
            tx.commit()?;
            return Ok(None);
        }
        if !quotas(
            &tx,
            now,
            &[(&format!("verify:email:{email_hash}"), 3600, 20)],
        )? {
            tx.commit()?;
            return Ok(None);
        }
        let valid = code.len() == 6
            && code.bytes().all(|b| b.is_ascii_digit())
            && crypto::matches(&self.key, "email-code", &[id, &scope_hash, code], &hash);
        tx.execute("UPDATE challenges SET attempts=attempts+1, pending=CASE WHEN attempts>=4 OR ?2=1 THEN 0 ELSE pending END WHERE id=?1", params![id, valid as i64])?;
        if !valid {
            tx.commit()?;
            return Ok(None);
        }
        let account = tx
            .query_row(
                "SELECT id FROM accounts WHERE email=?1 AND disabled=0",
                [&email],
                |r| r.get::<_, String>(0),
            )
            .optional()?;
        let account = match account {
            Some(id) => id,
            None => {
                let exists: bool = tx.query_row(
                    "SELECT EXISTS(SELECT 1 FROM accounts WHERE email=?1)",
                    [&email],
                    |r| r.get(0),
                )?;
                if exists {
                    tx.commit()?;
                    return Ok(None);
                }
                let id = crypto::token();
                tx.execute(
                    "INSERT INTO accounts(id,email,created_at) VALUES(?1,?2,?3)",
                    params![id, email, now],
                )?;
                id
            }
        };
        let count: i64 = tx.query_row("SELECT COUNT(*) FROM sessions WHERE account_id=?1 AND revoked_at IS NULL AND expires_at>?2 AND NOT (token_hash=?3 AND browser=1)", params![account,now,old_hash.unwrap_or("")], |r| r.get(0))?;
        if count >= 20 {
            tx.commit()?;
            return Ok(None);
        }
        if let Some(hash) = old_hash {
            tx.execute(
                "UPDATE sessions SET revoked_at=?2 WHERE token_hash=?1 AND browser=1",
                params![hash, now],
            )?;
        }
        let token = crypto::token();
        tx.execute("INSERT INTO sessions(token_hash,account_id,browser,created_at,expires_at) VALUES(?1,?2,?3,?4,?5)", params![crypto::digest(token.as_bytes()),account,browser,now,now+SESSION_TTL])?;
        new_event(&tx, &account, "login", "", now)?;
        tx.commit()?;
        Ok(Some(Issued { token, account }))
    }

    pub fn authenticate(&self, raw: &str, browser: bool, now: i64) -> Result<Option<Auth>> {
        if !crypto::is_token(raw) {
            return Ok(None);
        }
        let hash = crypto::digest(raw.as_bytes());
        let account = self.db.query_row("SELECT s.account_id FROM sessions s JOIN accounts a ON a.id=s.account_id WHERE s.token_hash=?1 AND s.browser=?2 AND s.revoked_at IS NULL AND s.expires_at>?3 AND a.disabled=0", params![hash,browser,now], |r| r.get::<_,String>(0)).optional()?;
        Ok(account.map(|account| Auth {
            account,
            hash,
            browser,
        }))
    }

    pub fn active(&self, auth: &Auth, now: i64) -> Result<bool> {
        active_in(&self.db, auth, now)
    }

    pub fn session(&self, auth: &Auth, now: i64) -> Result<Option<SessionInfo>> {
        if !self.active(auth, now)? {
            return Ok(None);
        }
        Ok(Some(self.db.query_row("SELECT a.email,s.expires_at FROM accounts a JOIN sessions s ON s.account_id=a.id WHERE s.token_hash=?1", [&auth.hash], |r| Ok(SessionInfo { account_id: auth.account.clone(), email: r.get(0)?, expires_at:r.get(1)? }))?))
    }

    pub fn logout(&mut self, auth: &Auth, all: bool, now: i64) -> Result<bool> {
        let tx = self.db.transaction()?;
        if !active_in(&tx, auth, now)? {
            return Ok(false);
        }
        if all {
            tx.execute(
                "UPDATE sessions SET revoked_at=?2 WHERE account_id=?1 AND revoked_at IS NULL",
                params![auth.account, now],
            )?;
        } else {
            tx.execute(
                "UPDATE sessions SET revoked_at=?2 WHERE token_hash=?1",
                params![auth.hash, now],
            )?;
        }
        tx.commit()?;
        Ok(true)
    }
}

pub(crate) fn active_in(db: &Connection, auth: &Auth, now: i64) -> Result<bool> {
    Ok(db.query_row("SELECT EXISTS(SELECT 1 FROM sessions s JOIN accounts a ON a.id=s.account_id WHERE s.token_hash=?1 AND s.account_id=?2 AND s.browser=?3 AND s.revoked_at IS NULL AND s.expires_at>?4 AND a.disabled=0)", params![auth.hash,auth.account,auth.browser,now], |r| r.get(0))?)
}

pub(crate) fn quotas(tx: &Transaction<'_>, now: i64, rules: &[(&str, i64, i64)]) -> Result<bool> {
    tx.execute(
        "DELETE FROM rate_limits WHERE window_start < ?1",
        [now - 86400],
    )?;
    for (name, period, max) in rules {
        let start = now / period * period;
        let count: i64 = tx
            .query_row(
                "SELECT count FROM rate_limits WHERE name=?1 AND period=?2 AND window_start=?3",
                params![name, period, start],
                |r| r.get(0),
            )
            .optional()?
            .unwrap_or(0);
        if count >= *max {
            return Ok(false);
        }
    }
    for (name, period, _) in rules {
        let start = now / period * period;
        tx.execute("INSERT INTO rate_limits(name,period,window_start,count) VALUES(?1,?2,?3,1) ON CONFLICT(name,period,window_start) DO UPDATE SET count=count+1", params![name,period,start])?;
    }
    Ok(true)
}

pub(crate) fn new_event(
    tx: &Transaction<'_>,
    account: &str,
    kind: &str,
    target: &str,
    now: i64,
) -> Result<i64> {
    tx.execute(
        "INSERT INTO events(account_id,kind,target_pk,created_at) VALUES(?1,?2,?3,?4)",
        params![account, kind, target, now],
    )?;
    let id = tx.last_insert_rowid();
    tx.execute(
        "INSERT INTO deliveries(event_id,device_id) SELECT ?1,id FROM devices WHERE account_id=?2",
        params![id, account],
    )?;
    Ok(id)
}
