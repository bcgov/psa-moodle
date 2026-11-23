# Fourth review: replatform 950003, DRAFT v0.5

- **Reviewed:** [replatform-950003-runbook.md](replatform-950003-runbook.md), DRAFT v0.5.
- **Date:** 2026-11-23, America/Vancouver.
- **Reviewer:** Codex.
- **Disposition:** Continue Phase 1 preparation. I would not approve a test or production cutover from v0.5 as written.

I would keep the overall approach: coexistence in 950003, running legacy dependencies, an untouched original database,
and a separate return migration after commit. v0.5 addresses several concrete defects from the previous review. The
remaining problems are in the procedures that enforce those promises, particularly fencing, abandoning a return, and
preventing precommit outbound requests. There are four blockers and four major findings below.

These are corrections to the plan and its required demonstrations. The fact that Phase 1 tooling has not yet been built
is not itself a finding, and this review does not authorize executing any proposed command.

## Scope and evidence

This was a **desk review only**, following v0.5's review instructions. No commands were run against any cluster: no `oc`
inspection, pod execution, application requests, SQL, or cluster changes. The only project file written by this review is
this document. The runbook and quota draft were left unchanged.

The review used this repository, `../moodle-nginx`, and `../platform-developer-docs`, including the previous review and
its dated observations. Public Helm documentation and GitHub plugin source corroborated specific behavior; they are
linked where used. Previously recorded cluster facts were **not reverified**. In particular, storage calculations below
use the `95332Mi` prod allocation recorded in the [v0.4 review](replatform-950003-v04-review.md).

Repository references at review time:

| Repository | HEAD | Qualification |
|---|---|---|
| `psa-moodle` | `40bfaecf0b6ae81ff7892a0119a6c3901223a39c` | Contains v0.5 and its quota draft. |
| `moodle-nginx` | `c167656ada8ff45fbb747da8a8b8f5fb91e02a31` | Existing working-tree changes were preserved; source observations refer to the working tree. |
| `platform-developer-docs` | `a82ae4ecea85c1c6ee78bd230e7e6a4bc1431008` | Local platform documentation. |

Runbook line numbers below refer to the reviewed v0.5. They will move when the plan is revised.

## Findings

“Blocker” means the stated procedure can defeat a core recovery or isolation promise. “Major” means a material execution,
access, or capacity gap to close before signing off the affected procedure. Neither severity prevents local preparation.

| ID | Severity | Section and step | Concrete failure scenario | Suggested change |
|---|---|---|---|---|
| V501 | **Blocker** | §14.1 step 2; S13; §8.3 writer fence | After scaling the application to zero, `helm upgrade` changes only `outbound=off`. Helm can restore the release's positive replica counts, including cron. The outbound guard does not prevent database writes, so the return's supposedly frozen source can change during extraction. | Make the fenced state part of the rendered release, including zero application replicas and disabled application schedules; preserve it through every upgrade. Reverify all writers after the upgrade and before extraction. |
| V502 | **Blocker** | S13; §8.3; §13.4 step 1 | Both the writer fence and full shutdown require a successful `pg_stat_activity` check. With new Postgres down, the prescribed rollback can fail before reopening legacy, contradicting the required database-down rollback. | Separate infrastructure fencing from database quiescence. A precommit abort must finish without SQL; a return must require database quiescence before extracting data. |
| V503 | **Blocker** | S4; §8.2; §8.4 step 7; §15 outbound check | A blank GitHub token still reaches the plugin's HTTP client. Manual sync can send a GET, and the file-editor endpoint can send a PUT body to GitHub before authentication fails. The promised “no request reaches GitHub” check cannot pass by blanking the token alone. | Stop these paths before HTTP dispatch, or enforce effective egress isolation while preserving required SSO. Reconcile the chosen control with S7's exact-code requirement and prove absence of requests. |
| V504 | **Blocker** | §14.7; §14 “Abandon and resume” step 1; §8.3 `bailout-unswitch.sh` | Validation removes legacy's CLI maintenance file and sends restricted public Routes to legacy. Abandoning then switches PHP back to the frozen `moodle` before removing that access. In prod the original database's maintenance setting was off; an allowed browser request can now write to the frozen baseline. | Put legacy back in CLI maintenance and move its Routes to the static fence before unswitching its database. Keep legacy fenced while the new site resumes, and prove the original database remains unchanged. |
| V505 | **Major** | S15; §13.1 T−7d; §13.2 load/check/restrict sequence | The temporary Route is first explicitly restricted after real data is restored and the application is running. Also, an IP allowlist admits another admin sharing a reviewer's NAT/VPN address. A later log check detects accepted work only after rollback would discard it. | Restrict or fence the Route from creation, before loading data. Enforce reviewer identity or demonstrate that allowed source addresses are exclusive; test a non-reviewer using the same permitted address. |
| V506 | **Major** | §8.3 `bailout-switch.sh` steps 2–3; §14.6 steps 2–3; §15 return check | Cron must remain at zero, but the handover requires `which-db.php` inside every cron pod. There is no pod to inspect. A script can hang or pass an empty list without proving cron will use the returned database. | Specify separate controller-template and runtime checks. Use a temporary validation workload derived from cron's actual configuration with its normal entrypoint disabled, while the real cron controller remains at zero. |
| V507 | **Major** | §5.4; C6/C7; §11.1; prod quota draft storage budget | The draft claims 144 GiB leaves room for a restore rehearsal. The recorded legacy allocation plus the proposed 31 GiB and the existing 20 GiB restore drill totals **144 GiB + 100 MiB**, before growth or a files-restore volume. | Budget the exact coexistence and restore states. Resize/parameterize the drill, explicitly defer it under C7, or change the request. Resolve the two-versus-three Postgres replica choice in the same rendered profile. |
| V508 | **Major** | C8/C16; S12; prod quota draft, moodledata backup destination | A 6 GiB destination is budgeted for two retained copies of a current 2.93 GiB file set. That leaves about 0.14 GiB before growth or overhead; staging a third full copy while retaining two needs about 8.79 GiB. A scheduled backup can fail soon after reopening. | Define backup format, retention, staging, rotation, and growth bounds. Budget their peak space, or demonstrate a bounded alternative that preserves the required verified recovery sets. Recalculate the aggregate quota. |

