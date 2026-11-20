# PoC deploy runbook — psa-moodle on `a58ce1-dev`

Stand up the single-replica proof-of-concept in `a58ce1-dev` and reach it at
**https://psa-moodle-dev.apps.silver.devops.gov.bc.ca**.

This runbook reflects what actually works on BC Gov Silver (verified 2026-06-03).
Every fix below is already in the chart/config, so a clean `helm install` now
runs end-to-end with **no manual SQL, config edits, or NetworkPolicy patches**.

## Key decisions (and why)

- **Images go to OpenShift's internal registry, not Artifactory.** The reused
  `a58ce1` plate has no Docker repo on `artifacts.developer.gov.bc.ca` (the
  defunct project used a legacy registry). We build locally and push to the
  cluster's built-in registry. No Artifactory repo, no pull secret.
  *(Request the `a58ce1-tools` Artifactory repo from Platform Services if/when
  you want the CI pipeline — but it's not needed for this.)*
- **Quota:** none required. The plate already carries 1 core / 16Gi / 64Gi
  (see `poc-quota-request.md`); the PoC fits, CPU is the tightest.
- **Profile:** `values-poc.yaml` — single replicas, internal-registry images,
  monitoring + add-on backups off (demo only). Cron now runs as a 60s loop
  Deployment and the **egress NetworkPolicy is ON** — both fixed since the
  original PoC (see `next-steps.md` → "Done").

## Fixes baked into the chart (context for reviewers)

| Problem on Silver | Fix |
|---|---|
| arm64 images crash (`exec format error`) | Makefile builds `linux/amd64` |
| Kyverno blocks fast cron-with-PVC | cron is a 60s loop Deployment (not a CronJob) |
| tenants can't create ClusterRoleBinding | gated off (`backup.moodledataSnapshot.clusterRoleBinding`) |
| nginx `fastcgi_pass php:9000` won't resolve | chart adds a Service named `php` |
| egress NetworkPolicy kills DNS on OVN | DNS egress allows port 5353 (OVN DNAT); egress ON |
| `install_database.php` can't make localcache dir | `/mnt/ramdisk` emptyDir on install + cron pods |
| PG15 denies CREATE on schema `public` | `databaseInitSQL` grants the moodle role ownership |
| Moodle "reverse proxy ... accessed directly" (HTTP 500) | `reverseproxy=false` in config.openshift.php |

## Changes made outside Helm (read this before touching the live PoC)

- **The Helm release records for `psa-moodle` in `a58ce1-dev` no longer exist** (found 2026-11-20). The objects still
  carry Helm labels and annotations (`meta.helm.sh/release-name: psa-moodle`), but `helm list -n a58ce1-dev` is empty and
  there are no `owner=helm` secrets. So `helm upgrade` fails, and `helm install` would try to adopt the objects and run the
  database-install Job. Don't do either against this namespace; change the live objects directly, or tear down and
  reinstall cleanly.
- **2026-11-20, nginx 1.30.7 (web only).** It fixes the November 2026 nginx advisories (CVE-2026-123007 and others).
  The web image is built from `Containerfile.web` (now `docker.io/nginx/nginx-unprivileged:1.30.7-alpine-slim`) with the
  running php image `php-8.3.36-poc5-20261021` as its code source, so the Moodle code tree is identical to before
  (29,598 files, same hash). It was pushed to the internal registry as `a58ce1-dev/web:nginx-1.30.7-20261120`, then applied
  with:

  ```sh
  oc -n a58ce1-dev set image deploy/psa-moodle-web web=image-registry.openshift-image-registry.svc:5000/a58ce1-dev/web:nginx-1.30.7-20261120
  ```

  This gave Deployment revision 5. The public `/health` now returns `Server: nginx/1.30.7`. Undo:
  `oc -n a58ce1-dev rollout undo deploy/psa-moodle-web` (revision 4, `web:php-8.3.36-poc5-20261021`, nginx 1.27.5).
  php and cron still run `php-8.3.36-poc5-20261021`.
- **The CI pipeline does not deploy here.** `deploy.yml` skips because the `OPENSHIFT_*` secrets are not set, and
  `build.yml` only verifies builds because `ARTIFACTORY_PASSWORD` is not set. Every change to this PoC has been manual.

---

## A. Pre-flight (read-only)

```bash
oc whoami && oc project a58ce1-dev
# Crunchy operator available to this namespace (NOT `oc get crd` — that 403s a tenant):
oc auth can-i create postgresclusters.postgres-operator.crunchydata.com -n a58ce1-dev   # expect: yes
```

## B. Build + push images to the internal registry

The Makefile defaults to `linux/amd64`. Bump `VERSION` on every rebuild so nodes
pull fresh (avoids the mutable-tag stale-image trap).

```bash
# 1. Build the openshift-variant images (amd64; slow under QEMU on Apple Silicon)
make build MOODLE_CONFIG_VARIANT=openshift TAG=v0.1.0-poc3

# 2. Sanity-check the arch before pushing
podman inspect localhost/psa-moodle-php:v0.1.0-poc3 --format '{{.Architecture}}'   # must print: amd64

# 3. Log into the cluster's internal registry (uses your oc token)
podman login -u "$(oc whoami)" -p "$(oc whoami -t)" image-registry.apps.silver.devops.gov.bc.ca

# 4. Tag + push all four images
REG=image-registry.apps.silver.devops.gov.bc.ca
for c in php web cron ops; do
  podman tag localhost/psa-moodle-$c:v0.1.0-poc3 $REG/a58ce1-dev/$c:v0.1.0-poc3
  podman push $REG/a58ce1-dev/$c:v0.1.0-poc3
done

# 5. Confirm imagestreams exist with the new tag
oc get imagestream -n a58ce1-dev   # expect: php, web, cron, ops @ v0.1.0-poc3
```

> `values-poc.yaml` pins `image.tag: v0.1.0-poc3`. If you push a different
> VERSION, either update that line or add `--set image.tag=<VERSION>` in step C.

## C. Install

```bash
# dry run (validates RBAC/quota/schema — note: does NOT exercise Kyverno)
helm install psa-moodle ./chart/psa-moodle \
  -f chart/psa-moodle/values.yaml \
  -f chart/psa-moodle/values-poc.yaml \
  -n a58ce1-dev --dry-run=server

# real install (blocks on the DB-install hook; first run takes a few minutes)
helm install psa-moodle ./chart/psa-moodle \
  -f chart/psa-moodle/values.yaml \
  -f chart/psa-moodle/values-poc.yaml \
  -n a58ce1-dev --timeout 15m
```

Watch (second terminal):
```bash
oc get postgrescluster,pods -n a58ce1-dev -w | grep -iE 'psa-moodle|NAME'
```
Expected: Postgres `Running` → php/valkey/web `Running` → `psa-moodle-install-*`
`Completed` → `helm install` returns success.

## D. Verify + access

```bash
# the route should serve HTTP 200 with NO manual fixes this time
curl -sS -o /dev/null -w "HTTP %{http_code}\n" -L https://psa-moodle-dev.apps.silver.devops.gov.bc.ca/login/index.php

# admin password
oc get secret psa-moodle-admin -n a58ce1-dev -o jsonpath='{.data.MOODLE_ADMIN_PASS}' | base64 -d; echo
```
Browse **https://psa-moodle-dev.apps.silver.devops.gov.bc.ca** → log in as `admin`.

Troubleshooting:
```bash
oc get events -n a58ce1-dev --sort-by=.lastTimestamp | tail -20
oc logs job/psa-moodle-install -c install -n a58ce1-dev     # DB-install errors
oc logs deploy/psa-moodle-php -n a58ce1-dev --tail=20       # app errors
```

---

## E. Teardown

The DB-install hook only runs on `helm install`, never `helm upgrade`, and the
PostgresCluster + its PVCs don't always cascade on uninstall — so tear down
explicitly:

```bash
helm uninstall psa-moodle -n a58ce1-dev
oc delete postgrescluster psa-moodle-pg -n a58ce1-dev --ignore-not-found
oc delete job psa-moodle-install -n a58ce1-dev --ignore-not-found
oc delete pod -n a58ce1-dev -l app.kubernetes.io/instance=psa-moodle --ignore-not-found
oc delete pvc -n a58ce1-dev -l postgres-operator.crunchydata.com/cluster=psa-moodle-pg --ignore-not-found
oc delete pvc psa-moodle-moodledata data-psa-moodle-valkey-0 -n a58ce1-dev --ignore-not-found
```
Wait until clean (re-run until it prints `CLEAN`):
```bash
oc get postgrescluster,pods,pvc -n a58ce1-dev | grep -i psa-moodle || echo CLEAN
```
The kept `psa-moodle-admin` Secret survives (resource-policy keep) so the admin
password is stable across reinstalls. Leave the `learningcurator`/`mysql` PVCs
alone. Imagestreams persist too — only re-push if the image changed.

---

## Appendix — known follow-ups (not needed for the PoC demo)

- ~~**Egress NetworkPolicy** is OFF~~ — **DONE.** Root-caused (Silver's OVN
  evaluates egress ACLs after the DNS service DNAT 53→5353) and re-enabled; on in
  the PoC profile and by default.
- ~~**Cron runs hourly**~~ — **DONE.** Converted to a long-running Deployment that
  loops `cron.php` every 60s (Deployments aren't subject to the Kyverno PVC-cron
  policy), restoring Moodle's normal cadence.
- **Artifactory `a58ce1-tools` repo** must be provisioned before the CI pipeline
  (build.yml/deploy.yml) can push/pull — request from Platform Services.
- **Monitoring + add-on backups** are off in the PoC; re-enable for dev/test.
