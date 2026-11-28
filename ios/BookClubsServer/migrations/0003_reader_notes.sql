CREATE TABLE notes (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  read_id TEXT REFERENCES reads(id) ON DELETE SET NULL,
  checkpoint_id TEXT REFERENCES checkpoints(id) ON DELETE SET NULL,
  book_title TEXT NOT NULL,
  body TEXT NOT NULL,
  visibility TEXT NOT NULL CHECK (visibility IN ('private', 'club')),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX notes_read_page ON notes(read_id, created_at DESC, id DESC);
CREATE INDEX notes_member_page ON notes(account_id, created_at DESC, id DESC);
CREATE INDEX notes_checkpoint ON notes(checkpoint_id);

CREATE TRIGGER private_notes_before_checkpoint_deletion
BEFORE DELETE ON checkpoints
BEGIN
  UPDATE notes SET visibility = 'private' WHERE checkpoint_id = OLD.id;
END;

CREATE TRIGGER private_notes_before_read_deletion
BEFORE DELETE ON reads
BEGIN
  UPDATE notes SET visibility = 'private' WHERE read_id = OLD.id;
END;
