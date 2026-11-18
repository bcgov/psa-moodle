# Independent review: replatform 950003 runbook

- **Date:** 2026-11-18
- **Reviewer:** Codex
- **Document reviewed:** [replatform-950003-runbook.md](replatform-950003-runbook.md), DRAFT v0.1
- **Purpose:** Findings for Claude and the owner to review when revising the runbook.
- **Disposition:** Proceed with the in-place architecture and preparation, but do not execute this draft against test or prod yet.

## Recommendation

I would run with the in-place replatforming approach, but I would not execute this draft against test or prod yet. Keeping Galera running, copying data, treating test as production, and rehearsing rollback in dev are sound choices. The main weakness is that the promised recovery path is less safe than the document claims.

Keep this direction and revise sections 13–14 before proceeding to rehearsals. Require the dev rehearsal to demonstrate recovery from a **failed reverse import** and a rollback under the intended quota constraints. Those are the tests that would make the “cannot strand us” promise credible.

“Blocker” below means resolve before the affected migration step; it does not prevent continuing discovery and preparation. The findings distinguish contradictions or missing safeguards from the chart changes already acknowledged as C1–C8.

## Review scope and limitations

The review examined this repository, `../moodle-nginx`, `../moodle-dev`, relevant surrounding assessments, and `../platform-developer-docs`. It also used read-only cluster queries, reads of deployed source files, and small SQL queries inside `START TRANSACTION READ ONLY` transactions.

No cluster resources or existing files were changed during the review. No migration, maintenance, or application scripts were executed. This review file was subsequently created at the owner's explicit request. The runbook has not been edited.

These observations are a point-in-time review, not a completed migration rehearsal or a substitute for the runbook's Phase 0 re-verification. No public-site smoke tests, failover drills, full data comparisons, or restore tests were performed. Operator-version inspection was restricted by RBAC.

## Owner clarification

The owner stated during the review: **“nothing uses the github sync plugin currently.”**

Treat GitHub sync as unused, leave it disabled on migration copies, and remove it as a required live cutover acceptance dependency. The live database had one saved GitHub sync configuration with automatic sync disabled. Its scheduled task was enabled, but that alone does not establish business use or an active course synchronization.

This clarification does not resolve the separate ELM outbound-safety issue in R2.

## Live observations

The following observations were collected on 2026-11-18 using the owner's authorized read-only access to Silver.

| Check | Observed |
|---|---|
| Available aggregate storage quota | Dev **28.66 GiB**; test **18.90 GiB**; prod **2.90 GiB** |
| Aggregate storage requested | Dev `68958Mi/96Gi`; test `78948Mi/96Gi`; prod `95332Mi/96Gi` |
| Available long-running CPU requests | Dev **2.670 cores**; test **2.625**; prod **1.025** |
| Long-running CPU requests used | Dev `1330m/4`; test `1375m/4`; prod `2975m/4` |
| Database versions | Both test and prod are MariaDB **10.6.20** |
| Moodle versions | Test **2024100711.03**, Build **20260519**; prod **2024100711.04**, Build **20260525** |
| Authentication | Both use core `oauth2`, with “BC Government Login” enabled |
| Production Routes | Both `moodle-custom` and `moodle-web` point to legacy `web` |
| Production custom hostname | `learning.gww.gov.bc.ca`; its Route carries a custom certificate |
| Production platform hostname | `moodle-950003-prod.apps.silver.devops.gov.bc.ca` |
| Production Route timeouts | `moodle-web` has `haproxy.router.openshift.io/timeout: 180s`; `moodle-custom` has no explicit timeout annotation |
| Health monitor | Prod and dev have `MANUAL_MODE=true`; test has `MANUAL_MODE=false`, with Galera scale-to-zero failsafe and automatic maintenance enabled |
| Dev readiness | Galera remains **4/5**; Routes point at the maintenance service |
| Test maintenance flag | `maintenance_enabled=1`; recorded without attempting to change it or diagnose user-facing availability |
| Production SMTP | `smtphosts=apps.smtp.gov.bc.ca` |
| Production web services | Enabled; 25 token records exist, not independently classified as active or in use |
| Production table engines | All 719 tables reported as InnoDB |
| GitHub sync | One saved configuration; zero configurations with automatic sync enabled |
| Existing psa-moodle proof of concept | A Postgres 15 cluster is present in `a58ce1-dev` |

