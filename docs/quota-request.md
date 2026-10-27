# Initial quota request — PSA Moodle on a new license plate

Prepared: **2026-10-22**. Evidence review: **2026-10-26**. Target: a **new Silver project set**, license plate to be assigned (`<new-plate>-dev`, `-test`, `-prod`, and `-tools`).

This request replaces the earlier proposal to enlarge the reused `a58ce1` project set. `a58ce1` is the proof of concept; `950003` is the existing Moodle architecture. Neither is the destination of this request. The figures below are a proposed **initial provisioning budget**, not measured production demand or a completed migration sizing exercise.

## Project description for registration

Moodle learning platform operated by the BC Public Service Agency.

This project replaces the existing `bcgov/moodle-nginx` deployment (`950003`) with a more maintainable OpenShift architecture. The work includes migrating from MariaDB Galera to Crunchy PostgreSQL, reducing reliance on custom operational code, and improving alignment with BC Gov Private Cloud platform and security guidance.

The replacement will support continued operation of the current Moodle service while we pursue an anticipated, but not yet confirmed, migration to vendor-hosted Moodle Workplace.

## Proposed totals for the quota adjustment

Register the new project set first. Once it is provisioned, inspect its actual quotas and use these proposed totals for the adjustment request. Registration and quota approval are separate steps; this document does not establish that the registration form can provision these amounts directly.

| Registry column | CPU (cores) | Memory (GiB) | Storage (GiB) |
|---|---:|---:|---:|
| Development Namespace | **6** | **32** | **256** |
| Test Namespace | **6** | **32** | **256** |
| Production Namespace | **6** | **32** | **256** |
| Tools Namespace | **0.5** | **2** | **1** |

These are the **requested totals**, not additions to the defaults. CPU and memory figures budget pod **requests**. Storage budgets PVC capacity, including the backup and recovery volumes listed below. Leave tools at its defaults: the current plan uses GitHub Actions for builds and a shared image registry, with no dedicated CI server or persistent tools workload.

The proposal gives dev, test, and prod the same capacity ceiling so each can run the same HA topology, autoscaler bounds, rollout procedures, and recovery tests. It does not require all environments to consume that ceiling continuously. Provisioning can proceed in stages, and requests should be reviewed after representative operation.

**Revision after live inspection:** memory is now 32 GiB, replacing the earlier provisional 16 GiB recommendation. Existing production used 16.45 GiB in the sampled metrics window, predominantly in its five MariaDB nodes, despite declaring only 5.47 GiB of memory requests. This is not a PostgreSQL benchmark, but it warrants a larger database allowance and tuning margin before migration. CPU and storage recommendations remain unchanged.

**Approval route:** request manual review with this document as the initial capacity plan and the [quota evidence report](quota-evidence.md) as supporting evidence. A new project set has no utilization history. Do not claim that the utilization-based automatic approval criteria are met: the platform guidance lists multiple conditions, including utilization thresholds and adjustment size, not simply “above 35%.” Sysdig is optional; the report uses exported OpenShift monitoring data.

### Evidence readiness and decisions before submission

The capacity plan alone was not a complete evidence package. On 2026-10-26 we collected fresh quota, admitted-container, replica and PVC inventories for `950003-dev/test/prod` and `a58ce1-dev`; fourteen-day per-pod CPU/memory summaries for existing production and the prototype; and fourteen-day utilization summaries for **all 11 production PVCs**. The [evidence report](quota-evidence.md) identifies the observation window, queries, exports, limitations, and refresh procedure.

That evidence supports a **manual initial-capacity review**, not a claim that the replacement has already demonstrated a need for these ceilings. Existing production averaged 0.141 CPU cores and 17.62 GiB of memory over the observed period. Its peak five-minute CPU rate was 2.361 cores and its sampled memory peak was 19.47 GiB. The architecture is different, and the prototype has no representative production load.

**The requested amounts remain provisional.** This model includes full HA/HPA capacity in all three environments, components that are not implemented yet, and concurrent recovery work. Before submitting the adjustment, reconcile that scope with the six-week bridge delivery plan. In particular, justify why dev needs the full ceiling as well as test/prod, distinguish fixed replicas from optional autoscaling, and identify which maintenance operations really need to overlap. A smaller or staged request requires a revised allocation table; neither these measurements nor this review silently changes the totals above.

