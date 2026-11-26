# Dataroot inventory (runbook §5.3, §8.3, RB07)

What the moodledata copy (O1, `moodledata-copy-job.yaml`) takes from legacy's `moodle-data` PVC, and what it leaves.
Legacy keeps everything until decommission (Phase 5), so nothing left here is lost.

Top-level entries as listed read-only on 2026-11-26 (P = prod, T = test, D = dev):

| Item | Where | Copied? | How | Why |
|---|---|---|---|---|
| `filedir/` | P T D | **referenced hashes only** (O1) | `rsync --files-from` the list from `referenced-files.sql` against the final dump; checked by `check-filedir.sh` | content-addressed; prod's 557 unreferenced files (5.25 GiB) stay on legacy |
| `lang/` | P T D | **yes, whole** | `rsync -a`; file checksums recorded on both sides | language customisations: **empty in prod and test**, 2 files in dev (2022) |
| `secret/` | P T D | **yes, whole**; key files kept at 0400 | `rsync -rlt` | Moodle's encryption key, `secret/key/sodium.key` (mode 0400, as Moodle creates it; the `secret/` and `secret/key/` directories are 777 in prod and test). Values encrypted with it stay readable (the canary, §8.3). Only the namespace's own UID can read it, which the copy Job and the nightly backup both run as |
| `psaelmsync_apitest_state.json` | T D | **yes, if present** | `rsync -a` | state of `local_psaelmsync`'s API test page (`api-test.php`, `$CFG->dataroot . '/psaelmsync_apitest_state.json'`); harmless while the outbound guard is on |
| `antivirus_quarantine/` | P T D | no | n/a | empty in prod and test |
| `.quarantine-20260826T190745Z/` | P T | no | n/a | one file each, from the 2026-05 recovery; kept on legacy |
| `muc/` | P T D | **never** | n/a | `muc/config.php` points at legacy Redis; the new stack builds its own cache configuration |
| `trashdir/` | P T D | no | n/a | content no record references; Moodle's own cleanup empties it (J2) |
| `cache/`, `localcache/`, `temp/`, `sessions/` | P T D (varies) | no | n/a | regenerated; most of legacy's live caches are under `/var/shared` or the RAM disk anyway |
| `.htaccess` | P T D | no | n/a | Moodle writes its own deny-all file into the dataroot |
| `vendor/` | P | no | n/a | empty |
| `cdata_tools/` | T | no (**Q**: owner) | n/a | 8 hand-run PHP scripts from 2024-09 (`import.php`, `enr-ins.php`, ...); no Moodle code reads them. Kept on legacy until decommission; copy them out first if anyone still uses them |
| `persistent/` | T | no | n/a | one leftover file under `temp/`, 2022 |
| `cdata.json` | D | no | n/a | 2022; no code reads it |
| `models/` | D | no | n/a | analytics model folders, no files |
| `8a67be2eed31256bcc24e02d4b9ab5ad/` | D | no | n/a | one file, 2023; nothing references it |
| anything else | n/a | **stop** | n/a | not reviewed: the copy Job lists the top level first and refuses on an unlisted entry |

Recorded per window, in the private run folder: the top-level listing of the source, the `lang/` and `secret/` file
checksums on both sides, and `check-filedir.sh`'s report.
