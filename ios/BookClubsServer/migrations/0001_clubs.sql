CREATE TABLE accounts (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  recovery_hash TEXT NOT NULL UNIQUE
);
CREATE TABLE sessions (
  token_hash TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  expires_at INTEGER NOT NULL
);
CREATE INDEX sessions_account ON sessions(account_id);
CREATE TABLE clubs (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  owner_id TEXT NOT NULL REFERENCES accounts(id),
  created_at INTEGER NOT NULL
);
CREATE INDEX clubs_owner ON clubs(owner_id);
CREATE TABLE memberships (
  club_id TEXT NOT NULL REFERENCES clubs(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  joined_at INTEGER NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('active', 'left', 'removed')),
  PRIMARY KEY (club_id, account_id)
);
CREATE INDEX memberships_account ON memberships(account_id, state);
CREATE TABLE invites (
  club_id TEXT PRIMARY KEY REFERENCES clubs(id) ON DELETE CASCADE,
  code_hash TEXT NOT NULL UNIQUE,
  expires_at INTEGER NOT NULL
);
CREATE TABLE reads (
  id TEXT PRIMARY KEY,
  club_id TEXT NOT NULL REFERENCES clubs(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  author TEXT,
  series TEXT,
  created_at INTEGER NOT NULL,
  closed_at INTEGER
);
CREATE UNIQUE INDEX one_active_read ON reads(club_id) WHERE closed_at IS NULL;
CREATE INDEX reads_history ON reads(club_id, created_at DESC);
CREATE TABLE checkpoints (
  id TEXT PRIMARY KEY,
  read_id TEXT NOT NULL REFERENCES reads(id) ON DELETE CASCADE,
  sort_order INTEGER NOT NULL,
  label TEXT NOT NULL,
  chapter_key TEXT,
  due_at INTEGER,
  track_position REAL,
  UNIQUE (read_id, sort_order)
);
CREATE TABLE sharing (
  read_id TEXT NOT NULL REFERENCES reads(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  epoch TEXT NOT NULL,
  presence INTEGER NOT NULL CHECK (presence IN (0, 1)),
  PRIMARY KEY (read_id, account_id)
);
CREATE TABLE progress (
  read_id TEXT NOT NULL REFERENCES reads(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  fraction REAL NOT NULL CHECK (fraction BETWEEN 0 AND 1),
  observed_at INTEGER NOT NULL,
  active_until INTEGER,
  PRIMARY KEY (read_id, account_id)
);
CREATE TABLE completions (
  checkpoint_id TEXT NOT NULL REFERENCES checkpoints(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  completed_at INTEGER NOT NULL,
  PRIMARY KEY (checkpoint_id, account_id)
);
CREATE TABLE posts (
  id TEXT PRIMARY KEY,
  read_id TEXT NOT NULL REFERENCES reads(id) ON DELETE CASCADE,
  checkpoint_id TEXT REFERENCES checkpoints(id) ON DELETE CASCADE,
  author_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  parent_id TEXT REFERENCES posts(id) ON DELETE SET NULL,
  body TEXT NOT NULL,
  passage TEXT,
  passage_chapter TEXT,
  created_at INTEGER NOT NULL
);
CREATE INDEX posts_thread ON posts(read_id, checkpoint_id, created_at DESC, id DESC);
CREATE TABLE reactions (
  post_id TEXT NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  emoji TEXT NOT NULL,
  PRIMARY KEY (post_id, account_id, emoji)
);
CREATE TABLE nominations (
  id TEXT PRIMARY KEY,
  club_id TEXT NOT NULL REFERENCES clubs(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  author TEXT,
  account_id TEXT REFERENCES accounts(id) ON DELETE SET NULL,
  created_at INTEGER NOT NULL,
  UNIQUE (club_id, id)
);
CREATE TABLE polls (
  id TEXT PRIMARY KEY,
  club_id TEXT NOT NULL REFERENCES clubs(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  closes_at INTEGER,
  closed_at INTEGER,
  winner_id TEXT REFERENCES nominations(id),
  started_read_id TEXT REFERENCES reads(id) ON DELETE SET NULL
);
CREATE UNIQUE INDEX one_open_poll ON polls(club_id) WHERE closed_at IS NULL;
CREATE TABLE poll_options (
  poll_id TEXT NOT NULL REFERENCES polls(id) ON DELETE CASCADE,
  nomination_id TEXT NOT NULL REFERENCES nominations(id),
  PRIMARY KEY (poll_id, nomination_id)
);
CREATE TABLE votes (
  poll_id TEXT NOT NULL,
  nomination_id TEXT NOT NULL,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  PRIMARY KEY (poll_id, account_id),
  FOREIGN KEY (poll_id, nomination_id) REFERENCES poll_options(poll_id, nomination_id) ON DELETE CASCADE
);
CREATE TABLE activity (
  id TEXT PRIMARY KEY,
  club_id TEXT NOT NULL REFERENCES clubs(id) ON DELETE CASCADE,
  account_id TEXT REFERENCES accounts(id) ON DELETE SET NULL,
  kind TEXT NOT NULL,
  label TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX activity_club ON activity(club_id, created_at DESC);
CREATE TABLE blocks (
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  blocked_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  PRIMARY KEY (account_id, blocked_id)
);
CREATE TABLE reports (
  id TEXT PRIMARY KEY,
  club_id TEXT REFERENCES clubs(id) ON DELETE SET NULL,
  reporter_id TEXT REFERENCES accounts(id) ON DELETE SET NULL,
  post_id TEXT REFERENCES posts(id) ON DELETE SET NULL,
  reason TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  resolved_at INTEGER
);
CREATE INDEX reports_open ON reports(resolved_at, created_at);
CREATE TABLE request_limits (
  key TEXT PRIMARY KEY,
  count INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