## Paste-ready justification for the registry

### 1. Why do you need to increase your quota?

We are requesting initial resources for a new PSA Moodle project set, replacing a proof of concept hosted in the reused `a58ce1` space. Please allocate 6 CPU cores, 32 GiB memory, and 256 GiB storage to each of dev, test, and prod so the same highly available application topology, autoscaling envelope, deployment surge, backups, and isolated recovery tests can be exercised before production; tools can remain at 0.5 CPU, 2 GiB memory, and 1 GiB storage.

### 2. Current and desired states of the relevant OpenShift objects

The new project set does not exist yet and has no utilization history. The default 0.5 CPU / 2 GiB memory / 1 GiB storage cannot accommodate the proposed application and its database. We have validated the application in `a58ce1-dev`, but that single-replica proof of concept is not a production-capacity benchmark.

The desired topology per application environment is three web replicas, three PHP replicas, three Crunchy PostgreSQL instances, an HA Valkey session/cache service, one Moodle cron runner, monitoring, backup repositories, and recovery automation. Web may scale to five replicas and PHP to six. With a proposed 2 GiB request per database container, the modeled baseline is approximately 2.38 CPU and 11.53 GiB of memory requests; the autoscaler maximum is approximately 3.08 CPU and 13.25 GiB. Allowing simultaneous rollout surge, one temporary restore database and repository, operational jobs, and an additional database-sized contingency brings the planning envelope to approximately 4.49 CPU and 20.53 GiB. The requested 6 CPU / 32 GiB ceiling provides a further margin for operator defaults and tuning. The existing production architecture currently has a 32 GiB memory-request ceiling too; we are retaining that ceiling while changing the architecture.

The PVC plan totals 224 GiB at recovery-test peak, including 84 GiB on `netapp-file-backup`. We request the documented 256 GiB storage tier, and confirmation of the aggregate and storage-class quotas described below. Live inspection on 2026-10-22 found 93.10 GiB of production PVC capacity allocated against a 96 GiB quota, 8.95 GiB used on the Moodle data volume, and approximately 973 MiB of database table/index allocation. The new storage budget covers HA copies, backups, and isolated restores rather than only the source dataset. PostgreSQL migration size, backup retention, and representative workload metrics remain to be validated.

Supporting exports cover 2026-10-12 22:00 UTC through 2026-10-26 22:00 UTC. Existing production averaged 0.141 CPU cores and 17.62 GiB memory, with a peak five-minute CPU rate of 2.361 cores and sampled memory peak of 19.47 GiB. Its 12 GiB Moodle data volume reached 9.18 GiB used; its 20 GiB file-backup volume reached 16.89 GiB used (84.4%). Per-pod averages/peaks, replica counts, requests/limits, and all PVCs are detailed in the accompanying evidence report. These observations establish source-system demand and storage behaviour; they are not a PostgreSQL or replacement-architecture load test.

### 3. What steps have you taken to fit the application into the current quota?

We first proved the replacement architecture with a small single-replica deployment. The design packages application code into immutable images, uses one shared Moodle data volume rather than duplicating it for every application replica, replaces the legacy Galera database and custom Redis proxy arrangement, bounds autoscaling, and runs one Moodle cron worker. Build execution remains in GitHub Actions, and recovery resources are temporary and must be removed after each test.

The requested headroom addresses deployment and recovery operations as well as steady state. Test needs capacity to exercise the agreed production topology and recovery procedures. Giving dev the same ceiling is a proposed convenience that must be justified separately; a smaller development environment is an available optimization. No comparative right-sizing or load test of the replacement has yet been completed. We will use the attached source-system history to guide those tests, review requests and quota after the first 30 days of representative operation, and reduce unused capacity where it does not prevent the agreed tests. We are not presenting configured requests as measured CPU or memory consumption.

## Environment parity: what needs to match

Equal quotas are **not technically necessary** for equivalent environments. Quota is an admission ceiling; the chart, pod configuration, and running replicas determine the deployment. A 6-core namespace and an 8-core namespace can run the same application if it fits in both. Conversely, equal quotas do not make a one-instance database equivalent to a three-instance database.

For this new project, matching initial ceilings is a reasonable way to avoid another quota-driven difference between environments. The operational target is a shared HA configuration, with intentional differences kept explicit:

