# Quota request — a58ce1 dev + test (full profile)

Paste-ready figures for the **Quotas** section of the
[Platform Product Registry](https://registry.developer.gov.bc.ca/) (`a58ce1`
product). This supersedes `poc-quota-request.md` (which covered only the
single-replica PoC and was overtaken by the reused plate's existing
1 core / 16 GiB / 64 GiB on `dev`).

This request moves psa-moodle from the PoC to the **production-shaped dev/test
pipeline**: monitoring re-enabled on dev, and a new `test` namespace running the
HA topology (3× replicas + HPA, 3-instance Postgres, restore rehearsal) so
multi-pod failure modes are exercised before any prod conversation.

> **Auto-approval (per [request-quota-adjustment docs](https://developer.gov.bc.ca/docs/default/component/platform-developer-docs/docs/automation-and-resiliency/request-quota-adjustment-for-openshift-project-set/)):**
> decreases auto-approve; CPU/RAM increases auto-approve above 35 % sustained
> utilisation; storage needs only the PVC list below (Sysdig not mandatory).

---

## Summary — what to request

| Namespace | CPU request | Memory request | Storage (file-standard) | VolumeSnapshots | Action |
|---|---|---|---|---|---|
| **`dev`** | 1 → **2 cores** | 16 GiB (no change) | 64 GiB (no change) | 5 → **10** | small CPU bump for monitoring + rollout headroom |
| **`test`** | 0.5 → **4 cores** | 2 → **8 GiB** | 1 → **100 GiB** | 5 → **20** | full HA-topology provision (currently default) |
| **`test` time-bound** | 1 → **2 cores** | 16 GiB (ok) | — | — | restore-rehearsal temp cluster |
| **`tools`** | no change | no change | no change | no change | no psa-moodle workload yet (Artifactory deferred) |

Numbers below are **requests** (the quota dimension that binds first), derived
from `values-dev.yaml` / `values-test.yaml` + base `values.yaml`, cross-checked
against live per-pod requests in `a58ce1-dev`.

---

## `dev` — why 2 cores

Dev stays single-replica but turns **monitoring back on** (exporters off in the
PoC). Long-running steady-state:

| Component | Replicas | CPU | Memory |
|---|---|---|---|
| web (nginx) | 1 | 50m | 64Mi |
| php (php-fpm) + exporter | 1 | 200m + 1m | 512Mi + 32Mi |
| valkey | 1 | 50m | 128Mi |
| postgres instance (db 250m + 3 operator sidecars ~150m) + exporter | 1 | ~400m + 1m | ~700Mi + 64Mi |
| pgBackRest repo-host | 1 | 100m | ~256Mi |
| cron (loop Deployment) | 1 | 100m | 256Mi |
| **Total** | | **~0.9 core** | **~2.0 GiB** |

At ~0.9 core the current 1-core cap sits at ~90 % — too tight to complete a
rolling update (the php Deployment surges a full extra pod, +201m) or absorb the
Postgres exporter rollout. **2 cores** gives rollout headroom and lands util at a
healthy ~45 %. **RAM and storage need no change** — dev uses ~2 GiB of the 16 GiB
cap and ~22 GiB of the 64 GiB cap. (Snapshot count → 10: the daily moodledata
snapshot at 7-day retention can hold up to ~7–8 snapshots, over the default 5.)

---

## `test` — full HA topology (new provision)

`test` is currently at the BC Gov default (0.5 core / 2 GiB / 1 GiB) and must be
provisioned for the production-shaped profile: web/php at 3 replicas with HPA
(max 5 / 6), 3-instance Postgres, monitoring, and the restore-rehearsal job.

### CPU / RAM — sized to HPA **max** (quota must cover peak)

| Component | Replicas (max) | CPU | Memory |
|---|---|---|---|
| web | 5 | 250m | 320Mi |
| php + exporter | 6 | 1200m + 6m | 3072Mi + 192Mi |
| valkey | 1 | 50m | 128Mi |
| postgres instances (~400m ea) + exporters | 3 | 1200m + 3m | ~2100Mi + 192Mi |
| pgBackRest repo-host | 1 | 100m | ~256Mi |
| cron (loop Deployment) | 1 | 100m | 256Mi |
| **Total at HPA max** | | **~2.9 cores** | **~6.5 GiB** |

Add the php rolling-update surge (+201m) → ~3.1 core peak. **Request 4 cores /
8 GiB** for headroom (lands ~73 % util at HPA max, auto-approvable).

### Time-bound compute (separate `compute-time-bound-quota`)

The weekly **restore-rehearsal** CronJob provisions a temporary Postgres cluster
from the backup repo — a transient ~0.5–1 core + ~1 GiB on top of the daily
integrity check and moodledata snapshot jobs. **Request test time-bound CPU
→ 2 cores** (RAM default 16 GiB is fine).

### Storage (netapp-file-standard)

| PVC | Size | Notes |
|---|---|---|
| moodledata (RWX) | 20Gi | `values-test.yaml` |
| postgres instance ×3 | 30Gi | 10Gi × 3 (base default) |
| pgBackRest repo | 20Gi | base default |
| valkey | 2Gi | base default |
| restore-rehearsal temp cluster | ~20Gi | transient instance + repo during the weekly job |
| **Total** | **~92Gi** | |

**Request 100 GiB** storage. **Snapshots → 20**: the daily moodledata snapshot at
14-day retention holds up to ~14, over the default 5.

> Confirm the storage class name before applying — the live `dev` PVCs all land on
> `netapp-file-standard`; if any `test` PVC is pinned to `netapp-block-standard`,
> split the request across both class quotas accordingly.

---

## `tools` — no change

No psa-moodle workload runs in `a58ce1-tools` today: images build in GitHub
Actions and the PoC pulls from the in-cluster registry, and the Artifactory
`a58ce1-tools` repo request is deferred. Leave `tools` at default until a tools
workload is defined. (Note: the defunct project left imagestreams in `tools`;
clean those separately if reclaiming registry storage.)

---

## Deploy once the quota lands

```bash
# dev (monitoring now on)
helm upgrade --install psa-moodle ./chart/psa-moodle \
  -f chart/psa-moodle/values.yaml -f chart/psa-moodle/values-dev.yaml \
  -n a58ce1-dev

# test (new namespace, HA topology)
helm upgrade --install psa-moodle ./chart/psa-moodle \
  -f chart/psa-moodle/values.yaml -f chart/psa-moodle/values-test.yaml \
  -n a58ce1-test
```

> Standardize on `helm upgrade --install` (see `next-steps.md` P1) — and make the
> `job-install` post-install hook idempotent first, so a re-run on an existing DB
> doesn't fail the release.
