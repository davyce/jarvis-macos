-- Persistent audit trail for Bridge system actions (click, keystroke, window
-- focus performed via macOS Accessibility). Every execution -- successful,
-- failed, or declined at the confirmation prompt -- is recorded here with
-- its fixed capability and target, never the raw keystroke/click content.

CREATE TABLE IF NOT EXISTS system_action_audit_log (
    id TEXT PRIMARY KEY,
    capability TEXT NOT NULL,
    target TEXT NOT NULL,
    outcome TEXT NOT NULL,     -- "success" | "failure" | "declined"
    detail TEXT NOT NULL,
    created_at REAL NOT NULL   -- Unix timestamp (seconds)
);