| Keep consistent | Legitimate environment differences |
|---|---|
| Image promotion, PHP/Moodle/plugin versions at the release being tested | Development may contain the next release candidate |
| Replica topology, database failover, cache/session failover | Traffic level and sanitized test data |
| Per-container requests and limits; FPM settings | Credentials, URLs, SSO clients, and notification destinations |
| Autoscaler bounds during scale/failure tests; rollout strategy | Actual replica count within those bounds |
| Storage classes, network policies, probes, backup/recovery mechanisms | Dataset size and retention, where deliberately documented |

A leaner dev environment is a valid alternative, but it would not validate every production failure mode. Test should match production's topology and exercise its scaling/recovery envelope. This proposal follows the preference for all three environments to be capable of that same exercise.

Live inspection on 2026-10-22 found that `950003-dev`, `950003-test`, and `950003-prod` **already have equal quotas**: 4 CPU, 32 GiB memory, and 96 GiB storage each. Their deployed configurations differ: dev has one PHP replica while test/prod have three; web CPU requests are 25m in dev/test and 100m in prod; Redis and Sentinel requests are 25m each in dev/test and 150m each in prod. All current PHP containers request 100m CPU. The historical sizing CSVs list different production PHP/web requests and must not override this live inventory. The new project therefore needs a shared deployment profile as well as matching quota ceilings.

## CPU and memory calculation — per application namespace

All figures below are **requests**, not limits or observed consumption. `1000m = 1 CPU core`; `1024Mi = 1GiB`. The current chart supplies the web, PHP, database CPU, exporter, and cron requests. The proposed database memory request, operator overhead, and future HA cache components are identified separately below. These planning changes have not been applied to the chart or cluster.

| Component | Baseline / maximum count | CPU per pod (m) | Memory per pod (Mi) | CPU at maximum (m) | Memory at maximum (Mi) |
|---|---:|---:|---:|---:|---:|
| nginx web | 3 / 5 | 50 | 64 | 250 | 320 |
| PHP-FPM plus exporter | 3 / 6 | 201 | 544 | 1,206 | 3,264 |
| PostgreSQL plus sidecars and exporter allowance | 3 / 3 | 401 | 2,880 | 1,203 | 8,640 |
| pgBackRest repository host allowance | 1 / 1 | 100 | 512 | 100 | 512 |
| Planned Valkey data nodes | 3 / 3 | 50 | 128 | 150 | 384 |
| Planned Valkey Sentinel allowance | 3 / 3 | 25 | 64 | 75 | 192 |
| Moodle cron | 1 / 1 | 100 | 256 | 100 | 256 |
| **Baseline total** | | | | **2,381** | **11,808 (11.53 GiB)** |
| **Autoscaler maximum total** | | | | **3,084** | **13,568 (13.25 GiB)** |

The PostgreSQL allowance comprises 250m / **2,048Mi** for the database container, three 50m / 256Mi supporting containers, and a 1m / 64Mi exporter. The proposed database memory request is higher than the chart's current 512Mi request: the legacy database's memory footprint makes that small PoC request an unsuitable production sizing assumption. The 2 GiB figure remains a planning allowance to validate with PostgreSQL migration and load tests, not a measured requirement. Review its current 2 GiB memory limit at the same time.

Live `a58ce1-dev` pods confirm three supporting database containers (`replication-cert-copy`, `pgbackrest`, and `pgbackrest-config`), each admitted with 50m / 256Mi requests. The repository host has two containers with those same requests, confirming its 100m / 512Mi allowance. Monitoring is disabled in the PoC; the exporter allowance comes from the chart. Operator defaults can change: set explicit resources and verify admitted pods in the new namespace.

Valkey HA is **planned, not implemented in the current chart**. The budget allows three data nodes and three small Sentinel processes/pods; a supported implementation may colocate them or use a different layout. Validate its failover behaviour and resource footprint before production. The proposal does not carry forward the legacy custom Redis proxy.

| Additional simultaneous allowance | CPU (m) | Memory (Mi) |
|---|---:|---:|
| One PHP surge pod and one web surge pod | 251 | 608 |
| Temporary restore database and its repository host | 500 | 3,328 |
| Integrity/rehearsal controllers and a backup/copy job | 250 | 640 |
| One additional database-sized contingency | 401 | 2,880 |
| **Combined maximum plus allowances** | **4,486 (4.486 cores)** | **21,024 (20.53 GiB)** |
| **Requested ceiling** | **6,000** | **32,768 (32 GiB)** |
| **Remaining margin** | **1,514** | **11,744 (11.47 GiB)** |

