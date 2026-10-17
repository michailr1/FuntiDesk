BEGIN;
CREATE TABLE IF NOT EXISTS account_library(account_id TEXT PRIMARY KEY REFERENCES accounts(id),revision INTEGER NOT NULL DEFAULT 0,history_epoch INTEGER NOT NULL DEFAULT 0,favorites TEXT NOT NULL DEFAULT '[]');
CREATE TABLE IF NOT EXISTS connection_history(account_id TEXT NOT NULL REFERENCES accounts(id),event_id TEXT NOT NULL,source_device_id TEXT NOT NULL REFERENCES devices(id),funti_id TEXT NOT NULL,name TEXT NOT NULL,connected_at INTEGER NOT NULL,PRIMARY KEY(account_id,event_id));
CREATE INDEX IF NOT EXISTS history_time ON connection_history(account_id,connected_at DESC,event_id DESC);
PRAGMA user_version=3;
COMMIT;
