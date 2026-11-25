# Sixth review: replatform 950003, DRAFT v0.7

- **Reviewed:** [replatform-950003-runbook.md](replatform-950003-runbook.md), DRAFT v0.7, commit `1ebfdc5`.
- **Date:** 2026-11-24, America/Vancouver.
- **Reviewer:** Codex.
- **Disposition:** Continue Phase 1. I would not approve a test or production cutover yet: the proposed backup pairing
  still permits an incomplete recovery set, and cleanup ordering and backup capacity need correction.

v0.7 addresses the durable backup contents and adds reconciliation after abandoned returns. Separating resumption of the
new site from unavailable legacy cleanup is also the right direction. The main remaining problem is the new claim that
copying live directories establishes a complete file set for a database recovered to 60 seconds before the copy began.

There is one blocker, two major findings and two minor consistency corrections below. Unimplemented Phase 1 tooling is
not itself a finding. The owner's acceptance of the remaining reviewer-access risk continues to apply; this review does
not reopen that decision.

## Scope and evidence

This was a focused review of the v0.6-to-v0.7 changes and their effects on backup, return and abandonment procedures,
against the [v0.6 review](replatform-950003-v06-review.md), the repository, relevant legacy configuration, and primary
Moodle, rsync, pgBackRest and Kubernetes documentation.

**No new cluster commands were run in this pass.** Previously collected live observations remain dated evidence from
2026-11-24, not fresh measurements. No application, database, workflow or cluster resources were changed. The runbook and
quota draft remain unchanged; this review document is the only repository file added.

Two small synthetic filesystem checks ran locally under a temporary directory, which was removed afterwards. They used
the installed `/usr/bin/rsync` (`openrsync`, protocol 29 / rsync 2.6.9 compatible). These demonstrate file-copy behavior;
they are not Moodle integration tests, target-image tests or successful PostgreSQL restore rehearsals.

Line references below refer to the reviewed v0.7.

## Findings

| ID | Severity | Section and step | Concrete failure scenario | Suggested change |
|---|---|---|---|---|
| V701 | **Blocker** | §8.1 C8 pairing, lines 777–781; S12; `restore-paired.sh` | A file referenced at `T − 60 s` is deleted and purged from trash before the copy starts at T. Neither copied directory contains it. Both rsync commands and checksums of copied files can succeed, yet the database recovery target references missing content. Cleanup during the copy creates the same risk and is explicitly left as an exception. | Establish and protect the required file set across the entire capture interval. Use a coordinated freeze, or a proven capture/pinning procedure with cleanup excluded and target-reference coverage verified. Reject an incomplete set before publishing it as verified. |
| V702 | **Major** | §8.3 legacy fence/cleanup, lines 949–962; §14 abandonment step 5, especially line 1366 | Route changes do not prove already accepted legacy work has drained. The new procedure leaves PHP/web running and permits switching database templates, checking the original database and dropping the bailout database in any order, even when CLI maintenance/drain failed. Cleanup can act on a database still in use, and an early checksum does not certify the final state. | Keep resumption independent of cleanup, but make cleanup ordered and conditional: maintenance plus drain, or a proven infrastructure writer fence; switch and verify every consumer; verify the original database after those actions; then revoke/drop unused bailout resources. If a prerequisite fails, defer its dependent steps. |
| V703 | **Major** | §8.1 C8 contents and churn budget, lines 774–792; quota draft | With ordinary path-based `--link-dest` copying, a hash moved from `filedir` to `trashdir` gets another stored copy even though its bytes are unchanged. The distinct-content budget can therefore understate storage at the advertised replacement allowance. | Specify and prove sharing across both directory trees, or budget both physical copies. Measure the exact backup command under deletion/trash-cleanup cycles before retaining the stated daily churn allowance. |
| V704 | **Minor** | §8.3 `verify-legacy-fenced.sh` and pending-cleanup invariant; §14 abandonment step 3 | The verifier requires every legacy Route to target the static fence, but resumption restores the same public Route objects to the new stack. Those Routes remain legacy-owned until Phase 5, so the stated invariant becomes false after a successful resume. | Define the invariant by backend: no inventoried ingress reaches legacy. Permit the public Routes to target the new stack after resumption; reserve “must target the static page” for the intermediate state. |
| V705 | **Minor** | §8.1 C8 rotation, lines 786–789 | The job is told to delete verified sets to make room before building the incoming set, then told that a verified set is never deleted to make room for an unverified one. Both rules cannot be implemented literally. | State one policy: for example, prune only down to the explicitly accepted floor before starting, never below it, and publish the replacement only after verification. Preserve the alert when retention falls below seven. |

