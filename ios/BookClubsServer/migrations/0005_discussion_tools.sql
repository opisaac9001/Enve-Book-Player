ALTER TABLE posts ADD COLUMN is_spoiler INTEGER NOT NULL DEFAULT 0 CHECK (is_spoiler IN (0, 1));

CREATE TABLE discussion_prompts (
  read_id TEXT NOT NULL REFERENCES reads(id) ON DELETE CASCADE,
  thread_id TEXT NOT NULL,
  body TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (read_id, thread_id)
);
CREATE INDEX posts_read_feed ON posts(read_id, created_at DESC, id DESC);
