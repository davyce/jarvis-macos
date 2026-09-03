-- Applied by Services/LocalDatabase.swift on launch (CREATE TABLE IF NOT EXISTS).
-- Kept here as the source of truth / history of schema changes.

CREATE TABLE IF NOT EXISTS command_history (
    id TEXT PRIMARY KEY,
    role TEXT NOT NULL,
    text TEXT NOT NULL,
    detail TEXT,
    created_at REAL NOT NULL
);
