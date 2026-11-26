# ELM reconciliation after a return (runbook §14.9, DR06, V605)

After any return to legacy, successful or abandoned, find every course completion the new site may have **sent to ELM,
logged, or failed to send**, and settle each one with ELM. **Nothing is re-sent blindly:** a completion is sent again
only after ELM's records show it wasn't received. Everything below is personal data: work in the private run folder
(S9), never in git or chat.

## How the plugin sends a completion (`local_psaelmsync`, as deployed)

`\core\event\course_completed` calls `local_psaelmsync\observer::course_completed`, which:

1. finds the user's latest `Enrol` row in `local_psaelmsync_logs` for that course (its `elm_enrolment_id`, `class_code`,
   `oprid`, `person_id`, `activity_id`); with none, it emails a lookup-failure notice and stops;
2. **POSTs the completion** to `completion_apiurl`;
3. **then** inserts a log row: `action = 'Complete'`, `status = 'Success'` (HTTP 2xx) or `'Error'` (with a failure
   email), `timestamp = time()`.

Moodle has already written `course_completions.timecompleted` before the event fires. So an interruption between
steps 2 and 3 leaves a completion **received but not logged**, and one before step 2 leaves it **completed but never
sent**. The plugin's scheduled `process_course_completion` task replays nothing (its `execute()` is empty).

## The window

- **Successful return:** from the §13.3 baseline (the commit point) to the §14.1 end-mark.
- **Abandoned return:** from the fence start **minus a margin** (the longest observed cron task or request, at least
  15 minutes) to the moment the new site resumed.

Record both ends as Unix times in the run log before extracting anything.

## 1. Extract Moodle's side (the new Postgres, read-only)

`{PREFIX}` is `mdl_` on the new stack (empty on legacy). Run with `psql -X -AF $'\t' -v t0=<start> -v t1=<end>`:

```sql
-- A. Completions recorded in the window, with the ELM enrolment they belong to (NULL: no Enrol row; not ELM-linked
--    or a lookup failure, which the plugin emailed about at the time).
SELECT cc.userid, cc.course, cc.timecompleted,
       (SELECT l.elm_enrolment_id FROM {PREFIX}local_psaelmsync_logs l
         WHERE l.user_id = cc.userid AND l.course_id = cc.course AND l.action = 'Enrol'
         ORDER BY l.timestamp DESC LIMIT 1) AS elm_enrolment_id
FROM {PREFIX}course_completions cc
WHERE cc.timecompleted BETWEEN :t0 AND :t1
ORDER BY cc.timecompleted;

-- B. Completion log rows in the window (what the plugin says it did).
SELECT l.id, l.user_id, l.course_id, l.elm_enrolment_id, l.status, l.timestamp
FROM {PREFIX}local_psaelmsync_logs l
WHERE l.action = 'Complete' AND l.timestamp BETWEEN :t0 AND :t1
ORDER BY l.timestamp;
```

Save the results as `moodle-completions.tsv` and `plugin-complete-log.tsv`.

## 2. Get ELM's side (the owner, as the ELM contact, Q19)

Ask ELM for every completion it received for these `elm_enrolment_id`s, or for the window plus a day either side,
with the time received. Save it as `elm-received.tsv`.

## 3. Classify each completion (one row per `elm_enrolment_id` in A or B)

| Class | In A (Moodle) | In B (log) | ELM received | Action |
|---|---|---|---|---|
| **OK** | yes | `Success` | yes | none |
| **Received, not logged** | yes | none | yes | interrupted between POST and log: nothing to send. Record it; adding a log row by hand is an owner decision |
| **Logged, not received** | yes | `Success` | no | ask ELM to check; **send again only once ELM confirms it isn't there** |
| **Failed** | yes | `Error` | no | the plugin emailed at the time; send again once ELM confirms |
| **Failed but received** | yes | `Error` | yes | none (the error was after ELM accepted it); record it |
| **Never sent** | yes | none | no | interrupted before the POST: send once ELM confirms it isn't there |
| **Not ELM-linked** | yes, `elm_enrolment_id` NULL | none | n/a | none: not an ELM course, or a lookup failure already reported |
| **Unexplained** | no | any | any | stop: a log row or an ELM record with no completion in Moodle. Decide with ELM |

**Sending again** is done one completion at a time, from the returned legacy site, only after the outbound guard is off
there and with ELM's confirmation recorded against that `elm_enrolment_id`.

## 4. Close

- Anything ambiguous is decided with ELM. Anything unresolved after **5 business days** goes to the owner, who records the
  outcome.
- The run log keeps the counts per class and each decision, by `elm_enrolment_id`; the extracts stay in the private run
  folder.

**Dry run (Pass B, DR06):** against a mock completion endpoint, including one request interrupted between sending and
logging, which must come out as **Received, not logged**.