The final contingency is a planning reserve for operator variation or an extra database-sized maintenance pod, not a claim that normal PostgreSQL failover always creates a fourth instance. No peak utilization measurements are available for this target architecture yet.

### Quota scope and limits

The temporary PostgreSQL cluster created by a restore job still consists of operator-managed database/repository pods. It must fit the long-running quota; it does not automatically inherit the controller Job's quota classification. Kubernetes distinguishes `Terminating` and `NotTerminating` scopes by the pod's `activeDeadlineSeconds`, not simply by whether the initiating object is a Job.

The model conservatively includes the operational-job allowance in its combined budget until admission behaviour is verified. Also confirm that the provisioned time-bound quota allows at least **1 CPU and 2 GiB of memory requests** for transient jobs. This is a supplemental confirmation for Platform Services, not an extra field to invent in the registration form. The chart's current backup jobs do not explicitly set a pod deadline; check their admitted scope before enabling them.

The 32 GiB figure budgets `requests.memory`; it is not a cap on instantaneous memory consumption. The inspected long-running quotas enforce memory requests, not aggregate memory limits. Inspect the new namespace's quota and LimitRange separately. The sum of container memory limits can exceed the requests budget, and implicit operator-container limits must not be mistaken for measured needs. Pin sensible requests and limits before deploying the full profile; if Platform Services also enforces an aggregate memory-limit ceiling, agree that ceiling against the rendered and admitted containers.

## Storage calculation — per application namespace

This plan uses a 32 GiB Moodle data allowance and 10 GiB per PostgreSQL instance as initial capacity assumptions. Live production has a 12 GiB Moodle data PVC using 8.95 GiB and five 10 GiB MariaDB PVCs; the sampled database volume uses 3.61 GiB. Its table/index allocation is approximately 973 MiB. Those measurements support the initial allowances but do not establish the PostgreSQL migration footprint or backup retention capacity. Historical CSV database sizes are superseded by the live inventory.

| PVC purpose | Class | Count × size (GiB) | Total (GiB) | Status |
|---|---|---:|---:|---|
| Shared Moodle data | `netapp-file-standard` | 1 × 32 | 32 | Proposed initial allowance; current test chart is 20Gi |
| PostgreSQL data | `netapp-block-standard` | 3 × 10 | 30 | Current chart's HA allocation |
| HA Valkey persistence | `netapp-file-standard` | 3 × 2 | 6 | Planned HA extension; current chart has one PVC |
| Local pgBackRest repository | `netapp-block-standard` | 1 × 20 | 20 | Current chart allocation |
| Moodle file backup destination | `netapp-file-backup` | 1 × 64 | 64 | Planned backup implementation |
| Secondary database backup destination | `netapp-file-backup` | 1 × 20 | 20 | Planned backup implementation |
| Temporary restore database | `netapp-block-standard` | 1 × 10 | 10 | Explicit class must be added to rehearsal configuration |
| Temporary restore repository | `netapp-block-standard` | 1 × 10 | 10 | Explicit class must be added to rehearsal configuration |
| Isolated Moodle file-restore workspace | `netapp-file-standard` | 1 × 32 | 32 | Planned complete recovery test |
| **Total at recovery-test peak** | | **13 PVCs** | **224** | |
| **Requested aggregate quota** | | | **256** | **32 GiB remaining margin** |

By class, this is **70 GiB file-standard**, **70 GiB block-standard**, and **84 GiB file-backup**. Please confirm class-specific quotas sufficient for these amounts as well as the 256 GiB aggregate quota. If class allocations use tiers, 128 GiB for each class is sufficient; those per-class ceilings are not additive permission to exceed the aggregate 256 GiB cap.

The platform storage guide lists a 256 GiB tier and says backup quota defaults to half the storage size. An associated 128 GiB backup ceiling would cover the modeled 84 GiB, but it must be confirmed on the newly provisioned project set. **The 84 GiB backup capacity is already included in the 224 GiB total**, not added a second time outside the aggregate budget.

