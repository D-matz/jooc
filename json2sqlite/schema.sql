PRAGMA foreign_keys = ON;  -- set on every connection

CREATE TABLE packages (
  id               INTEGER PRIMARY KEY,
  name             TEXT NOT NULL UNIQUE,
  description      TEXT NOT NULL,
  repository       TEXT,                -- NULL = None
  updated_at       INTEGER NOT NULL,    -- Unix time in seconds
  owners           TEXT NOT NULL,       -- space-separated
  total_downloads  INTEGER NOT NULL,
  recent_downloads INTEGER NOT NULL,
  latest_version   TEXT NOT NULL
);

CREATE TABLE modules (
  id         INTEGER PRIMARY KEY,
  package_id INTEGER NOT NULL REFERENCES packages (id) ON DELETE CASCADE,
  name       TEXT NOT NULL,
  source     TEXT NOT NULL,
  UNIQUE (package_id, name)
);

CREATE TABLE canonical_forms (
  id        INTEGER PRIMARY KEY,
  canonical TEXT NOT NULL UNIQUE
);

CREATE TABLE definitions (
  module_id    INTEGER NOT NULL REFERENCES modules (id) ON DELETE CASCADE,
  kind         INTEGER NOT NULL CHECK (kind IN (0, 1)),
  canonical_id INTEGER NOT NULL REFERENCES canonical_forms (id),
  start_pos    INTEGER NOT NULL,
  end_pos      INTEGER NOT NULL,
  PRIMARY KEY (module_id, start_pos)
) WITHOUT ROWID;

CREATE INDEX definitions_by_canonical ON definitions (canonical_id);
CREATE INDEX modules_by_package ON modules (package_id);

-- Delete old modules when a package gets a new updated_at.
-- Cascades to definitions.
CREATE TRIGGER packages_replace_modules
AFTER UPDATE OF updated_at ON packages
WHEN new.updated_at <> old.updated_at
BEGIN
  DELETE FROM modules WHERE package_id = new.id;
END;

-- Delete a canonical form when no definition uses it.
CREATE TRIGGER definitions_gc_canonical
AFTER DELETE ON definitions
BEGIN
  DELETE FROM canonical_forms
  WHERE id = old.canonical_id
    AND NOT EXISTS (
      SELECT 1 FROM definitions WHERE canonical_id = old.canonical_id
    );
END;

-- Insert definitions by canonical text. The trigger creates the form if needed.
CREATE VIEW definitions_in AS
SELECT module_id, kind, '' AS canonical, start_pos, end_pos
FROM definitions WHERE 0;

CREATE TRIGGER definitions_in_insert
INSTEAD OF INSERT ON definitions_in
BEGIN
  INSERT OR IGNORE INTO canonical_forms (canonical) VALUES (new.canonical);
  INSERT INTO definitions (module_id, kind, canonical_id, start_pos, end_pos)
  VALUES (
    new.module_id, new.kind,
    (SELECT id FROM canonical_forms WHERE canonical = new.canonical),
    new.start_pos, new.end_pos
  );
END;

-- Fuzzy search: packages (external content)
CREATE VIRTUAL TABLE packages_fts USING fts5(
  name, description, owners,
  content = 'packages', content_rowid = 'id',
  tokenize = 'trigram'
);

CREATE TRIGGER packages_fts_ai AFTER INSERT ON packages BEGIN
  INSERT INTO packages_fts (rowid, name, description, owners)
  VALUES (new.id, new.name, new.description, new.owners);
END;

CREATE TRIGGER packages_fts_ad AFTER DELETE ON packages BEGIN
  INSERT INTO packages_fts (packages_fts, rowid, name, description, owners)
  VALUES ('delete', old.id, old.name, old.description, old.owners);
END;

CREATE TRIGGER packages_fts_au AFTER UPDATE ON packages BEGIN
  INSERT INTO packages_fts (packages_fts, rowid, name, description, owners)
  VALUES ('delete', old.id, old.name, old.description, old.owners);
  INSERT INTO packages_fts (rowid, name, description, owners)
  VALUES (new.id, new.name, new.description, new.owners);
END;

-- Fuzzy search: modules (external content)
CREATE VIRTUAL TABLE modules_fts USING fts5(
  name, source,
  content = 'modules', content_rowid = 'id',
  tokenize = 'trigram'
);

CREATE TRIGGER modules_fts_ai AFTER INSERT ON modules BEGIN
  INSERT INTO modules_fts (rowid, name, source)
  VALUES (new.id, new.name, new.source);
END;

CREATE TRIGGER modules_fts_ad AFTER DELETE ON modules BEGIN
  INSERT INTO modules_fts (modules_fts, rowid, name, source)
  VALUES ('delete', old.id, old.name, old.source);
END;

CREATE TRIGGER modules_fts_au AFTER UPDATE ON modules BEGIN
  INSERT INTO modules_fts (modules_fts, rowid, name, source)
  VALUES ('delete', old.id, old.name, old.source);
  INSERT INTO modules_fts (rowid, name, source)
  VALUES (new.id, new.name, new.source);
END;
