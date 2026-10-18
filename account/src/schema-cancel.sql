BEGIN;
ALTER TABLE events ADD COLUMN cancelled_at INTEGER;
PRAGMA user_version=5;
COMMIT;