The storage figures are **requested PVC capacity against quota**, not filesystem utilization. In particular, `95332Mi` is about **93.10 GiB**, not 95.3 GiB. Aggregate quota remains binding even where a storage-class-specific quota has more headroom.

The running proof of concept also demonstrates resource requests that are not visible just by summing application containers in Helm templates: its Postgres pod has three additional containers requesting `50m` CPU and `256Mi` each, and its repository host has two containers requesting those amounts. Recheck the admitted resources for the intended new deployment rather than treating these observed defaults as a permanent sizing contract.

## Findings

| ID | Severity | Section / step | Concrete failure scenario | Suggested change |
|---|---|---|---|---|
| R1 | **Blocker** | Section 13, before CP2 | The plan enables **outbound and cron before moving the Route or approving reopening**. Deployed Moodle code confirms web maintenance does not suspend cron. The copy can send mail or ELM completions, then rollback restores legacy without those processing records. | Keep cron and business integrations disabled through CP3. Explicitly stop the new stack's processing before every rollback. Treat enabling external side effects as a commit point. |
| R2 | **Blocker** | Section 8.2, outbound switch | Disabling plugin scheduled tasks does **not** disable ELM completion reporting. The deployed observer directly POSTs completion data; the nominal completion scheduled task is actually empty. Core completion processing or manual actions can invoke the observer. | Apply a fail-closed guard to every ELM entry point, including observers and manual endpoints, backed by suitable egress restrictions. Apply protection to local copies too. GitHub sync can remain disabled and be removed from cutover acceptance requirements. |
| R3 | **Blocker** | Section 13 T0; section 14 step 1 | Web maintenance still permits privileged users and certain web-service access. “No new log rows” does not prove all writers have stopped. Scaling cron down without draining it can interrupt work. Concurrent database/file copying can therefore capture inconsistent state. | Specify a rehearsed drain-and-freeze procedure for requests, cron, ad hoc tasks, and other writers before taking the final database/file pair. Keep Galera running. |
| R4 | **Blocker** | Section 14 steps 4–6 | The reverse import **replaces the frozen legacy database**. If it fails halfway, the stated last resort—repointing to frozen legacy—no longer exists. These database/file writes also contradict S1/S2's permitted exceptions. | Preserve a separately recoverable frozen baseline; define recovery from a partially failed reverse import and rehearse that failure. Add explicit bail-out write exceptions and validate the imported database/files before routing users back. |
| R5 | **Blocker** | Sections 8.2–8.3; S7 | Upgrading the test copy from `.03` to `.04` leaves untouched legacy test running older code. Allowing plugins “at least as new” creates the same downgrade problem. Reverse database conversion does not reverse Moodle upgrades. | Resolve build alignment as a separate prerequisite. Pin exact core/plugin revisions and image identities; fail the migration on unexpected version differences rather than automatically upgrading the copy. |
| R6 | **Blocker** | Section 11 CPU plan; section 13 rollback | Prod frees CPU by stopping legacy components, but checkpoint undo instructions mostly restore only cron and maintenance. Redis, proxy, PHP and web may still be stopped; restarting them while the new stack remains fully scaled can exceed quota. | Write the full reverse scaling sequence, including HPA handling, readiness checks and capacity release. Budget operator-generated sidecars, rollout surge, backup jobs and recovery capacity—not just Helm-rendered requests. |
| R7 | **Major** | Section 13 CP2 | Setting `wwwroot` to the public hostname and then checking through the temporary Route does not reliably test the replacement. Deployed Moodle explicitly redirects mismatched hosts; checks can land back on legacy. | Test with the temporary canonical URL first, or use a rehearsed private access path preserving the public hostname. Verify which stack answered, then perform public-host checks after switching. |
| R8 | **Major** | Section 13 Route switch | There are **two** production Routes. Switching one leaves another path to legacy. Also, patching only the backend does not apply the new chart's 900-second timeout: `moodle-web` currently has 180 seconds, and the custom Route has no explicit timeout annotation. | Enumerate both Routes, their intended final behavior, certificates, ports and timeouts, with exact undo patches. Preserve certificates throughout. |
| R9 | **Major** | Section 9 prerequisites; section 5.5 | Disabling only the weekly schedule does not freeze legacy deployment automation. Other triggers remain. Legacy maintenance scripts enumerate **all Routes**, so distinct `psa-moodle-*` names do not protect the new Route. Test's active monitor can invoke those paths. | Make deployment/maintenance automation controls mandatory before coexistence, including existing queued runs. Name every controller being paused and its restoration conditions. |
| R10 | **Blocker** | Section 11 backups versus Q11/C8 | Q11 requires off-site protection before cutover, but section 11 postpones it until the bail-out window closes. New learner work could spend ten business days without that protection. A one-time copy also leaves ongoing recovery undefined. | Require working, scheduled database **and moodledata** backups before reopening, with retention, failure alerts, compatible recovery points and a demonstrated combined restore. |
| R11 | **Major** | Section 8.1 networking; section 15 email | Imported prod settings use `apps.smtp.gov.bc.ca`, but the chart's SMTP egress rule selects **backup components only**, excluding Moodle PHP and cron. Application email would be blocked under the current policies. | Add explicitly controlled application SMTP egress for the live state and verify delivery during the activation sequence. |
| R12 | **Major** | Section 8.4; section 15 validation | Matching row counts and finding filenames cannot establish lossless conversion. `tool_dbtransfer` also rebuilds `log_display`, and counts naturally change after reopening, making blanket equality at 24 hours unsuitable. | Compare frozen baselines before application activity; document expected transformations; validate important field values and file hashes. Rehearse new writes followed by reverse migration and verification in legacy. |

