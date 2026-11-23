# Third review: replatform 950003, DRAFT v0.4

- **Reviewed:** [replatform-950003-runbook.md](replatform-950003-runbook.md), DRAFT v0.4.
- **Date:** 2026-11-23, America/Vancouver.
- **Reviewer:** Codex.
- **Disposition:** Continue local preparation, but do not approve a test or production cutover from v0.4 as written.

The overall approach is sounder now, especially keeping legacy dependencies running and preserving the original database.
I would retain D1–D3 and the phased rehearsal strategy. However, concrete recovery and isolation defects remain, including
live-confirmed database permissions and configuration differences that can defeat the proposed return procedure.

Before sign-off, the four blocking designs below need correction, the return needs working backup protection, and the
resulting procedures need demonstration in the two clean dev rehearsals already required by the runbook. Those rehearsals
must exercise the specific failure paths identified here.

## Scope and limits

This review covers the runbook, previous reviews, relevant chart and workflow code, legacy source, supplied platform
documentation, and authorized read-only cluster inspection. Live inspection included resource configuration, selected
deployed source files, filesystem capacity, and small SQL metadata and aggregate queries inside read-only transactions.

No cluster resources, application data, maintenance settings, workflows, images or services were changed. No migration,
restart, failover or restore was attempted. The public application was not exercised. No credentials, certificate private
keys, encryption keys, learner records or database dumps are included here.

The original runbook remains unchanged. This review document was saved separately at the owner's request after the review
was delivered in conversation. The observations establish design defects and current configuration; they do not establish
that a recovery rehearsal has passed.

## Findings

“Blocker” means resolve before relying on the affected procedure for a production-grade migration. “Major” means a material
gap that also needs closure before signing off the recovery promise. These findings supplement the earlier R1–R12 and
RB01–RB14 reviews; the already-planned implementation work is not itself being reported as a new defect.

| ID | Severity | Section and step | Concrete failure scenario | Suggested change |
|---|---|---|---|---|
| DR01 | **Blocker** | §14.3–14.6; E5; D3 | The live application account has database privileges on `moodle.*` only. Creating a restricted import account does not give PHP or cron access to `moodle_bailout` after the switch. | Add an explicit runtime-account/grant step and its undo. Prove that PHP and cron can access the returned database before handover. |
| DR02 | **Blocker** | §8.3 `bailout-switch.sh`; §14.6 | PHP and cron mount different configuration ConfigMaps. Switching only PHP leaves cron targeting frozen `moodle`; after maintenance is lifted and cron resumes, it can write there. | Enumerate and switch both configurations, save both undos, and verify the effective database identity of every application consumer. |
| DR03 | **Blocker** | §8.2 C5; S4; O2 | GitHub manual sync and the AJAX file editor bypass the proposed plugin-setting overrides. Both environments retain a configuration with a stored credential. A copy with HTTPS access can reach GitHub before commit. | Block all GitHub entry points or enforce network isolation that permits only required SSO traffic. Prove manual reads and writes are blocked before commit. |
| DR04 | **Blocker** | S13; §8.1 fencing; §14.1–14.2 | An added deny-all NetworkPolicy cannot override existing allows. The full S13 fence shuts down Postgres, preventing the following dump, while §14.1's shorter sequence omits explicit PHP/web shutdown and relies on a Helm change. | Define separate procedures for complete shutdown and stopping application writers while retaining database access for extraction. Enumerate ingress paths and writer workloads, and verify their termination before dumping. |
| DR05 | **Major** | §14.8 reopening legacy; S12 | Legacy backups explicitly target `moodle`. After a successful return, new work resides in `moodle_bailout`, so scheduled backups continue protecting the wrong database. | Retarget and verify scheduled backups, and require a verified database-and-files recovery set before reopening legacy. Include the backup changes in the return and undo procedures. |
| DR06 | **Major** | §14.1 ELM end-mark; §14.9 reconciliation | The ELM HTTP request occurs before its local log insertion. A crash or forced cron termination between those operations can leave a delivered completion without a local log entry. | Reconcile ELM-side receipts against Moodle completion records, including interrupted requests and missing local logs. Do not treat the local log-ID interval as a complete delivery ledger. |
| DR07 | **Major** | §5.4 quota; §9 Pass A; §11 capacity | The inspected backup Jobs lack Pod-level `activeDeadlineSeconds`, so they do not qualify for the separate time-bound quota. Treating them as time-bound understates long-running CPU demand. | Budget their concurrent requests against long-running quota unless the admitted Pods actually qualify. Verify the Pod specification, not merely the workload kind or a Job-level timeout. |
| DR08 | **Major** | §13.2 CP2/CP3; precommit access | Web maintenance admits other site admins. After public Routes switch, an admin can make ordinary course changes before commit; rollback then discards those changes. | Restrict precommit access to designated reviewers and enforce the synthetic-data-only acceptance boundary. Preserve a working original-host SSO validation path. |
| DR09 | **Major** | §14.7 validation; `admin-check-route.yaml` | Return validation requires SSO through a temporary admin Route while public Routes remain fenced, but §10 says SSO works only on the public hostname. | Specify and rehearse restricted access using the registered hostname, or arrange a valid temporary callback before the window. |

