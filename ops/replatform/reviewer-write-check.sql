-- reviewer-write-check.sql (S15, DR08, DR09): before the commit point, has anyone outside the reviewer list written
-- anything? Reads Moodle's standard log store on the NEW Postgres; expect no rows. Run fresh before §13.3:
--   psql -X -AtF $'\t' -v since=<unix time the restricted Routes opened> -v reviewers=<user ids, comma-separated> \
--        -f reviewer-write-check.sql
-- A write counts as a reviewer's when the acting user (realuserid during "log in as", else userid) is on the list.
-- Output: ids, event names and counts only (no names or content). userid 0 is "not logged in".
-- Exit: psql 3 (ON_ERROR_STOP) if any write is not a reviewer's. The log store records events, not every write: this
-- is a check on behaviour, alongside the restricted Routes, not proof that nothing else changed.
\set ON_ERROR_STOP 1
\pset footer off
WITH w AS (
  SELECT l.userid, l.realuserid, COALESCE(l.realuserid, l.userid) AS actor, l.eventname, l.crud, l.timecreated
  FROM mdl_logstore_standard_log l
  WHERE l.timecreated >= :since AND l.crud IN ('c', 'u', 'd'))
SELECT 'summary' AS kind, COUNT(*) AS writes,
       COUNT(*) FILTER (WHERE actor = ANY (string_to_array(:'reviewers', ',')::bigint[])) AS by_reviewers,
       COUNT(*) FILTER (WHERE NOT actor = ANY (string_to_array(:'reviewers', ',')::bigint[])) AS by_others
FROM w;
WITH w AS (
  SELECT l.userid, l.realuserid, COALESCE(l.realuserid, l.userid) AS actor, l.eventname, l.crud, l.timecreated
  FROM mdl_logstore_standard_log l
  WHERE l.timecreated >= :since AND l.crud IN ('c', 'u', 'd'))
SELECT 'other' AS kind, userid, COALESCE(realuserid, 0) AS realuserid, eventname, crud, COUNT(*) AS events,
       to_timestamp(MIN(timecreated)) AS first_at, to_timestamp(MAX(timecreated)) AS last_at
FROM w WHERE NOT actor = ANY (string_to_array(:'reviewers', ',')::bigint[])
GROUP BY userid, realuserid, eventname, crud ORDER BY events DESC;
SELECT COUNT(*) AS others FROM mdl_logstore_standard_log l
WHERE l.timecreated >= :since AND l.crud IN ('c', 'u', 'd')
  AND NOT COALESCE(l.realuserid, l.userid) = ANY (string_to_array(:'reviewers', ',')::bigint[]) \gset
SELECT set_config('rp.others', :'others', false) \g /dev/null
DO $$ BEGIN
  IF current_setting('rp.others')::bigint > 0 THEN
    RAISE EXCEPTION 'reviewer-write-check: % write event(s) by users outside the reviewer list', current_setting('rp.others');
  END IF;
END $$;
