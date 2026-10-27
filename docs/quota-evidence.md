# Quota evidence — 26 October 2026

This report accompanies the [proposed quota adjustment](quota-request.md). It supplies actual source-system usage, current allocations, and a repeatable collection process. It supports a **manual initial-capacity review** for a new project set. It does not prove the proposed replacement needs 6 CPU / 32 GiB / 256 GiB in each environment, or that those amounts will be approved.

## What the platform asks for

The [quota-adjustment guide](https://github.com/bcgov/platform-developer-docs/blob/573c44fda31dcd40253430ca763dbbb14dbc90d4/src/docs/automation-and-resiliency/request-quota-adjustment-for-openshift-project-set.md) asks for averages and spikes per replica, replica/HPA counts, requested resources, PVCs and the components using them, usage over time, and an explanation of optimization already attempted. **Sysdig is optional.** OpenShift monitoring exports are an acceptable evidence source under that guidance.

The accompanying [resource-monitoring guide](https://github.com/bcgov/platform-developer-docs/blob/573c44fda31dcd40253430ca763dbbb14dbc90d4/src/docs/app-monitoring/resource-monitoring-dashboards.md) recommends two weeks, or at least one week, of data. This is guidance for a convincing request, not a requirement to leave a new empty namespace running for two weeks before asking for usable capacity.

| Evidence | Available now | Remaining limit |
|---|---|---|
| Current quotas, scopes, requests/limits, replica counts and PVC inventory | Fresh read-only exports for `950003-dev/test/prod` and `a58ce1-dev` | New project set does not exist yet |
| Per-pod CPU/memory averages and sampled peaks | Fourteen-day OpenShift exports for production and the prototype | Different architectures and workloads; not a replacement load test |
| Storage utilization and its variation | Fourteen-day summaries for all 11 production PVCs | New PostgreSQL footprint and new backup retention still unmeasured |
| Allocation plan for the requested totals | Component, rollout, recovery and PVC budgets in the quota request | Full HA/HPA in all three environments remains a proposed scope |
| Optimization evidence | Small PoC, immutable application images, shared Moodle data, bounded replica plan | No comparative right-sizing test of the replacement has been completed |
| Historical daily/weekly/seasonal context | A fourteen-day observation window with per-pod summaries | No claim that October represents annual peak demand; record workload context and retain time-series graphs if requested |

## Observation method and source files

Historical queries cover **12 October 2026 22:00 UTC through 26 October 2026 22:00 UTC**, equivalent to 15:00 PDT on both dates. Queries evaluate every five minutes. All namespace memory series and all 11 production PVC series returned **4,033 evaluation points**, including both endpoints. A returned point is not proof of uninterrupted application availability or complete underlying scrapes.

CPU is `rate(container_cpu_usage_seconds_total[5m])`, summed across application containers in each pod. Memory is `container_memory_working_set_bytes`, also summed per pod. Both use the platform's kubelet/cAdvisor series and exclude empty/POD containers. Namespace totals are calculated at each timestamp **before** calculating their average or maximum. PVC statistics use `max by (persistentvolumeclaim)` to avoid double-counting a shared volume reported by multiple mounts/nodes.

The tables are exports from the authenticated OpenShift **Developer → Observe → Metrics** view, using **Export as CSV** on the query table. Queries are pinned to the end timestamp `1793052000`; the local attachment directory contains the readable PromQL and export metadata. No application load was generated and no cluster resources or permissions were changed.

Important interpretation limits:

- CPU peaks are maximum **five-minute rates evaluated every five minutes**. Memory and storage peaks are maximum **five-minute samples**. Faster spikes can be missed.
- Per-pod averages cover the samples available for that pod. Replacement and retired pods have shorter histories. Do not sum their individual means to infer namespace demand or their separate maxima to infer a simultaneous peak.
- Requests in the per-pod tables are the **current admitted regular-container requests**. They are not historical request measurements. Retired pods are marked unavailable.
- Allocated PVC capacity, used filesystem bytes, pod resource requests, resource limits and observed usage are separate measurements.
- The historical exports are summaries of retained time series, not a load test or a complete export of every underlying sample. Missing measurements are shown as unavailable, never zero.

The local attachment directory is `artifacts/quota-evidence/2026-10-26/`. It is ignored by Git so cluster exports are not accidentally published. The tracked report retains the findings; the local directory retains the supporting files for a response to Platform Services.

| Attachment | Contents |
|---|---|
| `950003-dev.json`, `950003-test.json`, `950003-prod.json`, `a58ce1-dev.json` | Allowlisted quota, LimitRange, workload, pod, PVC and metrics API records with collection times |
| Corresponding namespace `.md` files | Human-readable inventories, including every admitted container and PVC-to-pod references |
| `950003-prod-history.csv` | Per-pod and namespace CPU/memory averages, sampled maxima and memory sample counts |
| `a58ce1-dev-history.csv` | The same observations for the prototype, including short-lived pods where metrics exist |
| `950003-prod-storage-history.csv` | Each production PVC's start/end usage, mean, sampled maximum, capacity and sample count |
| `950003-prod-history.promql`, `a58ce1-dev-history.promql`, `950003-prod-storage-history.promql` | Reproducible historical queries |
| `history-metadata.json`, `manifest.json` | Window, source, collection metadata and SHA-256 checksums |

## Findings relevant to the request

1. **The history supports a memory allowance and backup working space, but does not measure the replacement's requirements.** Production averaged 17.62 GiB of memory and reached a sampled 19.47 GiB. Its five MariaDB nodes dominate that use. The new PostgreSQL cluster must be measured separately.
2. **CPU is usually low, with material bursts.** Production averaged 0.141 cores and reached a 2.361-core five-minute rate. Those values do not establish sustained pressure requiring a six-core quota. Replica requests, deployment overlap and recovery allowances need their own explanation.
3. **The latest backup sample understates the observed working space.** The 20 GiB file-backup PVC ended at 8.06 GiB used but reached 16.89 GiB (84.4%). The cause of that peak was not investigated. A replacement backup design must measure its own temporary space and retention requirements.
4. **Moodle data is smaller than allocated storage.** Its 12 GiB PVC reached 9.18 GiB used. The proposed 224 GiB peak PVC allocation is primarily a topology/backup/recovery budget, not a claim that 224 GiB of source content exists. Production allocates 93.10 of its 96 GiB quota across all PVCs; that is quota occupancy, not filesystem fullness.
5. **The prototype is not production capacity evidence.** It averaged 0.023 CPU cores and 0.268 GiB memory, with a sampled 0.335 GiB memory peak. It confirms a small deployment can run, not that these resources can serve production traffic.
6. **Some pod settings need explicit testing.** The legacy cron history includes a 2.70 GiB memory sample. The new cron's planned 256 MiB request and current 512 MiB limit must be checked with representative scheduled tasks; namespace headroom alone cannot prevent a container from exceeding its own limit.

## Before and after the new project set is approved

1. **Register now.** Existing-system evidence can accompany the later adjustment. The new namespace does not need invented utilization history.
2. **Settle the requested operating scope before submitting the adjustment.** Decide which environments need the complete rehearsal topology, whether HPA is in the six-week delivery scope, and which restore/rollout operations must overlap. Update the allocation tables if that narrows the request. The current totals remain provisional.
3. **When the plate is assigned, collect its actual quotas and LimitRanges.** Confirm aggregate storage, each storage-class quota, long-running and time-bound compute scopes, and any limit ceilings. Enter requested **totals**, with any increase calculated from the actual provisioned values.
4. **Attach both the plan and this evidence.** Describe it as an initial migration-capacity request supported by source-production history and a small PoC. Explain that old and new project sets overlap during migration and that old capacity can only be released after cutover, recovery validation and the agreed rollback period. Do not promise a retirement date before that plan is agreed.
5. **Collect target metrics from the first deployment.** Migrate representative data, run scheduled tasks and backups, exercise the agreed replica topology and restore procedure, and load-test before final right-sizing. Review quota after 30 days of representative operation. A possible later vendor migration is not an approved expiry date for this capacity.

## Refresh the evidence

The [collector](../scripts/ops/collect-quota-evidence.py) uses an existing `oc` login and only reads resource APIs. It excludes secrets, environment variables, application data and logs. Calls are sequential with a two-second pause; this reduces connection bursts but is not a guarantee about the platform's connection-limit accounting.

```sh
python3 scripts/ops/collect-quota-evidence.py \
  950003-dev 950003-test 950003-prod a58ce1-dev \
  --output "artifacts/quota-evidence/$(date -u +%Y%m%dT%H%M%SZ)"
```

Use the assigned new namespace names for its inventory after provisioning. The collector refuses to overwrite an earlier run and exits nonzero if any API collection fails. Its current metrics sample does **not** replace the historical exports.

To refresh history, open the relevant namespace in OpenShift **Observe → Metrics**, turn refresh off, and paste the corresponding saved `.promql` query. Set the end timestamp to the desired UTC cutoff and retain the fourteen-day range and five-minute step, or record any deliberate change. Run the query, check for errors and missing series, and use its menu to **Export as CSV**. Record the new period and source before replacing any reported figures. Keep the old exports separately. If a reviewer needs daily/weekly graphs, use the underlying CPU, memory and PVC expressions over that same period; the existing CSVs contain summary statistics, not every time-series point.

### Sysdig access and onboarding

On 26 October, the signed-in account could see only **Catchall**, which had no project metrics. The existing `950003-tools/950003-sysdigteam` resource was reconciled, but its membership listed external support accounts rather than the current operator. No membership was changed. The authenticated OpenShift monitoring view provided the exports above instead.

For the new project, follow the [platform Sysdig onboarding instructions](https://github.com/bcgov/platform-developer-docs/blob/573c44fda31dcd40253430ca763dbbb14dbc90d4/src/docs/app-monitoring/sysdig-monitor-setup-team.md): sign in, create a single `SysdigTeam` resource in the new `-tools` namespace, and include the confirmed login email with the appropriate role. The current API resource name is **`sysdig-team`**, not `sysdigteam`. Team membership is managed through that resource, not through the Sysdig UI.

The documented starting dashboard is **Template - Resources Quota Approve Dashboard**. Use it for the assigned namespaces once access is configured. This is an operational follow-up, not a prerequisite for using the existing OpenShift evidence.

## Collected measurements

The following tables are generated from the retained exports, with rounding for readability.

### Fresh allocation and usage snapshot

Collected sequentially on 26 October between 21:58 and 22:00 UTC. Usage is a current metrics API sample, not the fourteen-day average.

| Namespace | CPU requests / ceiling (cores) | Memory requests / ceiling (GiB) | PVC allocation / ceiling (GiB) | Sample CPU (cores) | Sample memory (GiB) |
|---|---:|---:|---:|---:|---:|
| `950003-dev` | 1.080 / 4 | 5.10 / 32 | 67.34 / 96 | 0.123 | 7.42 |
| `950003-test` | 1.375 / 4 | 5.47 / 32 | 77.10 / 96 | 0.172 | 6.54 |
| `950003-prod` | 2.975 / 4 | 5.47 / 32 | 93.10 / 96 | 0.161 | 19.02 |
| `a58ce1-dev` | 0.900 / 1 | 2.69 / 16 | 19.00 / 64 | 0.021 | 0.25 |

### Fourteen-day namespace usage

| Namespace | Mean CPU (cores) | Peak 5-minute CPU (cores) | Mean memory (GiB) | Peak sampled memory (GiB) | Memory evaluations |
|---|---:|---:|---:|---:|---:|
| `950003-prod` | 0.141 | 2.361 | 17.62 | 19.47 | 4033 |
| `a58ce1-dev` | 0.023 | 0.044 | 0.27 | 0.34 | 4033 |

### Current replica counts — `950003-prod`

No HPA objects were returned in this namespace. Desired replicas below are current configuration, not a historical count.

| Kind | Workload | Desired replicas | Ready replicas |
|---|---|---:|---:|
| deployments | `cron` | 1 | 1 |
| deployments | `maintenance-message` | 0 | 0 |
| deployments | `moodle-db-backup-storage` | 1 | 1 |
| deployments | `php` | 3 | 3 |
| deployments | `pod-health-monitor` | 1 | 1 |
| deployments | `redis-proxy` | 5 | 5 |
| deployments | `web` | 3 | 3 |
| deployments | `workspaceab1e0e28f2fd44ac` | 0 | 0 |
| statefulsets | `mariadb-galera` | 5 | 5 |
| statefulsets | `redis-node` | 5 | 5 |

### Per-pod usage — `950003-prod`

CPU is in millicores; memory is in MiB. Requests are CPU / memory for regular containers in the current snapshot. “Absent” pods are no longer in that inventory. Sample counts show memory coverage; missing CPU values for short-lived pods are unavailable, not zero.

| Pod | Snapshot phase | Current request (m / MiB) | Mean CPU (m) | Peak 5-min CPU (m) | Mean memory (MiB) | Peak memory (MiB) | Memory samples |
|---|---|---:|---:|---:|---:|---:|---:|
| `cron-58d5686875-7kbkq` | Absent | Unavailable | 10.38 | 779.91 | 2240.8 | 2765.8 | 2611 |
| `cron-7865875fcf-hb2gs` | Running | 50 / 256 | 9.49 | 674.01 | 1073.1 | 2617.7 | 1416 |
| `mariadb-galera-0` | Running | 100 / 256 | 6.22 | 509.75 | 2926.1 | 3307.4 | 4033 |
| `mariadb-galera-1` | Running | 100 / 256 | 6.87 | 540.89 | 2994.2 | 3221.4 | 4033 |
| `mariadb-galera-2` | Running | 100 / 256 | 7.10 | 664.73 | 2937.8 | 3038.4 | 4033 |
| `mariadb-galera-3` | Running | 100 / 256 | 6.09 | 572.16 | 3078.1 | 3171.2 | 4033 |
| `mariadb-galera-4` | Running | 100 / 256 | 6.20 | 572.97 | 2984.7 | 3168.9 | 4033 |
| `moodle-db-backup-storage-85b995b77-9wxj8` | Running | 50 / 256 | 0.13 | 61.73 | 41.1 | 148.8 | 4033 |
| `php-559c77868f-m76d5` | Absent | Unavailable | 2.25 | 843.88 | 244.3 | 530.8 | 2617 |
| `php-559c77868f-n4nb5` | Absent | Unavailable | 1.29 | 509.20 | 158.3 | 247.4 | 2617 |
| `php-559c77868f-tkgl8` | Absent | Unavailable | 1.37 | 494.57 | 146.1 | 237.1 | 2617 |
| `php-79cc5b7bd4-nfqg5` | Running | 100 / 128 | 1.10 | 208.33 | 101.6 | 194.8 | 1416 |
| `php-79cc5b7bd4-p9hjh` | Running | 100 / 128 | 1.00 | 205.90 | 106.6 | 202.7 | 1416 |
| `php-79cc5b7bd4-v5llr` | Running | 100 / 128 | 0.82 | 168.37 | 92.7 | 171.0 | 1416 |
| `pod-health-monitor-655f6455-9fdrv` | Absent | Unavailable | 54.21 | 71.61 | 78.4 | 124.9 | 2611 |
| `pod-health-monitor-655f6455-v8vc2` | Running | 25 / 128 | 47.25 | 57.51 | 18.5 | 71.5 | 1416 |
| `redis-node-0` | Running | 300 / 512 | 8.65 | 119.23 | 41.9 | 103.5 | 4033 |
| `redis-node-1` | Running | 300 / 512 | 8.04 | 30.19 | 35.6 | 95.7 | 4033 |
| `redis-node-2` | Running | 300 / 512 | 8.32 | 30.34 | 24.9 | 81.9 | 4033 |
| `redis-node-3` | Running | 300 / 512 | 8.13 | 31.90 | 43.0 | 96.0 | 4033 |
| `redis-node-4` | Running | 300 / 512 | 8.16 | 31.28 | 44.8 | 107.4 | 4033 |
| `redis-proxy-995dc6465-5b8nj` | Running | 50 / 32 | 0.23 | 59.17 | 31.4 | 44.1 | 4033 |
| `redis-proxy-995dc6465-flqgw` | Running | 50 / 32 | 0.25 | 71.05 | 31.1 | 38.8 | 4033 |
| `redis-proxy-995dc6465-hmpfl` | Running | 50 / 32 | 0.23 | 58.11 | 28.7 | 40.7 | 4033 |
| `redis-proxy-995dc6465-kffzl` | Running | 50 / 32 | 0.23 | 60.67 | 30.4 | 43.9 | 4033 |
| `redis-proxy-995dc6465-sjgqk` | Running | 50 / 32 | 0.24 | 74.13 | 26.9 | 40.6 | 4033 |
| `web-54cd999c75-9bk7b` | Running | 100 / 192 | 0.04 | 19.24 | 137.7 | 167.8 | 4033 |
| `web-54cd999c75-9fctn` | Running | 100 / 192 | 0.03 | 17.74 | 132.0 | 185.4 | 4033 |
| `web-54cd999c75-r5w7m` | Running | 100 / 192 | 0.04 | 18.31 | 126.5 | 143.4 | 4033 |

### Current replica counts — `a58ce1-dev`

No HPA objects were returned in this namespace. Desired replicas below are current configuration, not a historical count.

| Kind | Workload | Desired replicas | Ready replicas |
|---|---|---:|---:|
| deployments | `psa-moodle-cron` | 1 | 1 |
| deployments | `psa-moodle-php` | 1 | 1 |
| deployments | `psa-moodle-web` | 1 | 1 |
| statefulsets | `mysql` | 0 | 0 |
| statefulsets | `psa-moodle-pg-instance1-ntcv` | 1 | 1 |
| statefulsets | `psa-moodle-pg-repo-host` | 1 | 1 |
| statefulsets | `psa-moodle-valkey` | 1 | 1 |

### Per-pod usage — `a58ce1-dev`

CPU is in millicores; memory is in MiB. Requests are CPU / memory for regular containers in the current snapshot. “Absent” pods are no longer in that inventory. Sample counts show memory coverage; missing CPU values for short-lived pods are unavailable, not zero.

| Pod | Snapshot phase | Current request (m / MiB) | Mean CPU (m) | Peak 5-min CPU (m) | Mean memory (MiB) | Peak memory (MiB) | Memory samples |
|---|---|---:|---:|---:|---:|---:|---:|
| `psa-moodle-cron-558cd4b77d-6jvdn` | Running | 100 / 256 | 4.26 | 6.17 | 47.0 | 64.5 | 1398 |
| `psa-moodle-cron-797c8d7f5-x5nwm` | Absent | Unavailable | 4.32 | 6.36 | 53.0 | 87.9 | 2635 |
| `psa-moodle-pg-instance1-ntcv-0` | Running | 400 / 1280 | 10.68 | 24.90 | 114.5 | 139.9 | 4033 |
| `psa-moodle-pg-repo-host-0` | Running | 100 / 512 | 1.81 | 9.57 | 12.8 | 19.3 | 4033 |
| `psa-moodle-pg-repo1-incr-29864940-q8f64` | Absent | Unavailable | 0.08 | 0.08 | 10.7 | 10.7 | 1 |
| `psa-moodle-pg-repo1-incr-29866380-khwr5` | Absent | Unavailable | 0.06 | 0.06 | Unavailable | Unavailable | Unavailable |
| `psa-moodle-pg-repo1-incr-29867820-ldqjf` | Absent | Unavailable | 0.08 | 0.08 | 14.1 | 14.1 | 1 |
| `psa-moodle-pg-repo1-incr-29869260-qbjdt` | Absent | Unavailable | 0.06 | 0.06 | 14.1 | 14.1 | 1 |
| `psa-moodle-pg-repo1-incr-29870400-7jjpv` | Absent | Unavailable | 0.01 | 0.01 | Unavailable | Unavailable | Unavailable |
| `psa-moodle-pg-repo1-incr-29870700-8x46w` | Absent | Unavailable | 0.08 | 0.08 | 12.0 | 12.0 | 1 |
| `psa-moodle-pg-repo1-incr-29872140-mtqmp` | Absent | Unavailable | 0.06 | 0.06 | Unavailable | Unavailable | Unavailable |
| `psa-moodle-pg-repo1-incr-29872440-qjpx5` | Absent | Unavailable | 0.00 | 0.00 | Unavailable | Unavailable | Unavailable |
| `psa-moodle-pg-repo1-incr-29873280-txc2s` | Absent | Unavailable | 0.01 | 0.01 | Unavailable | Unavailable | Unavailable |
| `psa-moodle-pg-repo1-incr-29873580-wqh95` | Absent | Unavailable | 0.06 | 0.06 | 9.6 | 9.6 | 1 |
| `psa-moodle-pg-repo1-incr-29875020-4rrkk` | Absent | Unavailable | 0.02 | 0.02 | Unavailable | Unavailable | Unavailable |
| `psa-moodle-pg-repo1-incr-29876460-pdjb2` | Absent | Unavailable | 0.07 | 0.07 | Unavailable | Unavailable | Unavailable |
| `psa-moodle-pg-repo1-incr-29877600-xdkgg` | Absent | Unavailable | 0.01 | 0.01 | Unavailable | Unavailable | Unavailable |
| `psa-moodle-pg-repo1-incr-29877900-ws7d9` | Absent | Unavailable | 0.08 | 0.08 | Unavailable | Unavailable | Unavailable |
| `psa-moodle-pg-repo1-incr-29879340-zz899` | Absent | Unavailable | 0.05 | 0.05 | Unavailable | Unavailable | Unavailable |
| `psa-moodle-pg-repo1-incr-29880780-fvz7z` | Absent | Unavailable | 0.06 | 0.06 | Unavailable | Unavailable | Unavailable |
| `psa-moodle-pg-repo1-incr-29882220-rnrqq` | Absent | Unavailable | 0.08 | 0.08 | Unavailable | Unavailable | Unavailable |
| `psa-moodle-pg-repo1-incr-29883660-z4f4v` | Absent | Unavailable | 0.05 | 0.05 | Unavailable | Unavailable | Unavailable |
| `psa-moodle-php-cd4748b65-wdds8` | Running | 200 / 512 | 3.79 | 9.05 | 85.7 | 102.4 | 1398 |
| `psa-moodle-php-f7b454cd4-bx7sq` | Absent | Unavailable | 3.80 | 6.58 | 44.0 | 118.9 | 2635 |
| `psa-moodle-valkey-0` | Running | 50 / 128 | 2.47 | 2.64 | 12.9 | 13.9 | 4033 |
| `psa-moodle-web-687b8f847b-flbls` | Absent | Unavailable | 0.03 | 0.03 | 24.0 | 24.6 | 2635 |
| `psa-moodle-web-766d795449-rrptr` | Running | 50 / 64 | 0.02 | 0.06 | 24.8 | 26.4 | 1398 |

### Production PVC history

All capacities and used quantities are GiB. All PVCs returned 4,033 evaluation points. The start and end values are observations, not a growth forecast. Detailed mounting pod references are in `950003-prod.md`; workload names below identify the current consumers.

| PVC | Current consumers | Class | Capacity | Used at start | Used at end | Mean used | Sampled peak used | Peak fullness |
|---|---|---|---:|---:|---:|---:|---:|---:|
| `data-mariadb-galera-0` | mariadb-galera | netapp-file-standard | 10.000 | 3.704 | 3.223 | 3.231 | 3.761 | 37.61% |
| `data-mariadb-galera-1` | mariadb-galera | netapp-file-standard | 10.000 | 3.690 | 3.210 | 3.235 | 3.764 | 37.64% |
| `data-mariadb-galera-2` | mariadb-galera | netapp-file-standard | 10.000 | 3.046 | 3.570 | 3.269 | 3.760 | 37.60% |
| `data-mariadb-galera-3` | mariadb-galera | netapp-file-standard | 10.000 | 3.704 | 3.223 | 3.227 | 3.757 | 37.57% |
| `data-mariadb-galera-4` | mariadb-galera | netapp-file-standard | 10.000 | 3.494 | 3.012 | 3.302 | 3.759 | 37.59% |
| `file-backup-data` | cron, php | netapp-file-backup | 20.000 | 8.060 | 8.061 | 8.282 | 16.887 | 84.44% |
| `moodle-app-data` | cron, php, web | netapp-file-standard | 2.000 | 1.180 | 1.180 | 1.180 | 1.180 | 58.99% |
| `moodle-data` | cron, php, web | netapp-file-standard | 12.000 | 8.587 | 8.356 | 8.606 | 9.184 | 76.53% |
| `moodle-db-backup-storage-backup-pvc` | moodle-db-backup-storage | netapp-file-standard | 7.000 | 1.840 | 2.190 | 2.072 | 2.275 | 32.50% |
| `moodle-db-backup-storage-verification-pvc` | moodle-db-backup-storage | netapp-file-standard | 2.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.00% |
| `moodle-shared` | cron, php | netapp-file-standard | 0.098 | 0.001 | 0.001 | 0.001 | 0.001 | 1.50% |
