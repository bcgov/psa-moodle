# PoC quota request — a58ce1 dev namespace

Paste-ready figures for the **Quotas** section of the
[Platform Product Registry](https://registry.developer.gov.bc.ca/) (`a58ce1`
product, **`dev`** namespace only). This covers the single-replica
proof-of-concept deployed with `values.yaml` + `values-poc.yaml`.

A quota increase is **mandatory before anything will schedule**: the BC Gov
default namespace quota is 0.5 core CPU / 2 GiB RAM / **1 GiB storage**, and
1 GiB of storage cannot hold Postgres + moodledata + a backup repo. This is the
*smallest* bump that runs a working Moodle.

> Decreases auto-approve. CPU/RAM auto-approve above 35% sustained utilisation.
> Storage needs only a PVC list — Sysdig is *not mandatory*
> ([quota-adjustment docs](https://developer.gov.bc.ca/docs/default/component/platform-developer-docs/docs/automation-and-resiliency/request-quota-adjustment-for-openshift-project-set/)).

## What to request (dev namespace)

| Resource | Default | **Request** | Why |
|---|---|---|---|
| CPU request | 0.5 cores | **1 core** | ~0.55 core of long-running pods + Crunchy repo-host, with headroom |
| Memory request | 2 GiB | **3 GiB** | ~1.3 GiB of long-running pods + Crunchy repo-host, with headroom |
| Storage | 1 GiB | **8 GiB** | 7 GiB of PVCs (below) + small margin |
| PVC count | 60 | 60 (no change) | PoC uses 4 PVCs |

Leave `test`, `prod`, `tools` at their defaults for now.

## CPU / RAM justification table

Per-pod **requests** at single-replica (monitoring exporters disabled in PoC):

| Component | Replicas | CPU request | Memory request |
|---|---|---|---|
| web (nginx) | 1 | 50m | 64Mi |
| php (php-fpm) | 1 | 200m | 512Mi |
| valkey (cache) | 1 | 50m | 128Mi |
| postgres (Crunchy instance) | 1 | 250m | 512Mi |
| pgBackRest repo-host (operator-created) | 1 | ~ operator default | ~ operator default |
| **Total (long-running)** | | **~0.55 core +** | **~1.3 GiB +** |

CronJobs (Moodle cron, pgBackRest schedules) draw from the separate
`compute-time-bound-quota`, not the figures above.

## Storage / PVC justification table

| Component | PVC type | Access | Size |
|---|---|---|---|
| moodledata | file-standard (netapp) | RWX | 2Gi |
| postgres instance1 | block-standard | RWO | 2Gi |
| pgBackRest repo1 | block-standard | RWO | 2Gi |
| valkey data | block-standard | RWO | 1Gi |
| **Total** | | | **7Gi** |

## Deploy once the bump lands

```bash
helm upgrade --install psa-moodle ./chart/psa-moodle \
  -f chart/psa-moodle/values.yaml \
  -f chart/psa-moodle/values-poc.yaml \
  -n a58ce1-dev
```

## After the demo

This PoC profile is throwaway. For the real dev/test deployment, request the
prod-shaped quota separately and switch back to `values-dev.yaml` /
`values-test.yaml` (3× replicas, HPA, full monitoring + backup rehearsal,
larger storage). That second request is where the Sysdig utilisation dashboard
from this PoC run becomes the evidence that auto-approves it.
