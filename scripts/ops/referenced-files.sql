-- referenced-files.sql (O1, runbook §8.3): every file the database references, one row per content hash, for the
-- moodledata copy's --files-from list and for check-filedir. Valid on MariaDB (legacy) and Postgres (new): run it with
-- the client's tab-separated, no-header output. Hashes and sizes only; no names, paths or users.
-- {PREFIX}: legacy MariaDB has no table prefix, the new Postgres uses mdl_ (§5.2), so fill it in first:
--   sed 's/{PREFIX}//'    referenced-files.sql | mariadb -N -B moodle        (legacy, or a legacy dump's copy)
--   sed 's/{PREFIX}/mdl_/' referenced-files.sql | psql -AtF $'\t' moodle       (new)
--   contenthash <TAB> smallest filesize <TAB> largest filesize   (the two differ only if the database is inconsistent)
SELECT contenthash, MIN(filesize) AS min_size, MAX(filesize) AS max_size
FROM {PREFIX}files
WHERE filename <> '.'
GROUP BY contenthash
ORDER BY contenthash;