## Additional corrections

### Maintenance commands need to be explicit

In the deployed Moodle version:

- `admin/cli/maintenance.php --enable` enables CLI maintenance, including the offline file.
- `admin/cli/maintenance.php --enableold` sets web maintenance.
- The legacy `config/moodle/enable-maintenance-mode.sh` wrapper supplies `--enable --wait`, but `--wait` is not a supported option in the deployed maintenance script.

Do not reuse that wrapper without correction. Choose and rehearse the exact commands for each stage; maintenance mode is not itself proof that every writer has stopped. The official [Moodle 4.5 CLI documentation](https://docs.moodle.org/405/en/Administration_via_command_line#Maintenance_mode) also documents the CLI maintenance/offline-file behavior.

### Evaluate the union of live NetworkPolicies

Existing namespace-wide ingress allowances remain additive. The chart's narrower policies do not remove them. In particular:

- Prod's `allow-all-internal` selects all destination pods and permits traffic from the project prod/tools namespaces.
- Test's corresponding policy also permits traffic from the project dev namespace.
- Existing router ingress allowances select all destination pods.

The review did not perform connectivity probes or exploitation tests. The finding is based on policy manifests and their additive semantics. Do not claim per-component isolation solely from the new chart's policy selectors.

## Evidence for the reviewer

### Repository evidence

- [Runbook cutover and bail-out](replatform-950003-runbook.md), sections 13–14.
- [Replacement Moodle configuration](../config/moodle/config.openshift.php): fixed `wwwroot`, `reverseproxy=false`, PostgreSQL prefix, and session configuration.
- [Replacement image build](../Containerfile.php): core and plugin cloning currently follow branches rather than exact revisions.
- [Replacement network policies](../chart/psa-moodle/templates/networkpolicy.yaml): broad external HTTPS allowance; SMTP allowance selects only backup components.
- [Replacement PostgresCluster template](../chart/psa-moodle/templates/postgrescluster.yaml) and [values](../chart/psa-moodle/values.yaml): storage, resource requests, backups, and intended Route timeout.
- [Local ELM observer](../../moodle-dev/plugins/psaelmsync/classes/observer.php), [event registration](../../moodle-dev/plugins/psaelmsync/db/events.php), and [completion scheduled task](../../moodle-dev/plugins/psaelmsync/classes/task/process_course_completion.php).
- [Legacy maintenance wrapper](../../moodle-nginx/config/moodle/enable-maintenance-mode.sh).
- [Legacy emergency maintenance routing](../../moodle-nginx/openshift/scripts/utils/maintenance-mode.sh), [maintenance deployment](../../moodle-nginx/openshift/scripts/deploy-maintenance-message.sh), and [maintenance removal](../../moodle-nginx/openshift/scripts/remove-maintenance-message.sh): namespace-wide Route handling.
- [Legacy build workflow](../../moodle-nginx/.github/workflows/build.yml): schedule and additional triggers.

Local plugin source is development context, not proof of the exact deployed revision. The ELM observer and empty completion-task behavior were separately confirmed by reading deployed source.

### Deployed source evidence

The following files were read from a running production PHP pod without executing Moodle:

- `/var/www/html/admin/cli/maintenance.php`: supported options and maintenance semantics.
- `/var/www/html/lib/classes/cron.php`: CLI maintenance suspends cron; web maintenance is not the corresponding stop condition.
- `/var/www/html/admin/cli/cron.php`: task-draining controls exist and need a rehearsed procedure.
- `/var/www/html/lib/setuplib.php`: mismatched request hosts are redirected when `reverseproxy=false`.
- `/var/www/html/webservice/lib.php`: maintenance access depends on the caller's maintenance-access capability.
- `/var/www/html/admin/tool/dbtransfer/cli/migrate.php` and `locallib.php`: target checks, schema-checked database transfer, and rebuilding of target `log_display` entries.
- `/var/www/html/lib/dtl/`: database-transfer implementation.
- `/var/www/html/admin/index.php` and `/var/www/html/lib/upgradelib.php`: version/downgrade handling.
- `/var/www/html/local/psaelmsync/classes/observer.php`: direct outbound completion POST.
- `/var/www/html/local/psaelmsync/classes/task/process_course_completion.php`: empty `execute()` implementation.

Read-only observations of namespace quotas, Routes, NetworkPolicies, workloads, selected ConfigMap script lines, admitted resource requests, and selected database configuration underpin the live findings above. Credentials, certificate private keys, token values, and learner records are not included in this document.

## Platform alignment

The architecture broadly follows the supplied platform guidance: Crunchy-managed Postgres, block storage for database files, and temporary coexistence quota are reasonable choices.

- [Quota adjustment guidance](../../platform-developer-docs/src/docs/automation-and-resiliency/request-quota-adjustment-for-openshift-project-set.md), Example 3, supports requesting temporary migration capacity. It does not guarantee approval.
- [Postgres guidance](../../platform-developer-docs/src/docs/database-and-api-management/postgres-how-to.md) supports operator-managed database configuration and block storage for database PVCs.
- [Backup guidance](../../platform-developer-docs/src/docs/database-and-api-management/database-backup-best-practices.md) calls for a defined, tested recovery process, not merely the existence of backup files.
- [Storage guidance](../../platform-developer-docs/src/docs/platform-architecture-reference/platform-storage.md) identifies `netapp-file-backup` as the file class backed up daily by OCIO and distinguishes file/block snapshot support.
- [NetworkPolicy guidance](../../platform-developer-docs/src/docs/platform-architecture-reference/openshift-network-policies.md) explains additive allow rules and the platform default policy.

Postgres 15 is running in the existing proof of concept. The review could not independently establish the current operator version through cluster-scoped inspection because the user's RBAC denied those reads. Retain that verification as an explicit Phase 0 item.