Keep the default **60-PVC allowance and five VolumeSnapshots**. The current moodledata snapshot workflow is disabled; this request does not depend on it or request extra snapshots. The file-backup class is described as receiving daily OCIO backups. Do not assume block storage or an in-cluster pgBackRest repository alone provides that protection; confirm the recovery and retention service with Platform Services.

These backup PVC sizes are initial allowances, not validated retention guarantees. In particular, the current chart requests seven full pgBackRest backups in a 20 GiB repository: seven uncompressed full copies of a near-full 10 GiB database would exceed that capacity even before WAL and incremental backups. Measure actual full-backup sizes, WAL/incremental growth, file churn, and required retention; resize or revise the plan before migration. Validate restore-workspace sizing at that same point. Larger real datasets can require a larger initial request or a later adjustment.

## Evidence and implementation boundaries

### Live inventory — 2026-10-22

This older sample is retained for provenance. The [2026-10-26 evidence report](quota-evidence.md) supplies the refreshed inventory and the historical averages/peaks to use with the submission.

Read-only inspection used `oc get resourcequota`, `oc get pods`, `oc get pvc`, `oc adm top pods --containers`, filesystem `df -k`, and an aggregate `information_schema.tables` query. No cluster configuration or application data was changed. Quantities below are rounded only for presentation.

| Namespace | CPU requests / quota (cores) | Memory requests / quota (GiB) | PVC capacity / quota (GiB) | Sample CPU use (cores) | Sample memory use (GiB) |
|---|---:|---:|---:|---:|---:|
| `950003-dev` | 1.080 / 4 | 5.10 / 32 | 67.34 / 96 | 0.089 | 6.57 |
| `950003-test` | 1.375 / 4 | 5.47 / 32 | 77.10 / 96 | 0.177 | 6.06 |
| `950003-prod` | 2.975 / 4 | 5.47 / 32 | 93.10 / 96 | 0.140 | 16.45 |
| `a58ce1-dev` | 0.900 / 1 | 2.69 / 16 | 19 / 64 | 0.031 | 0.29 |

CPU and memory use are sums of the reported container metrics from one collection, **not historical averages, peaks, or a load test**. Existing production's five MariaDB containers account for 15,363Mi (15.00 GiB) of its 16,848Mi sampled memory use, while declaring only 256Mi each. This mismatch is evidence to revisit requests, not a direct forecast for the replacement three-instance PostgreSQL cluster. Neither the low sampled CPU use nor request/quota occupancy establishes the form's sustained-utilization criteria.

Production's allocated PVC capacity is **96.98%** of its storage quota; this is not 96.98% filesystem fullness. All three legacy namespaces have a separate 48 GiB file-backup ceiling and equal time-bound quotas of 4 CPU / 32 GiB. The PoC has a 32 GiB file-backup ceiling and a 1 CPU / 16 GiB time-bound quota. No time-bound quota usage was reported in this collection.

| Production storage measurement | Provisioned (GiB) | Filesystem used (GiB) | Interpretation |
|---|---:|---:|---|
| `moodle-data` | 12 | 8.952 | Whole volume, including regenerable files; not just user uploads |
| `moodle-app-data` | 2 | 1.180 | Shared code volume; replacement images eliminate this PVC |
| `data-mariadb-galera-0` | 10 | 3.608 | One of five replicas; includes database files and logs |
| `file-backup-data` | 20 | 8.061 | Current backup destination occupancy; no retention guarantee inferred |
| `moodle-db-backup-storage-backup-pvc` | 7 | 2.272 | Current database backup destination occupancy |
| `moodle-db-backup-storage-verification-pvc` | 2 | 0 | Currently empty verification volume |

The application database reports **719 tables and 972.71 MiB of table/index allocation** through `information_schema`. This is an engine-reported estimate, not a dump size or the eventual PostgreSQL disk requirement. The other four 10 GiB MariaDB PVCs and a 100Mi shared PVC complete the 93.10 GiB allocated production inventory; their used bytes were not sampled. The new budget accounts for three database replicas, larger file allowances, two backup destinations, and concurrent isolated restores.

### Provenance and outstanding validation

