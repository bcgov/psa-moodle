# Pass B, run 2: through the commit point, then a return

Window 1 ([passb-window-1.md](passb-window-1.md)) took the cutover to CP3 and rolled back. Run 2 goes the whole way, in
**950003-dev only**, in two sessions, as a real bail-out window would:
- **Session 1: the cutover to the commit point,** then a short period of live use on the new stack.
- **Session 2: the return (§14),** on a later day, back to legacy dev on `moodle_bailout`, with ELM reconciled against
  the mock.

Approval and rules are as for window 1: the owner approves each session's steps as a set, makes every checkpoint call
and approves each `deploy-950003` gate. The stop rule applies (S10), and so does the latest-abort time. Scripts run under
bash, and each step is logged only on a zero exit status (window 1's lesson).

## Already in place (2026-11-26)
- The new stack bootstrapped and fenced with the build carrying window 1's fixes (`build-exact` run 45901281051,
  `1c46829`); files pre-copied and verified with that build's ops image (6,120 intact, the 1,399 known gaps).
- Legacy dev: monitor at 0 (E4), `moodle-web` on `web` (Q17); it matches `passb1-precutover`.
- Email: legacy dev's and test's databases divert all email to the owner (`divertallemailsto`, no exceptions), and
  copies inherit it.

## Before session 1
| # | Step | Approval |
|---|---|---|
| M1 | **The ELM mock** in 950003-dev: a small HTTP service on a pinned image (`docker-remote`, by digest). It answers GET with an empty record list, and records each POST (time, path, body) to its own volume, printing only counts to its log. A "hold" switch makes the next POST wait after it has been recorded, for DR06. Labels distinct from legacy's and the release's; no Route | its own dev change |
| M2 | **A NetworkPolicy** letting only the release's php and cron pods reach the mock on its port (the release's own policies allow no in-cluster peers but Postgres and Valkey) | with M1 |
| M3 | Capture `passb2-ready`; collision check | read-only |

## Session 1: the cutover and the commit point
1. **Forward to CP3, as window 1** (T0 capture `passb2-precutover`, freeze, final dump, file delta, local
   conversion, CP1, load, `precommit`, CP2, `review`, E3, CP3), with these changes:
   - P4: the owner sets the copy's `admin` **password only**, not its email (window 1's auto-link lesson);
   - **the copy's ELM endpoints to the mock,** before CP2: `php admin/cli/cfg.php --component=local_psaelmsync`
     for `apiurl` and `completion_apiurl`. The guard keeps forcing dead addresses until the commit point; from the
     commit point the copy's own values, the mock, apply;
   - **a plain user's SSO** at CP3: the owner's SSO identity matches no live account in dev's data, so the login
     should create a new, non-admin account; record whether it does, and what the user sees;
   - the write check starts after the last planned CLI step.
2. **CP3: go** (this time).
3. **§13.3, the commit point:**
   - **S12 recovery set:** a named pgBackRest backup after the load; the moodledata backup run by hand (its first run
     on real data: time the pause); artifacts read back; the off-site copy to the owner's encrypted disk, checked
     against the checksums;
   - **record the commit point** in the window log (time, the exact command, the **ELM baseline**: the latest
     `local_psaelmsync_logs` id and time);
   - **`deploy-950003` `commit`** (gate): outbound on, cron on, the SMTP policy rendered;
   - `unrestrict-routes.sh` on `moodle-web`; `maintenance.php --disable` on the new site.

   Verify: the guard shows real values; a cron run succeeds; **a test email reaches the owner** (diverted); the mock
   records the sync task's GET and no POST yet; the public hostname serves the new stack to anyone; the nightly
   backup is scheduled.
4. **Live use (about 30 minutes, synthetic records only):** uploads, edits and deletes; a course restore from `.mbz`;
   a quiz attempt; **synthetic course completions** (the mock must record each POST); two tags differing only by an
   accent (RB08); a new course and user (fresh IDs). Record what was created.
5. Leave the new stack live (dev's site). The nightly backup runs on real data that night.

## Session 2: the return (§14), on a later day
1. **§14.0:** capacity (Galera's free space at least twice the database; legacy moodledata's reserve); the recovery
   package current; **`state-capture.sh passb2-prereturn`**; **`frozen-checksums.sql`** on the frozen `moodle`;
   **`reverse-precheck.sh`**. RB08's accent-distinct tags must be found **before** the conversion, then resolved per
   `unique-conflicts.md`.
2. **§14.1:** `writer-fence.sh` (Postgres stays up); `quiescence-pg.sql`; **ELM end-mark**. Before it, start one
   completion with the mock on **hold** and kill its php pod mid-request: the DR06 interrupted request.
3. **§14.2:** the local reverse conversion (`local-pipeline.sh dev reverse`), `compare-local.sh dev reverse`,
   `mariadb-dump`, `bailout-dump-check.sh`.
4. **§14.3–14.4:** `moodle_bailout` and its import account on legacy dev's Galera; `bailout-import.sh`; compare; the
   files add-only; `check-filedir` against `moodle_bailout.files`.
5. **Go/no-go 1 (§14.5).**
6. **§14.6:** `bailout-switch.sh` (grant, `DB_NAME=moodle_bailout` on every consumer, `which-db.php`, the cron probe,
   the backup retarget).
7. **§14.7:** clear `mdl_sessions` in `moodle_bailout`; `purge_caches.php`; Routes restricted and pointed at legacy;
   web maintenance; validation through the public hostname: versions, the session-created records and files present,
   admin and SSO, a fresh ID, and **a cookie saved before the return refused** (V1203).
8. **Go/no-go 2 (§14.8), separate approval:** the recovery set; `unrestrict-routes.sh`; Routes, maintenance and
   cron from **`passb2-precutover`**; `DB_NAME` stays `moodle_bailout`. **The return's commit point.**
9. **§14.9 ELM reconciliation (DR06)** against the mock's record, per `elm-reconcile.md`: every synthetic completion
   classified, and the interrupted one must come out **Received, not logged**. Nothing re-sent blindly.

Afterwards, legacy dev runs on `moodle_bailout`; its frozen `moodle` stays as the evidence. The new stack stays fenced
until the owner decides (§13.4 step 6).

## Estimates
Session 1: about 2.5 h (75 minutes to CP3, as window 1, plus the commit point and live use). Session 2: about 2.5–3 h;
window 1's timings and the dry runs set each session's latest-abort time.
