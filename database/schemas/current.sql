-- Cumulative current schema for the local Jarvis SQLite store
-- (~/Library/Application Support/Jarvis/jarvis.sqlite3 on macOS).
-- Regenerate this file by hand whenever a new migration lands.

CREATE TABLE conversations (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    created_at REAL NOT NULL,  -- Unix timestamp (seconds)
    updated_at REAL NOT NULL   -- Unix timestamp (seconds)
);

CREATE TABLE command_history (
    id TEXT PRIMARY KEY,
    role TEXT NOT NULL,        -- "user" | "jarvis"
    text TEXT NOT NULL,
    detail TEXT,
    created_at REAL NOT NULL,  -- Unix timestamp (seconds)
    conversation_id TEXT NOT NULL DEFAULT 'legacy'
);

CREATE TABLE system_action_audit_log (
    id TEXT PRIMARY KEY,
    capability TEXT NOT NULL,
    target TEXT NOT NULL,
    outcome TEXT NOT NULL,     -- "success" | "failure" | "declined"
    detail TEXT NOT NULL,
    created_at REAL NOT NULL   -- Unix timestamp (seconds)
);