| Evidence | Date / provenance | How it is used |
|---|---|---|
| Exported monitoring history and refreshed inventory | [2026-10-26 evidence report](quota-evidence.md), with local source exports and checksums | Per-pod averages and sampled peaks over fourteen days, all production PVCs, current requests/limits, replica counts, quota scopes and allowances |
| Current `psa-moodle` chart and templates | Repository `56c375d`, reviewed 2026-10-22 | Configured requests, HA/HPA bounds, storage classes, and enabled workflows |
| Live namespace inventory and metrics | 2026-10-22, `950003-dev/test/prod` and `a58ce1-dev` | Quotas, admitted requests, PVC sizes, and sampled container utilization tabulated above; no historical average or peak claims |
| Production filesystem and database measurements | 2026-10-22, `950003-prod` | Used bytes and table/index estimate above; PostgreSQL conversion and retention remain unvalidated |
| Admitted PostgreSQL operator containers | 2026-10-22, `a58ce1-dev` | Confirms supporting-container count and default requests used in the model |
| Existing dev deployment | 2026-10-21 | PHP 8.3.36 rollout and application operation validated; single-replica PoC only |
| Legacy sizing CSVs and template | `moodle-nginx` checkout `c167656`, reviewed 2026-10-22 | Historical context; superseded by live measurements where they differ |
| Platform developer documentation | Checkout `573c44fda31dcd40253430ca763dbbb14dbc90d4`, dated 2026-10-16 | Quota process, units, storage tiers, default requests, and HA guidance |

The old dev request's 90% CPU figure was **quota occupancy by declared requests**, not measured CPU utilization. It must not be used as evidence for utilization-based automatic approval. The discovery worksheet remains incomplete for full migration planning; the sizing evidence above fills only the headline capacity questions.

Approval of this capacity adjustment would increase the new project set's quotas. Before deploying the complete shared profile:

1. Replace `a58ce1` namespace/registry references with the assigned new plate, and create the new environment-specific URLs, secrets, RBAC, and CI configuration.
2. Define a shared HA profile for dev/test/prod. The existing dev values are still single-replica, and no production values file exists; equal quotas alone will not change those settings.
3. Implement and validate Valkey HA, secondary database backup, Moodle file backup, and file recovery. These are budgeted work items, not completed chart features.
4. Set explicit operator/backup-job requests, limits, deadlines, and storage classes, including the proposed database memory allowance. The existing rehearsal script leaves storage classes and instance requests unspecified; do not copy that omission into the new environment.
5. Collect representative per-container CPU/memory averages and peaks, measure the PostgreSQL conversion footprint and full/incremental backup sizes, and validate file retention and complete recovery. Refresh the source measurements before migration and revise this budget if required.
6. Verify admitted quota scopes, class quotas, HA placement, failover, rolling deployments at HPA maximum, and complete restore/cleanup. Review capacity after 30 days of representative operation.

This document requests initial namespace capacity; it does not submit the form, migrate data, change the existing clusters, or authorize retirement of either existing plate.

## Sources

- [Platform quota-adjustment guidance](https://github.com/bcgov/platform-developer-docs/blob/573c44fda31dcd40253430ca763dbbb14dbc90d4/src/docs/automation-and-resiliency/request-quota-adjustment-for-openshift-project-set.md)
- [Platform quota units, scope, and default requests](https://github.com/bcgov/platform-developer-docs/blob/573c44fda31dcd40253430ca763dbbb14dbc90d4/src/docs/automation-and-resiliency/openshift-project-resource-quotas.md)
- [Platform storage tiers and backup quotas](https://github.com/bcgov/platform-developer-docs/blob/573c44fda31dcd40253430ca763dbbb14dbc90d4/src/docs/platform-architecture-reference/platform-storage.md)
- [Platform HA database guidance](https://github.com/bcgov/platform-developer-docs/blob/573c44fda31dcd40253430ca763dbbb14dbc90d4/src/docs/database-and-api-management/high-availability-database-clusters.md)
- [Kubernetes quota scopes](https://kubernetes.io/docs/concepts/policy/resource-quotas/#quota-scopes)
- Repository inputs: [base values](../chart/psa-moodle/values.yaml), [test values](../chart/psa-moodle/values-test.yaml), [Postgres template](../chart/psa-moodle/templates/postgrescluster.yaml), [restore rehearsal](../scripts/ops/restore-rehearsal.sh), and [remaining implementation work](next-steps.md).
