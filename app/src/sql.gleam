pub const all_pkgs =
  "SELECT p.name, p.description, p.repository, p.updated_at, p.owners,
  p.total_downloads, p.recent_downloads, p.latest_version,
  NULL AS module, NULL AS snippet
FROM packages p
ORDER BY p.recent_downloads DESC, p.id"

pub const info_only =
  "SELECT p.name, p.description, p.repository,
  p.updated_at, p.owners, p.total_downloads, p.recent_downloads,
  p.latest_version, NULL AS module, NULL AS snippet
FROM packages p
WHERE instr(lower(p.name), lower(?)) > 0
   OR instr(lower(p.description), lower(?)) > 0
   OR instr(lower(p.owners), lower(?)) > 0
ORDER BY p.recent_downloads DESC, p.id"

// const code_search_sql =
//   "SELECT p.name, p.description, p.repository, p.updated_at, p.owners,
//     p.total_downloads, p.recent_downloads, p.latest_version,
//     m.name AS module,
//     snippet(modules_fts, -1, char(2), char(3), '', 64) AS snippet
//   FROM modules_fts f
//   JOIN modules m ON m.id = f.rowid
//   JOIN packages p ON p.id = m.package_id
//   WHERE modules_fts MATCH ?
//   ORDER BY f.rank"

// const code_and_package_sql =
//   "SELECT * FROM (
//   SELECT p.name, p.description, p.repository, p.updated_at, p.owners,
//          p.total_downloads, p.recent_downloads, p.latest_version,
//          NULL AS module, NULL AS snippet,
//          0 AS kind,
//          lower(p.name) = lower(?2) AS exact,
//          -p.recent_downloads AS score
//   FROM packages_fts f
//   JOIN packages p ON p.id = f.rowid
//   WHERE packages_fts MATCH ?1
//   UNION ALL
//   SELECT p.name, p.description, p.repository, p.updated_at, p.owners,
//          p.total_downloads, p.recent_downloads, p.latest_version,
//          m.name AS module,
//          snippet(modules_fts, -1, char(2), char(3), '', 64) AS snippet,
//          1 AS kind,
//          0 AS exact,
//          f.rank AS score
//   FROM modules_fts f
//   JOIN modules m ON m.id = f.rowid
//   JOIN packages p ON p.id = m.package_id
//   WHERE modules_fts MATCH ?1
// )
// ORDER BY kind, exact DESC, score"

// const code_and_package_sql =
//   "SELECT name, description, repository, updated_at, owners,
//   total_downloads, recent_downloads, latest_version, module, snippet FROM (
//   SELECT p.name, p.description, p.repository, p.updated_at, p.owners,
//          p.total_downloads, p.recent_downloads, p.latest_version,
//          m.name AS module,
//          snippet(modules_fts, -1, char(2), char(3), '', 64) AS snippet,
//          0 AS kind, f.rank AS score
//   FROM modules_fts f
//   JOIN modules m ON m.id = f.rowid
//   JOIN packages p ON p.id = m.package_id
//   WHERE modules_fts MATCH ?1
//   UNION ALL
//   SELECT p.name, p.description, p.repository, p.updated_at, p.owners,
//          p.total_downloads, p.recent_downloads, p.latest_version,
//          m.name,
//          snippet(modules_fts, -1, char(2), char(3), '', 64),
//          1, f.rank
//   FROM modules_fts f
//   JOIN modules m ON m.id = f.rowid
//   JOIN packages p ON p.id = m.package_id
//   WHERE modules_fts MATCH ?2
//     AND f.rowid NOT IN (SELECT rowid FROM modules_fts WHERE modules_fts MATCH ?1)
// )
// ORDER BY kind, score
// LIMIT 100"

pub const code_and_package_sql =
  "WITH pkg AS (
  SELECT rowid AS id, rank AS score FROM packages_fts
  WHERE packages_fts MATCH ?2
    AND rank < -15.0

  UNION

  SELECT p.id, 0 AS score
  FROM packages p
  WHERE lower(p.name) IN (
    SELECT lower(value)
    FROM json_each(?3)
  )
),
exact AS (
  SELECT rowid AS id FROM modules_fts
  WHERE modules_fts MATCH ?1 ORDER BY rank
),
fuzzy AS (
  SELECT rowid AS id FROM modules_fts
  WHERE modules_fts MATCH ?2
    AND rank < -15.0
    AND rowid NOT IN (SELECT id FROM exact)
  ORDER BY rank LIMIT 20
)
SELECT name, description, repository, updated_at, owners,
  total_downloads, recent_downloads, latest_version, module, snippet FROM (
  SELECT p.name, p.description, p.repository, p.updated_at, p.owners,
         p.total_downloads, p.recent_downloads, p.latest_version,
         NULL AS module, NULL AS snippet,
         0 AS kind, pkg.score AS score
  FROM pkg
  JOIN packages p ON p.id = pkg.id
  UNION ALL
  SELECT p.name, p.description, p.repository, p.updated_at, p.owners,
         p.total_downloads, p.recent_downloads, p.latest_version,
         m.name,
         CASE
           WHEN instr(lower(m.source), lower(?1)) > 0
           THEN substr(m.source, max(1, instr(lower(m.source), lower(?1)) - 40), 120)
           ELSE snippet(modules_fts, 1, '', '', '', 64)
         END,
         1, f.rank
  FROM modules_fts f
  JOIN modules m ON m.id = f.rowid
  JOIN packages p ON p.id = m.package_id
  WHERE modules_fts MATCH ?1 AND f.rowid IN (SELECT id FROM exact)
    AND p.id NOT IN (SELECT id FROM pkg)
  UNION ALL
  SELECT p.name, p.description, p.repository, p.updated_at, p.owners,
         p.total_downloads, p.recent_downloads, p.latest_version,
         m.name,
         snippet(modules_fts, 1, '', '', '', 64),
         2, f.rank
  FROM modules_fts f
  JOIN modules m ON m.id = f.rowid
  JOIN packages p ON p.id = m.package_id
  WHERE modules_fts MATCH ?2 AND f.rowid IN (SELECT id FROM fuzzy)
    AND p.id NOT IN (SELECT id FROM pkg)
)
ORDER BY
  COALESCE(
    (
      SELECT CAST(key AS INTEGER)
      FROM json_each(?3)
      WHERE lower(value) = lower(name)
      LIMIT 1
    ),
    999999
  ),
  kind,
  score"
