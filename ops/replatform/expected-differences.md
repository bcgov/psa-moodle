# Expected differences (runbook §8.3, R12)

Every difference between a source and its converted target that is **accepted in advance**. `compare-content.php`
(the database) and `check-filedir.sh` (the files) are judged against this list: **any difference not on it is a no-go**
for that window. Adding an entry is an owner decision, recorded in the runbook's decision log before the window.

## Database: forward (legacy MariaDB → new Postgres)

| # | Difference | Why | Size (prod / test) | Evidence |
|---|---|---|---|---|
| D1 | `log_display` differs | `tool_dbtransfer` rebuilds it in the target from the code's log definitions | whole table | §5.2; every conversion so far |
| D2 | `search_simpledb_index` is not compared | rebuilt on the target with `search/cli/indexer.php --reindex` | whole table | §8.3 |
| D3 | 195 `bht_*` tables absent | Behat leftovers, not in XMLDB; dropped in the local copy before conversion | 195 / 195 tables | §5.2, `local-pipeline.sh clean-source` |
| D4 | `course_completion_criteria_log` and the six `local_psaelmsync_logs_*` copies absent (prod); `local_psaelmsync_enrol` absent (test) | not in XMLDB; dropped in the local copy (Q10: the archived dumps keep them) | 7 / 1 tables | §5.2 |
| D5 | trigger `trg_log_completion_criteria_delete` absent | O4: not recreated | prod only | §5.2, O4 |
| D6 | `name`, `tool_lockstats_history`, `tool_lockstats_locks` absent | not in XMLDB, so `tool_dbtransfer` skips them; all empty | 3 / 3 tables, 0 rows | §5.2 |
| D7 | `local_githubsync` tables and settings absent, and these `config` rows changed: `allversionshash`, the plugins' version hash, the cache revision counters, `registrationpending` | E7's uninstall and its required `upgrade.php --non-interactive` refresh, **only when the source predates E7** | per window | §5.3 E7 |
| D8 | NULLs in XMLDB NOT NULL columns filled with Moodle's own default: `user.timezone` → `99`, `course.format` → `topics` | Postgres enforces NOT NULL; Moodle already treats both NULLs as these values | 4,036 + 1 / 0 rows | §5.2, `xmldb-notnull.py`, `normalised-nulls-<env>.tsv` |

Byte-for-byte: binary-typed legacy columns compare with the target's text columns as raw bytes (§5.2), so a re-encoding
would show up as a difference. None is expected.

## Database: reverse (new Postgres → `moodle_bailout`, §14)

| # | Difference | Why |
|---|---|---|
| R1 | `log_display` differs | rebuilt by `tool_dbtransfer` again |
| R2 | D3-D6 stay absent | they were not migrated forward; legacy's own frozen `moodle` keeps them |
| R3 | D8's filled values stay filled | the reverse writes what Postgres holds |
| R4 | `config.rp_encryption_canary` present | created on the new stack after the forward `compare-content` (§13.2, V1012); legacy's frozen `moodle` never had it |

A reverse conversion of an unchanged forward result has shown no other difference (prod and test, 2026-11-25).

## Files (`check-filedir.sh`)

The accepted missing files are **the frozen source's own gaps, measured in the same window**, not a fixed list:

1. After the freeze, run `referenced-files.sql` against the final dump's local copy.
2. Run `check-filedir.sh` against **legacy's own `filedir`** (read-only, from a pod) with that list. The hashes it reports
   missing are the source's gaps: save them as `known-missing-<env>-<window>.txt` in the private run folder.
3. Run `check-filedir.sh` against the target with that file as the known list. It must report **no unexpected missing
   file, no wrong size and no wrong SHA-1**, and every known-missing hash must still be absent (an out-of-date list fails).

Phase 0's live figures, for comparison: **prod 3** referenced files missing (one badge's images, 2021), **test 9** (2021
user icons and backups; two H5P files, 2026-01). A count far above these is a reason to stop and look before going on.

*Not a source gap:* the backup tests' "62 known gaps" came from comparing the 18 November prod dump with files copied on
25 November: 59 more files had been deleted, and purged from `trashdir`, in between. Comparing a dump with files from
another day always produces such entries, which is why step 2 measures the frozen source itself.
