-- backup-role-grants.sql (C8, §13.2; review V1004): give the nightly backup's role exactly what it needs on a loaded or
-- restored moodle database, and PROVE it. Run as the database owner or postgres after every load, restore or install,
-- before the backup is unsuspended:
--   psql -X -v ON_ERROR_STOP=1 -v backup_role=moodle-backup -d moodle -f backup-role-grants.sql
-- Initialization SQL runs only once, at bootstrap, before Moodle's tables exist; that is why this is a separate step.
-- Grants: SELECT on mdl_files only (the inventory), and EXECUTE on pg_create_restore_point(text) and pg_switch_wal()
-- (granted at bootstrap; re-granted here, harmless). Then checks the role has those privileges, and NOT the broader ones it must never have.
-- Exit: psql 3 if any check fails.
\set ON_ERROR_STOP 1
GRANT SELECT ON TABLE mdl_files TO :"backup_role";
GRANT EXECUTE ON FUNCTION pg_create_restore_point(text) TO :"backup_role";
GRANT EXECUTE ON FUNCTION pg_switch_wal() TO :"backup_role";
SELECT set_config('rp.backup_role', :'backup_role', false) \g /dev/null
DO $$
DECLARE r text := current_setting('rp.backup_role');
BEGIN
  IF NOT has_table_privilege(r, 'mdl_files', 'SELECT') THEN RAISE EXCEPTION '% cannot SELECT mdl_files', r; END IF;
  IF NOT has_function_privilege(r, 'pg_create_restore_point(text)', 'EXECUTE') THEN
    RAISE EXCEPTION '% cannot EXECUTE pg_create_restore_point', r; END IF;
  IF NOT has_function_privilege(r, 'pg_switch_wal()', 'EXECUTE') THEN RAISE EXCEPTION '% cannot EXECUTE pg_switch_wal', r; END IF;
  IF has_table_privilege(r, 'mdl_files', 'INSERT,UPDATE,DELETE,TRUNCATE') THEN RAISE EXCEPTION '% can write mdl_files', r; END IF;
  IF has_table_privilege(r, 'mdl_user', 'SELECT') THEN RAISE EXCEPTION '% can read mdl_user: too broad', r; END IF;
  IF (SELECT rolsuper OR rolcreaterole OR rolcreatedb FROM pg_roles WHERE rolname = r) THEN
    RAISE EXCEPTION '% has superuser, createrole or createdb', r; END IF;
  RAISE NOTICE 'backup role %: SELECT on mdl_files, EXECUTE on pg_create_restore_point and pg_switch_wal (checked)', r;
END $$;