## Supporting evidence and implications

### DR01 and DR02: D3 needs a complete application handover

Read-only SQL in both `950003-test` and `950003-prod` reported:

- Application identity: `moodle@%`.
- Selected database: `moodle`.
- Global privilege: `USAGE`.
- Database privileges: `moodle.*` only; no privileges on `moodle_bailout` were returned.

The plan creates `moodle_bailout_import` with privileges on the return database and drops that account after import.
That is useful import containment, but it does not provide the application's runtime access. The necessary runtime grant
or account change must be included explicitly in E5, with verification and undo.

Live workload definitions and selected ConfigMap source lines confirmed this mapping in both test and prod:

| Consumer | ConfigMap | Mounted file | Database selection |
|---|---|---|---|
| `deployment/php` | `moodle-config` | `/var/www/html/config.php`, via `subPath` | `$CFG->dbname = $_SERVER['DB_NAME'];` |
| `deployment/cron` | `cron-config` | `/var/www/html/config.php`, via `subPath` | `$CFG->dbname = $_SERVER['DB_NAME'];` |

The relevant assignments are at line 16 of the inspected `moodle-config` entry and line 66 of `cron-config`. The singular
“config.php ConfigMap” instruction is insufficient. Restarting cron does not make it consume PHP's different ConfigMap.

The deployed `lib/classes/cron.php` checks `CLI_MAINTENANCE` before running tasks. The shared dataroot's
`climaintenance.html` supplies that gate. Removing the file during return validation/reopening also removes the gate for
cron, even if cron still selects the original database. Consequently, this is a potential write to the supposedly frozen
baseline, not just a failed background task.

### DR03: the retained GitHub plugin has additional outbound paths

Read-only aggregate queries found one row in `local_githubsync_config` in each environment, with `auto_sync = 0` and a
nonempty stored credential. This review did not read or test the credential and does not establish that it remains valid.

The deployed source shows:

- `local/githubsync/classes/github/client.php:35` hardcodes `https://api.github.com` as `API_BASE`.
- Its `update_file()` method calls an authenticated HTTP `PUT` through `api_write_request()`.
- `local/githubsync/classes/external/update_file.php:84` reads the per-course configuration directly from
  `local_githubsync_config`, then decrypts `pat_encrypted` and constructs the GitHub client.
- `local/githubsync/db/services.php` declares the file editor functions with `ajax => true`.
- `local/githubsync/sync.php` invokes the sync engine directly from a logged-in web request.
- The engine likewise reads the repository URL and credential from the per-course record.

These paths do not consult hypothetical `apiurl`, `apitoken` or `enabled` plugin-setting overrides. Disabling the scheduled
task covers the scheduled entry point only. Disabling REST web services does not disable Moodle's logged-in AJAX interface
or the direct manual-sync page.

This matters when a test/prod copy has HTTPS access for SSO. The local/dev internal-network protection is useful, but it
does not establish that the application guard protects every later migration state.

### DR04: separate a writer fence from complete shutdown

