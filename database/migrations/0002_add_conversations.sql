-- Splits command_history into separate conversations so the chat can have
-- real history (switch back to an older thread) and a "new conversation"
-- action instead of one endless timeline.

CREATE TABLE IF NOT EXISTS conversations (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL
);

ALTER TABLE command_history ADD COLUMN conversation_id TEXT NOT NULL DEFAULT 'legacy';

-- Pre-existing rows (recorded before conversations existed) are grouped
-- under a single "legacy" conversation so no history is lost.
INSERT OR IGNORE INTO conversations (id, title, created_at, updated_at)
VALUES ('legacy', 'Historique', strftime('%s', 'now'), strftime('%s', 'now'));
