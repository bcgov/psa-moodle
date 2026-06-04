# Phase 3 — First OpenShift deploy

This is the runbook for deploying psa-moodle into `a58ce1-dev` for the first time. **Phase 0 (namespace handover) must be complete first** — see [`namespace-handover.md`](namespace-handover.md).

The objective: prove the new architecture works end-to-end on cluster (Galera removed, RWX-code removed, custom Redis proxy removed) by getting an empty Moodle 4.5 install reachable via Route.

---

## Prerequisites

- `oc` and `helm` (v3.13+) installed locally
- `podman` and `buildah` (Phase 2 CI isn't built yet, so first-time image push is manual)
- `oc login` to `api.silver.devops.gov.bc.ca` working
- Phase 0 complete: `psa-moodle-deploy` SA exists, `artifactory-pull` Secret attached to `default` SA in `a58ce1-dev`
- `oc get crd | grep postgresclusters` returns the Crunchy CRD (operator is installed cluster-wide on Silver)

---

## Step 1 — Images in Artifactory

Phase 3 consumes the **`<version>` (no-suffix) image tags** that Phase 2 builds and pushes. If you haven't completed Phase 2 yet, do that now — it's the runbook for building both image variants, pushing them, and proving the registry artifacts work via a local smoke test.

See [`phase2-images.md`](phase2-images.md).

The shortcut: `make push VERSION=v0.1.0-dev1` (after `podman login` to Artifactory). That builds and pushes both `<version>-local` and `<version>` variants of all three images. The OpenShift Helm chart in the next step references the no-suffix tag.

---

## Step 2 — `helm template` preview

Before installing, render and review:

```sh
helm template psa-moodle ./chart/psa-moodle \
  -n a58ce1-dev \
  -f ./chart/psa-moodle/values-dev.yaml \
  --set image.tag=v0.1.0-dev1 \
  > /tmp/psa-moodle-dev-rendered.yaml

# Sanity check that the expected resources are there.
grep -E '^(kind|  name):' /tmp/psa-moodle-dev-rendered.yaml
```

Expected resource list:

- `PostgresCluster` (Crunchy)
- `ConfigMap` valkey
- `Service` valkey + headless StatefulSet selector
- `StatefulSet` valkey
- `PersistentVolumeClaim` moodledata
- `Secret` `<release>-admin`
- `Deployment` php + Service
- `Deployment` web + Service
- `Route`
- `CronJob` cron
- `Job` install (post-install hook)
- `NetworkPolicy` × 5 (deny-by-default, router→web, web→php, app→valkey, app→postgres)

If anything's missing or wrong, fix it before `helm install`.

---

## Step 3 — Install

```sh
oc project a58ce1-dev

helm install psa-moodle ./chart/psa-moodle \
  -n a58ce1-dev \
  -f ./chart/psa-moodle/values-dev.yaml \
  --set image.tag=v0.1.0-dev1 \
  --wait \
  --timeout 15m
```

The `--wait` flag pauses until all resources report Ready. The install Job runs as a post-install hook; it has an initContainer that waits up to 5 min for Crunchy Postgres to come up.

---

## Step 4 — Verify

```sh
# All release pods
oc -n a58ce1-dev get pods -l app.kubernetes.io/instance=psa-moodle

# Crunchy Postgres
oc -n a58ce1-dev get postgrescluster psa-moodle-pg
oc -n a58ce1-dev get pods -l postgres-operator.crunchydata.com/cluster=psa-moodle-pg

# Install Job result
oc -n a58ce1-dev logs job/psa-moodle-install

# Route
oc -n a58ce1-dev get route psa-moodle

# Admin password (retrieve once, store safely)
oc -n a58ce1-dev get secret psa-moodle-admin \
  -o jsonpath='{.data.MOODLE_ADMIN_PASS}' | base64 -d ; echo

# Browse
echo "https://$(oc -n a58ce1-dev get route psa-moodle -o jsonpath='{.spec.host}')"
```

Log in as `admin` with the retrieved password. You should land on a fresh, empty Moodle 4.5 site with the `bcgovpsa` theme available.

---

## Step 5 — Smoke test the architectural payoff

This is the "did we actually fix the things the 2026-04-12 assessment flagged?" check.

```sh
# 1. No Galera — confirm a single Postgres primary and replicas.
oc -n a58ce1-dev get pods -l postgres-operator.crunchydata.com/role=master
oc -n a58ce1-dev get pods -l postgres-operator.crunchydata.com/role=replica

# 2. No shared RWX code — only moodledata is RWX, everything else is image.
oc -n a58ce1-dev get pvc
oc -n a58ce1-dev get pvc psa-moodle-moodledata -o jsonpath='{.spec.accessModes}{"\n"}'
# Expected: [ReadWriteMany]
oc -n a58ce1-dev get pvc -l app.kubernetes.io/instance=psa-moodle \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.accessModes}{"\n"}{end}'
# Expected: only moodledata is RWX; postgres / valkey are RWO.

# 3. No Redis proxy / sentinel_tunnel — a single Valkey pod.
oc -n a58ce1-dev get pods -l app.kubernetes.io/component=valkey

# 4. Route timeout is raised.
oc -n a58ce1-dev get route psa-moodle \
  -o jsonpath='{.metadata.annotations.haproxy\.router\.openshift\.io/timeout}{"\n"}'
# Expected: 900s

# 5. Old moodle-nginx pods (if any) are untouched.
oc -n a58ce1-dev get pods -l app=moodle 2>/dev/null
```

---

## Common first-deploy issues

| Symptom | Likely cause | Fix |
|---|---|---|
| `ErrImagePull` on web/php/cron | Image not pushed or pull secret missing | Re-do Step 1; check `oc -n a58ce1-dev get sa default -o yaml | grep imagePullSecrets` |
| Install Job stuck in `wait-for-db` | Crunchy operator not present, or PVC binding stuck | `oc get crd postgresclusters...`; `oc get pvc -n a58ce1-dev` |
| `valkey` pod CrashLoopBackOff with permission errors on `/data` | SCC didn't propagate fsGroup; PVC class doesn't support fsGroup chown | Switch to a `fsGroupChangePolicy: OnRootMismatch` capable class, or add an initContainer that chowns `/data` |
| `helm install` reports "Crunchy CRD not found" | Operator missing | File a `#devops-operations` Rocket.Chat ticket |
| Route 503 after pods are Ready | Service selector mismatch | `oc -n a58ce1-dev get endpoints psa-moodle-web` should show pod IPs |
| install Job fails with "site is already installed" | DB already populated from a previous run | `helm uninstall` (Postgres + admin Secret survive — see Step 6), `oc delete postgrescluster psa-moodle-pg`, then reinstall |

---

## Step 6 — Cleanup / re-run

To uninstall and start over from a clean slate:

```sh
helm uninstall psa-moodle -n a58ce1-dev

# helm.sh/resource-policy: keep means the following survive uninstall:
#   - PostgresCluster (data preserved)
#   - <release>-admin Secret (admin pw preserved)
#   - PersistentVolumeClaims (moodledata preserved)
# Delete them explicitly to truly reset:
oc -n a58ce1-dev delete postgrescluster psa-moodle-pg
oc -n a58ce1-dev delete pvc -l app.kubernetes.io/instance=psa-moodle
oc -n a58ce1-dev delete secret psa-moodle-admin
```

---

## Phase 3 acceptance criteria

- [ ] Images pushed to Artifactory under `a58ce1-tools/psa-moodle/{web,php,cron}`
- [ ] `helm install` completes within 15 min
- [ ] All pods Ready, install Job Completed
- [ ] Route resolves and Moodle login page renders with `bcgovpsa` theme
- [ ] Admin login works
- [ ] No Galera, no Redis proxy, no shared RWX code volume (Step 5 verifications all pass)
- [ ] Old `moodle-nginx` workloads (if any) still running unaffected

When the boxes are ticked, Phase 3 is done and Phase 4 (operational hardening — PDB, HPA, topology spread, refined NetworkPolicies) is unblocked.
