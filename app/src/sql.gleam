const all =
  "SELECT
  p.name, p.description, p.repository, p.updated_at, p.owners,
  p.total_downloads, p.recent_downloads, p.latest_version,
  NULL AS module, NULL AS snippet
FROM packages p"

pub const all_pkgs_by_downloaded =
  all <> " ORDER BY p.recent_downloads DESC, p.id"

pub const all_pkgs_by_recent = all <> " ORDER BY p.updated_at DESC, p.id;"

pub const all_pkgs_by_small = all <> " LEFT JOIN modules m ON m.package_id = p.id
GROUP BY p.id
ORDER BY COALESCE(SUM(length(m.source)), 0) ASC, p.id;"

pub const all_pkgs_by_big = all <> " LEFT JOIN modules m ON m.package_id = p.id
GROUP BY p.id
ORDER BY COALESCE(SUM(length(m.source)), 0) DESC, p.id;"

pub const info_only = all <> " WHERE instr(lower(p.name), lower(?)) > 0
   OR instr(lower(p.description), lower(?)) > 0
   OR instr(lower(p.owners), lower(?)) > 0
ORDER BY p.recent_downloads DESC, p.id"

// params: ?1 text, ?2 trigrams, ?3 similar package names, ?4 bm25 threshold
pub const code_and_package =
  "WITH pkg AS (
  SELECT rowid AS id, rank AS score, 999999 AS pos
  FROM packages_fts
  WHERE packages_fts MATCH ?2 AND rank < ?4

  UNION

  SELECT p.id, 0, CAST(j.key AS INTEGER)
  FROM json_each(?3) j
  JOIN packages p ON lower(p.name) = lower(j.value)
),
fuzzy AS (
  SELECT rowid AS id FROM modules_fts
  WHERE modules_fts MATCH ?2
    AND rank < ?4
    AND length(source) < 200000
    AND rowid NOT IN (
      SELECT rowid FROM modules_fts
      WHERE modules_fts MATCH ('\"' || replace(?1, '\"', '\"\"') || '\"')
    )
)
SELECT name, description, repository, updated_at, owners,
  total_downloads, recent_downloads, latest_version, module, snippet FROM (
  SELECT p.name, p.description, p.repository, p.updated_at, p.owners,
    p.total_downloads, p.recent_downloads, p.latest_version,
    NULL AS module, NULL AS snippet,
    0 AS kind, pkg.score AS score, pkg.pos AS pos
  FROM pkg
  JOIN packages p ON p.id = pkg.id

  UNION ALL

  SELECT p.name, p.description, p.repository, p.updated_at, p.owners,
    p.total_downloads, p.recent_downloads, p.latest_version,
    m.name,
    snippet(modules_fts, 1, char(2), char(3), '', 64),
    1, f.rank, 999999
  FROM modules_fts f
  JOIN modules m ON m.id = f.rowid
  JOIN packages p ON p.id = m.package_id
  WHERE modules_fts MATCH ('\"' || replace(?1, '\"', '\"\"') || '\"')
    AND p.id NOT IN (SELECT id FROM pkg)

  UNION ALL

  SELECT p.name, p.description, p.repository, p.updated_at, p.owners,
    p.total_downloads, p.recent_downloads, p.latest_version,
    m.name,
    snippet(modules_fts, 1, char(2), char(3), '', 64),
    2, f.rank, 999999
  FROM modules_fts f
  JOIN modules m ON m.id = f.rowid
  JOIN packages p ON p.id = m.package_id
  WHERE modules_fts MATCH ?2 AND f.rowid IN (SELECT id FROM fuzzy)
    AND p.id NOT IN (SELECT id FROM pkg)
)
ORDER BY pos, kind, score"

pub const canonical =
  "SELECT
  p.name, p.description, p.repository, p.updated_at, p.owners,
  p.total_downloads, p.recent_downloads, p.latest_version,
  m.name AS module,
  char(2) || CAST(
    substr(CAST(m.source AS BLOB), d.start_pos + 1, d.end_pos - d.start_pos)
    AS TEXT
  ) || char(3) AS snippet
FROM canonical_forms c
JOIN definitions d ON d.canonical_id = c.id
JOIN modules m ON m.id = d.module_id
JOIN packages p ON p.id = m.package_id
WHERE c.canonical = ?1
ORDER BY p.recent_downloads DESC, p.id, m.name, d.start_pos"
