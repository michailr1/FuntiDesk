//! Account lists never carry credentials or device trust.
use crate::{
    crypto,
    store::{active_in, quotas, Auth, Store},
    web::{self, ApiError, ApiResult},
    App,
};
use anyhow::Result;
use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    routing::{get, post},
    Json, Router,
};
use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

const HISTORY_TTL: i64 = 90 * 86400;
const MAX_FAVORITES: usize = 128;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Favorite {
    pub funti_id: String,
    pub name: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HistoryEntry {
    pub event_id: String,
    pub source_device_id: String,
    pub funti_id: String,
    pub name: String,
    pub connected_at: i64,
}
#[derive(Serialize)]
pub struct Library {
    pub revision: i64,
    pub history_epoch: i64,
    pub favorites: Vec<Favorite>,
    pub history: Vec<HistoryEntry>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FavoritesUpdate {
    pub revision: i64,
    pub favorites: Vec<Favorite>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HistoryUpdate {
    pub history_epoch: i64,
    pub entry: HistoryEntry,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HistoryClear {
    pub history_epoch: i64,
}

pub enum Change {
    Applied(Library),
    Conflict,
    Rejected,
    Limited,
}
fn name_valid(name: &str) -> bool {
    name.len() <= 256 && !name.chars().any(char::is_control)
}
fn favorites_valid(rows: &[Favorite]) -> bool {
    rows.len() <= MAX_FAVORITES
        && rows
            .iter()
            .all(|r| crypto::valid_id(&r.funti_id) && name_valid(&r.name))
        && rows
            .iter()
            .map(|r| &r.funti_id)
            .collect::<HashSet<_>>()
            .len()
            == rows.len()
}

impl Store {
    pub fn library(&self, auth: &Auth, now: i64) -> Result<Option<Library>> {
        if !self.active(auth, now)? {
            return Ok(None);
        }
        let (revision, history_epoch, favorites): (i64, i64, String) = self
            .db
            .query_row(
                "SELECT revision,history_epoch,favorites FROM account_library WHERE account_id=?1",
                [&auth.account],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?
            .unwrap_or((0, 0, "[]".into()));
        let mut stmt = self.db.prepare("SELECT event_id,source_device_id,funti_id,name,connected_at FROM connection_history WHERE account_id=?1 AND connected_at>?2 ORDER BY connected_at DESC,event_id DESC LIMIT 1000")?;
        let history = stmt
            .query_map(params![auth.account, now - HISTORY_TTL], |r| {
                Ok(HistoryEntry {
                    event_id: r.get(0)?,
                    source_device_id: r.get(1)?,
                    funti_id: r.get(2)?,
                    name: r.get(3)?,
                    connected_at: r.get(4)?,
                })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        Ok(Some(Library {
            revision,
            history_epoch,
            favorites: serde_json::from_str(&favorites)?,
            history,
        }))
    }

    pub fn favorites_update(
        &mut self,
        auth: &Auth,
        update: FavoritesUpdate,
        now: i64,
    ) -> Result<Change> {
        if update.revision < 0 || !favorites_valid(&update.favorites) {
            return Ok(Change::Rejected);
        }
        let tx = self.db.transaction()?;
        if !active_in(&tx, auth, now)? {
            return Ok(Change::Rejected);
        }
        tx.execute(
            "INSERT OR IGNORE INTO account_library(account_id) VALUES(?1)",
            [&auth.account],
        )?;
        let revision: i64 = tx.query_row(
            "SELECT revision FROM account_library WHERE account_id=?1",
            [&auth.account],
            |r| r.get(0),
        )?;
        if revision != update.revision {
            return Ok(Change::Conflict);
        }
        if !quotas(&tx, now, &[(&format!("library:{}", auth.account), 60, 120)])? {
            tx.commit()?;
            return Ok(Change::Limited);
        }
        tx.execute(
            "UPDATE account_library SET revision=revision+1,favorites=?2 WHERE account_id=?1",
            params![auth.account, serde_json::to_string(&update.favorites)?],
        )?;
        tx.commit()?;
        Ok(Change::Applied(
            self.library(auth, now)?
                .ok_or_else(|| anyhow::anyhow!("session ended"))?,
        ))
    }

    pub fn history_append(
        &mut self,
        auth: &Auth,
        update: HistoryUpdate,
        now: i64,
    ) -> Result<Change> {
        let e = update.entry;
        if auth.browser
            || update.history_epoch < 0
            || !crypto::is_token(&e.event_id)
            || !crypto::is_token(&e.source_device_id)
            || !crypto::valid_id(&e.funti_id)
            || !name_valid(&e.name)
            || e.connected_at <= now - HISTORY_TTL
            || e.connected_at > now + 300
        {
            return Ok(Change::Rejected);
        }
        let tx = self.db.transaction()?;
        if !active_in(&tx, auth, now)? {
            return Ok(Change::Rejected);
        }
        let source: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM devices WHERE id=?1 AND account_id=?2)",
            params![e.source_device_id, auth.account],
            |r| r.get(0),
        )?;
        if !source {
            return Ok(Change::Rejected);
        }
        tx.execute(
            "INSERT OR IGNORE INTO account_library(account_id) VALUES(?1)",
            [&auth.account],
        )?;
        let epoch: i64 = tx.query_row(
            "SELECT history_epoch FROM account_library WHERE account_id=?1",
            [&auth.account],
            |r| r.get(0),
        )?;
        if epoch != update.history_epoch {
            return Ok(Change::Conflict);
        }
        let existing:Option<(String,String,String,i64)> = tx.query_row("SELECT source_device_id,funti_id,name,connected_at FROM connection_history WHERE account_id=?1 AND event_id=?2",params![auth.account,e.event_id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).optional()?;
        if let Some(existing) = existing {
            if existing != (e.source_device_id, e.funti_id, e.name, e.connected_at) {
                return Ok(Change::Conflict);
            }
        } else {
            if !quotas(&tx, now, &[(&format!("history:{}", auth.account), 60, 120)])? {
                tx.commit()?;
                return Ok(Change::Limited);
            }
            tx.execute("INSERT INTO connection_history(account_id,event_id,source_device_id,funti_id,name,connected_at) VALUES(?1,?2,?3,?4,?5,?6)",params![auth.account,e.event_id,e.source_device_id,e.funti_id,e.name,e.connected_at])?;
            tx.execute("DELETE FROM connection_history WHERE account_id=?1 AND event_id NOT IN (SELECT event_id FROM connection_history WHERE account_id=?1 ORDER BY connected_at DESC,event_id DESC LIMIT 1000)",[&auth.account])?;
        }
        tx.commit()?;
        Ok(Change::Applied(
            self.library(auth, now)?
                .ok_or_else(|| anyhow::anyhow!("session ended"))?,
        ))
    }

    pub fn history_clear(&mut self, auth: &Auth, update: HistoryClear, now: i64) -> Result<Change> {
        let tx = self.db.transaction()?;
        if !active_in(&tx, auth, now)? {
            return Ok(Change::Rejected);
        }
        tx.execute(
            "INSERT OR IGNORE INTO account_library(account_id) VALUES(?1)",
            [&auth.account],
        )?;
        let epoch: i64 = tx.query_row(
            "SELECT history_epoch FROM account_library WHERE account_id=?1",
            [&auth.account],
            |r| r.get(0),
        )?;
        if epoch != update.history_epoch {
            return Ok(Change::Conflict);
        }
        if !quotas(&tx, now, &[(&format!("library:{}", auth.account), 60, 120)])? {
            tx.commit()?;
            return Ok(Change::Limited);
        }
        tx.execute(
            "DELETE FROM connection_history WHERE account_id=?1",
            [&auth.account],
        )?;
        tx.execute(
            "UPDATE account_library SET history_epoch=history_epoch+1 WHERE account_id=?1",
            [&auth.account],
        )?;
        tx.commit()?;
        Ok(Change::Applied(
            self.library(auth, now)?
                .ok_or_else(|| anyhow::anyhow!("session ended"))?,
        ))
    }
}
fn response(change: Change) -> ApiResult<Json<Library>> {
    match change {
        Change::Applied(library) => Ok(Json(library)),
        Change::Conflict => Err(ApiError(StatusCode::CONFLICT, "sync_conflict")),
        Change::Rejected => Err(web::invalid()),
        Change::Limited => Err(ApiError(StatusCode::TOO_MANY_REQUESTS, "try_later")),
    }
}
pub fn routes() -> Router<App> {
    Router::new()
        .route("/library", get(read))
        .route("/library/favorites", post(favorites))
        .route("/library/history", post(append))
        .route("/library/history/clear", post(clear))
}
async fn read(State(app): State<App>, headers: HeaderMap) -> ApiResult<Json<Library>> {
    let auth = web::authorize(&app, &headers, false).await?;
    let now = app.now();
    Ok(Json(
        app.db(move |db| db.library(&auth, now))
            .await?
            .ok_or_else(web::invalid)?,
    ))
}
async fn favorites(
    State(app): State<App>,
    headers: HeaderMap,
    Json(update): Json<FavoritesUpdate>,
) -> ApiResult<Json<Library>> {
    let auth = web::authorize(&app, &headers, true).await?;
    let now = app.now();
    response(
        app.db(move |db| db.favorites_update(&auth, update, now))
            .await?,
    )
}
async fn append(
    State(app): State<App>,
    headers: HeaderMap,
    Json(update): Json<HistoryUpdate>,
) -> ApiResult<Json<Library>> {
    let auth = web::authorize(&app, &headers, true).await?;
    let now = app.now();
    response(
        app.db(move |db| db.history_append(&auth, update, now))
            .await?,
    )
}
async fn clear(
    State(app): State<App>,
    headers: HeaderMap,
    Json(update): Json<HistoryClear>,
) -> ApiResult<Json<Library>> {
    let auth = web::authorize(&app, &headers, true).await?;
    let now = app.now();
    response(
        app.db(move |db| db.history_clear(&auth, update, now))
            .await?,
    )
}
