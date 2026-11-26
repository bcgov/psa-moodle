-- quiescence-pg.sql (RB05, V502; RETURNS ONLY, never part of an abort): is anything other than our own management
-- sessions connected to the moodle database? Run fresh on the new Postgres primary immediately before the return's
-- extraction (§14.1), after the writer fence has verified:
--   psql -X -AtF $'\t' -v allow_users=<roles> -v allow_apps=<application names> -f quiescence-pg.sql
-- A session is allowed only if BOTH its role and its application_name are listed (for example allow_users=postgres
-- allow_apps=psql,pg_dump). This session is always excluded. Crunchy's own management (Patroni, pgBackRest) connects
-- to the postgres database or as replication, and doesn't appear here.
-- Output: the unexpected sessions (pid, role, application, client address, state and times; never query text), then
-- the database's write counters as supporting evidence only: run twice a minute apart, and they should not move.
-- Exit: psql 3 (ON_ERROR_STOP) if any unexpected session is connected. A failure stops the return.
\set ON_ERROR_STOP 1
\pset footer off
SELECT 'session' AS kind, pid, usename, application_name, client_addr, state, backend_start, xact_start, state_change
FROM pg_stat_activity
WHERE backend_type = 'client backend' AND datname = current_database() AND pid <> pg_backend_pid()
  AND NOT (usename = ANY (string_to_array(:'allow_users', ',')) AND application_name = ANY (string_to_array(:'allow_apps', ',')))
ORDER BY backend_start;
SELECT 'counters' AS kind, now() AS at, xact_commit, tup_inserted, tup_updated, tup_deleted
FROM pg_stat_database WHERE datname = current_database();
SELECT COUNT(*) AS unexpected FROM pg_stat_activity
WHERE backend_type = 'client backend' AND datname = current_database() AND pid <> pg_backend_pid()
  AND NOT (usename = ANY (string_to_array(:'allow_users', ',')) AND application_name = ANY (string_to_array(:'allow_apps', ','))) \gset
SELECT set_config('rp.unexpected', :'unexpected', false) \g /dev/null
DO $$ BEGIN
  IF current_setting('rp.unexpected')::int > 0 THEN
    RAISE EXCEPTION 'quiescence-pg: % unexpected session(s) on the moodle database', current_setting('rp.unexpected');
  END IF;
END $$;