## Evidence and closure requirements

### V701: a clock margin does not protect files from deletion

A concrete timeline consistent with normal Moodle operation is:

| Time | Event |
|---|---|
| T − 24 hours | Previous nightly snapshot. |
| T − 2 hours | A new file is uploaded. It did not exist in the previous snapshot. |
| T − 60 seconds | The proposed database recovery target still references the file. |
| T − 45 seconds | The last reference is deleted; its content moves to `trashdir`. |
| T − 30 seconds | The daily cleanup deletes the trash contents. |
| T | The backup copies `filedir`, then `trashdir`. The required content is in neither. |

The source behavior is already described in §5.3. Moodle's `empty_trash()` removes the trash tree; it does not guarantee
that a newly deleted file remains there for a full day. The upstream
[Moodle file-storage source](https://raw.githubusercontent.com/moodle/moodle/MOODLE_405_STABLE/lib/filestorage/file_system_filedir.php)
corroborates that behavior. “Daily cleanup” describes the task's cadence, not a minimum age for each trashed file.

The local model created a synthetic content file, moved it to trash, removed it, and then copied both directories. Both
copy operations exited successfully while the required hash was absent from the resulting snapshot. No database restore
was performed; the logical target's reference was part of the model.

The runbook also explicitly permits deletion and purge during the copy, proposing to discover the missing hash after
restore. That is detection after recovery has become necessary, not proof that the published recovery set was complete.
Checksums validate the files that were copied; they cannot reveal an omitted required file without the target's reference
inventory.

**Close with:** a capture protocol that protects required hashes from the chosen database cutoff until their content is
safely captured. A short coordinated freeze is one option. A live-copy approach needs a proven way to identify and retain
the target's required hashes, including safe handling of cleanup and movement between the two directories. Verify
coverage before marking the set usable. Include the timeline above and cleanup during copying in dev tests, in addition
to the existing upload/deletion cases.

The accepted 24-hour recovery objective is not an objection here. The defect is that the proposed set may not actually
restore its own declared recovery point.

### V702: best-effort cleanup still has dependencies

H3 correctly allows the new site to resume before legacy is repaired. That does not require partially switching or
destroying legacy database resources while prerequisite checks remain unavailable.

The revised infrastructure check establishes Route targets, cron replicas and absence of active application Jobs. It
does not establish termination of requests already accepted by legacy web/PHP. Routing and connection drainage are
distinct concerns; Kubernetes documents the need to handle existing connections during workload transitions in its
[termination and endpoint tutorial](https://kubernetes.io/docs/tutorials/services/pods-and-endpoint-termination-flow/).
The runbook also already records broad internal Service access in §5.8, so Route inspection is not a universal writer
fence.

Line 1366 then permits cleanup steps 5.1–5.4 in any order. This allows dropping `moodle_bailout` while consumers still
select it, switching consumers before maintenance/drain is established, and taking the frozen checksum before subsequent
cleanup actions. The fact that failed operations are logged as pending does not make dependent later operations safe.

**Close with:** leave the database configuration alone while the new stack resumes, if safe cleanup cannot yet run.
When legacy becomes available, perform an ordered cleanup with explicit prerequisites. If an infrastructure-only writer
fence is used instead, prove it stops active work as well as new ingress and reconcile it with E2's existing prohibition
on scaling legacy PHP/web. Check the original database after the dependent actions, and drop the bailout database only
after consumers are verified away from it.

This concerns already-running work and cleanup sequencing, including the owner's own validation requests. It does not
rely on an uninvited reviewer appearing and does not reverse the accepted reviewer-access decision.

### V703: a hash can occupy two backup paths

The new backup includes both `filedir` and `trashdir`. Plain `--link-dest` matching works at corresponding paths; it is not
a repository-wide content-hash index. The rsync manual also requires the preserved attributes to match before linking.
See [rsync documentation](https://rsync.samba.org/ftp/rsync/rsync.1.html).

The local check used the proposed two-directory layout and a prior snapshot as the link destination:

| Check | Result |
|---|---|
| Copy an unchanged file to the next snapshot | Same inode: hard-link sharing worked. |
| Move that source file from `filedir/<hash-path>` to `trashdir/<hash-path>` and take another snapshot | Identical bytes, different inode from the older `filedir` copy. |
| Count stored inodes across the old file path and new trash path | Two for one content hash. |

The fixture file was 1,212,416 bytes. This was a local behavior check, not a measurement of NetApp usage or the eventual
backup image. Explicit cross-tree link destinations or another suitable storage layout could avoid the duplication;
the runbook needs to specify and demonstrate whichever approach the budget assumes.

For illustration, suppose replaced content is captured in trash once before the next cleanup, and the backup otherwise
uses ordinary path-based sharing. Across seven retained sets plus the incoming set, seven replacement intervals give:

| Component | Prod, GiB | Test, GiB |
|---|---:|---:|
| Initial live referenced set | 2.93 | 1.67 |
| Seven intervals at the stated daily replacement allowance | 4.20 | 2.10 |
| Additional copies at the trash paths | 4.20 | 2.10 |
| Illustrative peak before growth and overhead | **11.33** | **5.87** |
| Proposed destination | 10.00 | 5.00 |

These are counterexamples to the sizing assumption, not measured upload forecasts. Pruning to the three-set floor may
avoid a full volume, but it can also make the advertised allowance incompatible with retaining seven sets.

**Close with:** prove the exact implementation's storage sharing when hashes move between pools, or incorporate those
copies into the physical-space budget. Retain the full-rotation and interruption tests. The revised aggregate test quota
arithmetic itself is correct: `78948Mi / 1024 + 16 GiB = 93.09765625 GiB`, leaving `2.90234375 GiB` under 96 GiB, using the
earlier 2026-11-24 allocation.

## Disposition of the v0.6 findings

| Previous finding | v0.7 disposition |
|---|---|
| V601: abandonment depends on failed legacy PHP/Galera | Resumption is appropriately separated from unavailable cleanup. V702 addresses the remaining fence/cleanup dependencies; V704 corrects the Route invariant after resumption. |
| V602: durable dataroot state missing from backups | Addressed in design: `secret/`, `lang/`, the manifest, empty-storage restore, encryption canary and `nokeygeneration` handling. |
| V603: database/file recovery pairing | Still open. An explicit target is an improvement, but `T − 60 s` plus a live directory copy does not guarantee coverage. See V701. |
| V604: retention/churn space | Improved: larger test destination, stated allowances, staging, alerts and a low-space policy. The new two-pool layout needs V703's physical-space accounting; V705 reconciles the rotation wording. |
| V605: no ELM reconciliation after abandonment | Addressed in design: reconciliation now follows every fenced return attempt, including abandonment, with mock-endpoint tests and no blind resend. |

“Addressed in design” remains conditional on implementation and the already-required demonstrations. No new live
verification or rehearsal is implied.

## Recommendation

Proceed with Phase 1 while correcting these points. Before cutover sign-off, I would require the paired backup to survive
the cleanup race with complete target-reference coverage, the cleanup procedure to preserve its dependencies while the
new site resumes, and the actual backup rotation to fit its stated storage allowance. Keep the existing dev exit gates
and resolve the two minor wording contradictions in the implementation specification.