## Evidence and closure requirements

### V501: the return fence must survive Helm reconciliation

Runbook lines 1036–1042 scale web, PHP and cron to zero, verify the pods are gone, and **then** run an upgrade with
`outbound=off`. They do not require the upgraded release to retain zero replicas or `cron=off`.

The current [PHP Deployment](../chart/psa-moodle/templates/php-deployment.yaml) and
[web Deployment](../chart/psa-moodle/templates/web-deployment.yaml) render replica counts when their HPAs are disabled.
The [cron Deployment](../chart/psa-moodle/templates/cron-deployment.yaml) currently renders one replica; C3 will make it
configurable, but the return occurs after cron has been enabled at commit. C5 only changes the application's outbound
configuration. None of those settings makes ordinary Moodle processing read-only.

Helm documents reconciliation of the old manifest, live state, and new manifest, including restoring replicas that were
scaled to zero outside Helm. This is why an imperative scale-down is not a durable fence across a later upgrade.
See [Helm's three-way merge explanation](https://helm.sh/docs/faq/changes_since_helm2/#improved-upgrade-strategy-3-way-strategic-merge-patches).

The optional CLI-maintenance step cannot rescue this design: §14 explicitly allows proceeding when that command fails.
If cron restarts, it can process Moodle work with ELM delivery suppressed. A momentary absence of active database sessions
does not prevent its next iteration from writing after the dump begins.

**Close with:** an explicit fenced values/profile state, an inventory of active application Jobs as well as controllers,
and a rehearsal that runs the exact upgrade after fencing. Verify no application writer returns throughout extraction,
including after a failed upgrade and a retry. Keep Postgres available for the dump.

### V502: database inspection cannot be a prerequisite for the emergency abort

S13 line 259 and the writer-fence specification at lines 745–748 both require the database session query. Full shutdown
is defined as that writer fence followed by the Crunchy shutdown flag. §13.4 uses those same procedures for rollback.
There is no database-unavailable branch, despite §9 explicitly requiring rollback with new Postgres down.

**Close with:** two explicit verification paths. Infrastructure checks must establish that application controllers and
active Jobs cannot run and ingress cannot reach the new application, without contacting its database. A precommit abort
can then restore legacy. For a return, separately require a reachable database and allowlisted sessions before extraction;
failure there stops the return. Rehearse the abort with PostgreSQL unavailable for the entire procedure, not merely
unavailable at its start.

### V503: invalid authentication is not an outbound guard

The [previous review's DR03](replatform-950003-v04-review.md) recorded these paths in deployed source. Public upstream
source corroborates the specific behavior:

- [Engine credential handling](https://github.com/PSA-Corporate-Learning-Branch/moodle-local_githubsync/blob/main/classes/sync/engine.php):
  `decrypt_pat('')` returns an empty string; the constructor passes it to the client, and `execute()` requests the latest
  commit. Relevant lines: 92–111 and 1374–1377.
- [File-editor endpoint](https://github.com/PSA-Corporate-Learning-Branch/moodle-local_githubsync/blob/main/classes/external/update_file.php):
  lines 84–93 read the configuration row, decrypt the token, construct a client, and call `update_file()` without rejecting
  an empty token.
- [GitHub client](https://github.com/PSA-Corporate-Learning-Branch/moodle-local_githubsync/blob/main/classes/github/client.php):
  lines 273–289 build the authenticated request and dispatch the JSON body; lines 353–367 dispatch reads. Neither path
  rejects an empty credential before dispatch.

This does not dispute the owner's statement that the old credential expired, and it does not claim a repository update
will succeed. A rejected HTTP request is still an outbound request; a PUT can transmit submitted content before GitHub
rejects authentication. The public upstream files are corroboration, not a fresh verification of the pinned deployment.

**Close with:** a control covering direct manual and AJAX entry points, followed by the existing §8.4/§15 test under the
actual HTTPS-capable CP3 profile. An error displayed by Moodle is insufficient evidence: demonstrate that no request is
sent. If code must change, explicitly reconcile that change with the pinned-code policy instead of silently bypassing S7.

### V504: abandoning a validated return needs to refence legacy first

The concrete sequence is:

1. §14.7 points restricted public Routes at legacy and moves it from CLI to web maintenance against `moodle_bailout`.
2. A validation check fails, and the operator chooses “Abandon and resume.”
3. Its first step runs `bailout-unswitch.sh`. The specified undo changes `DB_NAME` back to `moodle`, restores the old backup
   target, and revokes the bailout grant. It does not first restore CLI maintenance or move legacy's Routes away.
4. The original prod database still has its pre-cutover maintenance setting: off. The shared CLI maintenance file was
   removed in step 1. Reviewer traffic can now reach the original database during the rolling restart. Even ordinary
   session or login activity can write to it; a deliberate course edit is not necessary.

Moving the Routes back to the new site in the final abandon step is too late to protect that interval. IP restrictions
still permit the reviewers themselves to send requests.

**Close with:** an explicit legacy refence at the start of the abandon sequence, before any database switch. Ensure it
covers all legacy ingress, drain in-flight work, keep cron parked, and only then unswitch. In the existing “validation
failure after handover” rehearsal, leave a reviewer session refreshing while abandoning and compare the original frozen
database before and after. State exactly which maintenance state legacy retains once the new site resumes.

### V505: enforce the reviewer boundary before any exposure

S15 states the right invariant, but the execution table first calls `restrict-routes.sh` at line 981, after the new
application is up and `pg_restore` has run. The temporary Route already exists from T−7d. The current
[Route template](../chart/psa-moodle/templates/route.yaml) renders a timeout annotation but no reviewer restriction.
Resolve this ordering explicitly in C6/the Route template and the cutover table; do not depend on an operator inferring
an earlier unlisted step from S15.

Separately, a source IP is not a Moodle user identity. Shared corporate egress or VPN addresses are a concrete way an
unlisted site admin could pass the same allowlist and then bypass web maintenance. This review did not establish that
the selected reviewers actually share such an address; the plan needs to exclude or handle that case. A retrospective
log check cannot make already accepted author work disposable on rollback.

**Close with:** restriction at Route creation, explicit proof before loading real data, and a denied non-reviewer test
from an allowed source address. If exclusive addresses are the chosen boundary, document and prove that assumption.
Keep the public-hostname SSO solution from v0.5.

### V506: prove cron's future database without starting normal cron

Both legacy configuration files support the proposed `DB_NAME` switch:
[PHP config](../../moodle-nginx/config/moodle/remote.config.php), line 16, and
[cron config](../../moodle-nginx/config/cron/remote.config.php), line 66. The old configuration mismatch is therefore
addressed in the design. The problem is the verification sequence at runbook lines 774–776 and 1074–1075.

A zero-replica Deployment has no running pod in which to execute `which-db.php`. Checking zero matching pods must not
count as proving that consumer. Starting the usual cron process just to inspect it also changes the stated fence;
the legacy [cron wrapper](../../moodle-nginx/config/cron/cron.sh) runs both Moodle cron and file-backup work.

**Close with:** inspect the parked controller's effective pod template and perform a bounded runtime probe using the
same image, environment and configuration mounts, with its command overridden so neither the cron loop nor its wrapper
runs. Verify the selected database and ability to connect, and account for the probe's quota. Keep the real cron at zero
until the return commit point. The handover should fail if any inventoried consumer lacks evidence.

### V507: calculate the actual restore state, not a rounded margin

The [quota draft](quota-request-950003-prod-temporary.md), lines 70–82, proposes 31 GiB of new PVCs and says 144 GiB leaves
space for a restore rehearsal and growth. The existing [restore rehearsal](../scripts/ops/restore-rehearsal.sh), lines
69–85, requests a 10 GiB database PVC and a 10 GiB repository PVC.

| Allocation | GiB |
|---|---:|
| Recorded prod legacy allocation: `95332Mi / 1024` | 93.09765625 |
| Proposed new steady PVCs | 31 |
| Existing database restore drill | 20 |
| **Total before any growth or separate files restore** | **144.09765625** |
| Requested limit | 144 |
| **Shortfall** | **0.09765625 GiB = 100 MiB** |

C7 already offers a safe option: leave that rehearsal disabled until headroom exists. S12 requires a combined restore
demonstration in dev, so this finding does not require running the production drill during coexistence. It does require
correcting the draft's claim and choosing which restore procedure actually runs in each state.

There is also an unresolved profile choice. The draft budgets **two** Postgres instances; current chart defaults and
`values-test.yaml` use three. The local [platform Postgres guidance](../../platform-developer-docs/src/docs/database-and-api-management/postgres-how-to.md),
lines 109 and 168, recommends at least three and gives PDB guidance for deployments below that size. Two is not presented
here as a platform admission prohibition, but it is an availability tradeoff that should be explicit. Three 5 GiB
instances add another 5 GiB and approximately 400m CPU to the draft's model.

**Close with:** one rendered migration profile and a state-by-state resource ledger for coexistence, rollout, backup,
restore, return validation, and decommission. Include the new validation workload from V506 and the backup capacity
chosen for V508. Confirm admitted resources in the already-planned dev Pass A; do not treat these desk calculations as a
fresh quota measurement.

### V508: storage for two retained backups needs a peak-space model

The draft allocates 6 GiB for the live referenced file set plus growth and another 6 GiB for two retained file backups.
At the recorded 2.93 GiB source size, two uncompressed copies occupy about 5.86 GiB. Staging another full copy while
retaining both occupies about 8.79 GiB, before metadata or growth.

Compression, deduplication, incremental storage, or a different rotation order may change that requirement. None is yet
specified or bounded, and C8 permits either an archive or rsync. The current numbers therefore do not establish that the
promised retention can operate. Backing up a growing source makes this more than a one-time cutover calculation.

**Close with:** a selected implementation and measured peak storage for its real rotation sequence, including a failed
or interrupted backup. State how many verified sets remain available throughout replacement. Size from an explicit
growth limit with alerting, and update the aggregate quota rather than counting on an unspecified compression ratio.

## Disposition of the previous findings

“Addressed in design” means the written remedy is now appropriate; it still needs the implementation and rehearsals that
the runbook already requires. It does not mean a live change or a successful test occurred during this review.

| Previous item | v0.5 disposition |
|---|---|
| DR01: runtime grants | Addressed in design: explicit grant, connection proof, and revoke. |
| DR02: PHP and cron database selection | Switch design addressed. Runtime proof for parked cron still needs V506; abandon ordering needs V504. |
| DR03: manual GitHub paths | Still open: blanking/expiry does not prevent HTTP dispatch. See V503. |
| DR04: fencing and extraction | Additive-policy reliance and premature database shutdown addressed. Fence persistence and database-down abort remain open: V501/V502. |
| DR05: backup target after return | Addressed in design: retarget, run, verify, and capture the returned recovery set before reopening. |
| DR06: ELM send-before-log | Addressed in design: received records, Moodle completions, local logs, and interrupted-request rehearsal. |
| DR07: quota classification | Corrected in design: classify actual Pod specs and budget backup Jobs. New storage-budget issues are V507/V508. |
| DR08: precommit admin writes | Improved, but restriction timing and the difference between an IP and a named reviewer remain: V505. |
| DR09: SSO callback hostname | Addressed in design: restricted public hostnames retain registered callbacks. |
| Distinct state captures | Addressed in design: immutable `precutover` and `prereturn` captures with explicit uses. Preserve the active bailout database when restoring only Routes/mode/cron after a successful return. |
| Off-site timing | Owner decision accepted: checksum-verified recovery set on the encrypted laptop during the window. Retain the required independent retrieval and combined-restore proof. |

## What would change the recommendation

I would proceed with Phase 1 to implement the corrected design and prepare reviewable commands. Before a test or prod
cutover, I would require closure of V501–V508 and the existing two clean dev rehearsals, specifically exercising:

1. An outbound-off Helm upgrade while fenced, with no application writer reappearing.
2. A precommit abort with PostgreSQL unavailable throughout.
3. GitHub manual/AJAX attempts under the HTTPS-capable CP3 configuration, with no outbound request.
4. An abandoned return after legacy web validation, with the original database still unchanged.
5. Route protection before import and enforcement against a non-reviewer sharing an allowed address.
6. Runtime database proof for cron while its normal controller remains at zero.
7. The chosen backup rotation and allowed restore states within the corrected resource budget.

The plan does not need a new architecture. It needs these procedures made internally consistent, then demonstrated by the
rehearsals it already promises.