Live namespaces still contain broad `allow-all-internal` and router ingress allowances. Kubernetes NetworkPolicies are
additive: a new policy with no allowed traffic does not revoke traffic permitted by another matching policy.
See the [Kubernetes NetworkPolicy semantics](https://kubernetes.io/docs/concepts/services-networking/network-policies/#the-two-sorts-of-pod-isolation).

The chart also contains explicit egress allowances. Merely adding another deny-all policy does not revoke those either.
The existing PoC's Crunchy-generated Pods carry operator labels rather than the Helm release selector labels, so any
policy intended to select database Pods needs an explicit selector check as well.

Scaling application writers to zero can provide an effective fence, but the exact sequence and completion checks must
carry that guarantee. The runbook currently offers two incompatible levels of shutdown:

- S13 and `fence-new.sh` include application shutdown and Crunchy shutdown.
- §14.1 lists Route changes, cron zero, a Helm outbound change and optional application maintenance, followed by a live
  database dump in §14.2.

Define a return procedure that stops every application writer while leaving Postgres available to the extraction account.
Define a separate full shutdown for cases where database access is unnecessary. Include the temporary Route, relevant
Jobs and autoscaling behavior in the inventory. A point-in-time activity check alone does not prevent a still-running
application from reconnecting later.

Crunchy's supported shutdown mechanism is appropriate for the full-shutdown case:
[Crunchy administrative tasks](https://access.crunchydata.com/documentation/postgres-operator/latest/tutorials/cluster-management/administrative-tasks).

### DR05: a successful return must also move backup coverage

Both live `moodle-db-backup-storage-config` ConfigMaps contain this target:

```text
mariadb=mariadb-galera:3306/moodle
```

Changing PHP's or cron's database configuration does not change this independent backup target. The return needs a
verified backup of the returned database and matching files, plus scheduled protection for subsequent writes. A healthy
backup process targeting the frozen database would otherwise give false reassurance.

### DR06: ELM delivery can precede the audit record

In the inspected `local/psaelmsync/classes/observer.php`, `curl_exec()` occurs at line 152 and insertion into
`local_psaelmsync_logs` occurs at line 201. The log is therefore evidence of recorded attempts, not an atomic record of
every external delivery. Forced termination during the intervening work can create an unlogged delivery.

The existing reconciliation plan is directionally right. Its input set must include ELM's records and the actual Moodle
completion state, with explicit handling for requests interrupted during shutdown and ambiguous delivery outcomes.

### DR07: observed backup workloads use long-running quota

The PoC's `psa-moodle-pg-repo1-full` and `psa-moodle-pg-repo1-incr` CronJobs had no Job-level or Pod-level
`activeDeadlineSeconds`. The repository's
[backup-integrity template](../chart/psa-moodle/templates/cronjob-backup-integrity.yaml) and
[restore-rehearsal template](../chart/psa-moodle/templates/cronjob-restore-rehearsal.yaml) also omit Pod-level deadlines.

Kubernetes classifies Pods with no `.spec.activeDeadlineSeconds` as `NotTerminating` for quota purposes; merely belonging
to a Job does not make a Pod `Terminating`. See [quota scopes](https://kubernetes.io/docs/concepts/policy/resource-quotas/#quota-scopes).

The instruction to measure admitted resources in Pass A remains correct. That measurement must cover peak concurrent
backup/restore work and rollouts in the quota class actually charged. The final 950003 values and quota request remain
to be established; this finding does not establish that test requires an increase.

## Two further procedure details to resolve

### Distinct state captures

Keep immutable, separately named captures for the original pre-cutover state and the start-of-return state. At the start
of §14, legacy is already frozen with cron at zero; that is different from the operating state to restore after a
successful return. §14.0 takes a new capture, while §14.8 says to restore captured states without identifying which capture.

Make each restore operation name its intended capture explicitly. This prevents restoring frozen maintenance/cron values
or the wrong Route targets, and preserves the separate state needed to abandon the return and resume the new site.

### Off-site backup timing

S12 is a good requirement, but the final recovery set must satisfy it within the agreed window. Writing an archive to
`netapp-file-backup` does not establish that OCIO has already copied that specific archive off-site.

The supplied [platform backup guidance](../../platform-developer-docs/src/docs/automation-and-resiliency/netapp-backup-restore.md)
describes monthly full backups, daily incremental backups and a coordinated restore request process. Establish the
mechanism and timing for proving off-site availability of the final post-import database-and-files set before scheduling
the window. A prior successful retrieval does not prove that the newly created set has been captured.

## Live facts rechecked and stale statements

| Item | Observation on 2026-11-23 |
|---|---|
| Test health monitor | `MANUAL_MODE=true`, contrary to §5.5/Q18's recorded `false`; the Deployment remains at one replica. |
| Test and prod web images | Both Deployments reference `web-security-patch` images by digest, rather than the mutable image described in §5.5. |
| Legacy dev | Four Galera Pods; both Routes still target `maintenance-message`. It is not yet the required healthy rehearsal source. |
| Legacy test/prod | Five Galera Pods each; inspected database connections reported `Primary`, `Synced`, cluster size 5 and readiness `ON`. |
| Moodle builds | Test remains `2024100711.03`; prod remains `2024100711.04`. |
| Maintenance flags | Test `1`; prod `0`. |
| Long-running CPU used | Dev `1330m/4`; test `1375m/4`; prod `2975m/4`. |
| Aggregate storage quota used | Dev `68958Mi/96Gi`; test `78948Mi/96Gi`; prod `95332Mi/96Gi`. Prod still has approximately 2.90 GiB unallocated. |
| Production Routes | Both target `web` on port `8080`; the custom Route has a custom certificate and no timeout annotation, while the platform Route has `180s`. |
| Database schema | Test 713 tables; prod 719. The production trigger `trg_log_completion_criteria_delete` remains present. |
| GitHub configuration | One configured row with a stored credential in each environment; automatic sync is off for those rows. Credential validity was not tested. |

These observations should replace the stale dated facts where applicable. They do not replace the required pre-phase
inventory or establish future capacity, backup availability or recovery timing.

## Evidence needed for sign-off

- A rehearsed D3 handover and undo that covers application privileges, both application ConfigMaps, and backup targets.
- A verified writer fence that works with PHP unavailable or a failed rollout, while permitting the database extraction
  needed for a return.
- Proof that the retained GitHub plugin cannot make manual or scheduled outbound requests before commit, including in
  the SSO-capable migration profile.
- Restricted precommit reviewer access and a working SSO validation path on the intended hostname.
- ELM reconciliation that covers interrupted requests and deliveries missing from the local log.
- Admitted peak-capacity measurements using the correct quota scopes, and a practical mechanism for meeting the final
  off-site recovery-set gate.
- The two clean dev rehearsals already required by §9, updated to demonstrate these corrected procedures and their
  failure cases.

I would continue Phase 1 preparation with these corrections. I would approve the production-grade cutovers only after
the revised procedures and the required rehearsal evidence are available for review.
