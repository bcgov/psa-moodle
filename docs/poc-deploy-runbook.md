# PoC deploy runbook — psa-moodle into `a58ce1-dev`

Step-by-step to stand up the single-replica proof-of-concept in the `a58ce1-dev`
namespace, for a demo ahead of the full dev/test rollout.

- **Profile:** `values-poc.yaml` (single replicas, ~7Gi storage, monitoring +
  add-on backups off). Not the dev/test/prod profile.
- **Quota:** none required. The `a58ce1` plate is reused from the defunct
  `learningcurator` project and already carries a raised quota (verified
  2026-06-03: 1 core CPU request / 16Gi RAM / 64Gi storage / 60 PVCs). The PoC
  fits; **CPU (1 core long-running cap) is the tightest resource**. The full
  test/prod-shaped profile still needs an increase — see `poc-quota-request.md`.
- **Leftover cleanup is optional**, not a blocker — see the appendix.

All `oc`/`helm` commands assume you're logged in. Nothing here is destructive
except the optional appendix.

---

## A. Pre-flight checks (read-only)

```bash
# 1. Right cluster + namespace
oc whoami && oc project a58ce1-dev

# 2. Crunchy Postgres operator is available to this namespace.
#    NOTE: do NOT use `oc get crd ...` — CRDs are cluster-scoped and a namespace
#    tenant always gets 403 on them. The namespace-safe check is can-i:
oc auth can-i create postgresclusters.postgres-operator.crunchydata.com -n a58ce1-dev
#    expect: yes   (the operator runs cluster-wide on Silver; you just need create rights)

# 3. Image pull secret exists in this namespace
oc get secret artifactory-pull -n a58ce1-dev
```

**Gate:**
- A.2 `yes` → good. Anything else → email PlatformServicesTeam@gov.bc.ca; the DB
  can't provision without the operator.
- A.3 `found` → skip B1. `NotFound` → do B1.

---

## B. One-time prerequisites (only what A flagged)

### B1 — Artifactory pull secret (if A.3 was NotFound)
Follow `namespace-handover.md` Steps 2–3. You need the `psa-moodle-ci` robot
account token from [BC Gov Artifactory](https://artifacts.developer.gov.bc.ca)
(`a58ce1` project → Robot Accounts; `a58ce1-dev` needs **Pull**).

```bash
oc -n a58ce1-dev create secret docker-registry artifactory-pull \
  --docker-server=artifacts.developer.gov.bc.ca \
  --docker-username='a58ce1+psa-moodle-ci' \
  --docker-password='<PASTE-ARTIFACTORY-TOKEN>' \
  --docker-email='unused@example.com'

# Helm releases use the default SA; attach the secret to it (chart pods also
# reference it explicitly, so this is belt-and-suspenders per the handover doc).
oc -n a58ce1-dev patch serviceaccount default \
  -p '{"imagePullSecrets":[{"name":"artifactory-pull"}]}'
```

### B2 — Build & push the OpenShift images (if not already in the registry)
Uses Podman/buildah per the Makefile. Pushes the `openshift` variant of
php/web/cron/ops under the chosen `VERSION` tag.

```bash
podman login artifacts.developer.gov.bc.ca
make push VERSION=v0.1.0-poc1
```
> The chart defaults to `image.tag: dev`. You pushed `v0.1.0-poc1`, so step C
> overrides the tag with `--set image.tag=v0.1.0-poc1`.

---

## C. Deploy

### C1 — Server-side dry run (creates nothing; catches RBAC/quota/schema rejects)
```bash
helm upgrade --install psa-moodle ./chart/psa-moodle \
  -f chart/psa-moodle/values.yaml \
  -f chart/psa-moodle/values-poc.yaml \
  --set image.tag=v0.1.0-poc1 \
  -n a58ce1-dev \
  --dry-run=server
```
Clean output → proceed.

### C2 — Install
The post-install hook Job runs Moodle's CLI installer and waits for the Crunchy
primary to accept connections, so first deploy takes several minutes — use a
long timeout.
```bash
helm upgrade --install psa-moodle ./chart/psa-moodle \
  -f chart/psa-moodle/values.yaml \
  -f chart/psa-moodle/values-poc.yaml \
  --set image.tag=v0.1.0-poc1 \
  -n a58ce1-dev \
  --timeout 15m
```
> If it times out, **don't re-run blindly** — resources are created and the
> install Job is likely still finishing. Use section D, then `helm status
> psa-moodle -n a58ce1-dev`.

---

## D. Watch the rollout

```bash
oc get postgrescluster,pods -n a58ce1-dev -w
```
Expected order: a `psa-moodle-pg-*` instance pod + pgBackRest repo pod go
`Running` → `psa-moodle-web-*` / `psa-moodle-php-*` go `Running` → a one-shot
`psa-moodle-install-*` Job pod runs and reaches `Completed`.

Troubleshooting:
```bash
oc get events -n a58ce1-dev --sort-by=.lastTimestamp | tail -20
oc logs job/psa-moodle-install -n a58ce1-dev      # install failures
oc describe pod <stuck-pod> -n a58ce1-dev         # ImagePullBackOff → recheck B1/B2
#                                                  # Pending + quota event → CPU 1-core cap
```

---

## E. Access (the demo)

```bash
# Auto-generated admin password
oc get secret psa-moodle-admin -n a58ce1-dev \
  -o jsonpath='{.data.MOODLE_ADMIN_PASS}' | base64 -d; echo

# Route host
oc get route psa-moodle -n a58ce1-dev -o jsonpath='{.spec.host}'; echo
```
Browse **https://psa-moodle-dev.apps.silver.devops.gov.bc.ca** and log in as
`admin` with that password.

---

## Appendix — optional cleanup of the defunct `learningcurator` remnants

Not required for the PoC (plenty of headroom). Frees ~50m CPU and 27Gi storage.
**Confirm with the PO that this 4-year-old data is disposable before deleting.**

```bash
oc delete pod learningcurator-sunset-10-b2bx8 -n a58ce1-dev
oc delete statefulset/mysql -n a58ce1-dev
oc delete pvc data-mysql-0 data-mysql-1 data-mysql-2 \
              learningcurator-data learningcurator-mysql-dev -n a58ce1-dev
```
