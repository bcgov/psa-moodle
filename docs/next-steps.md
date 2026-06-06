# Next steps — psa-moodle after the PoC

The PoC proved the architecture works on BC Gov Silver: Moodle 4.5 on Crunchy
Postgres is **deployed and live** in `a58ce1-dev` at
<https://psa-moodle-dev.apps.silver.devops.gov.bc.ca/>. Since then the chart has been
**hardened past the demo shortcuts** (see "Done" below). The job now is to finish
unblocking CI/CD, stand up `-test`, and line up the prod cutover (a separate, later
approval).

A full alignment review against the BC Gov Private Cloud docs is in
[`bcgov-alignment-review.md`](./bcgov-alignment-review.md) — it found **0 critical/high**
issues; the work below is the medium/lead-time tail.

## Done (since the first PoC)

- ✅ **Egress NetworkPolicy re-enabled** — root-caused (Silver OVN evaluates egress
  ACLs after the DNS service DNAT 53→5353) and fixed; on by default and in the PoC profile.
- ✅ **Cron cadence fixed** — hourly Kyverno-throttled CronJob → long-running loop
  Deployment ticking `cron.php` every 60s (`cron.mode: deployment`).
- ✅ **Monitoring + add-on backups** — on by default in `values.yaml`/dev/test
  (exporters, PodMonitor/ServiceMonitor, PrometheusRule, AlertmanagerConfig); off only in
  the throwaway `values-poc.yaml`.
- ✅ **Storage class pinned to block** — Postgres datafiles and the pgBackRest repo now
  request `netapp-block-standard` (block quota confirmed free) instead of silently landing
  on the NFS default. *Applies on a fresh deploy — these are operator-managed CRs and
  `storageClassName` is immutable on an existing PVC, so the live dev DB needs a
  backup+restore (or fresh redeploy) to migrate off NFS. Valkey deliberately stays on file
  (it's a cache, and its StatefulSet volumeClaimTemplate is immutable — pinning it would
  break `helm upgrade`).*
- ✅ **moodledata snapshot disabled** — it could never run (RWX/NFS volume, snapshots are
  block-only, wrong class name) and was emailing a daily "SKIPPED" warning. Real off-site
  moodledata backup is in the prod-cutover backlog.
- ✅ **nginx real client IP** — access logs now record the learner's IP from
  `X-Forwarded-For`, not the router pod IP (audit/logging guidance).
- ✅ **Valkey authentication** — the session/cache store now requires a password.

## Priority 1 — Unblock CI/CD

Today images are built locally (native `linux/amd64` in CI, or under QEMU on Apple
Silicon) and pushed to the cluster's internal registry by hand. That's the single biggest
fragility: a one-person, one-machine dependency.

- **Request the `a58ce1-tools` Artifactory repo** from Platform Services. This is a
  lead-time item, so file it first — it gates `build.yml` / `deploy.yml`. It is **not** a
  help-desk ticket: create an `ArtifactoryProject` object via `oc` (see the BC Gov
  *Set up an Artifactory project and repository* doc); Archeobot routes it to Platform
  Services for approval (`oc describe artproj`). A namespace admin must log into the
  Artifactory web console once first, or the project is created with no admins. Confirm the
  current support channel (MS Teams `OpenShift-howto-artifactory`; Rocket.Chat is gone).
- Once provisioned, add the `ARTIFACTORY_USERNAME` / `ARTIFACTORY_PASSWORD` GitHub Actions
  secrets — `build.yml` already builds `linux/amd64` natively and self-enables push.
- Add the OpenShift deploy secrets so `deploy.yml` can run: `OPENSHIFT_SERVER`,
  `OPENSHIFT_TOKEN_DEV` / `OPENSHIFT_TOKEN_TEST`, `OPENSHIFT_NAMESPACE_DEV` /
  `OPENSHIFT_NAMESPACE_TEST`. Until set, the deploy job skips itself (it no longer fails).
- Point the weekly `scheduled-rebuild.yml` at the real registry.
- **Add CI security scanning now** (does *not* need Artifactory): a Trivy image-CVE step in
  `build.yml` (fail on HIGH/CRITICAL) and CodeQL/SonarCloud SAST in `lint.yml`. JFrog Xray
  scanning comes for free once images live in Artifactory.
- The deploy method is already standardized on `helm upgrade --install`. Keep the
  post-install `psa-moodle-install` hook install-only (it already gates to `helm install`)
  so an upgrade can't re-trigger a failing install.
- **Outcome:** a `git push` deploys; no laptop in the loop.

## Priority 2 — Stand up `a58ce1-test`

Only `-dev` exists today; the handover doc scopes dev/test/tools.

- Request the `-test` quota (see `quota-request.md`) and apply the chart with
  `values-test.yaml`.
- This doubles as the **clean-install regression check** — proving the "no manual SQL /
  config / NetworkPolicy steps" claim holds on a fresh namespace.
- `-test` is the right place to land the **block storage class** on fresh PVCs (no live
  data to migrate) and to validate the off-site backup path before prod.

## Priority 3 — Housekeeping in `a58ce1-dev`

- **Reclaim the orphaned legacy DB.** A scaled-to-0 `mysql` StatefulSet + `mysql-read`
  Service + 3× `data-mysql-*` PVCs (**12 GiB of the 19 GiB used**) are the Galera leftover
  from the reused plate. Confirm nothing needs the data, then delete — frees most of the
  dev storage and CPU pressure (`compute-long-running` sits at ~90%).
- **Migrate the live dev PVCs to block** (optional for dev) — a fresh redeploy picks up the
  new `netapp-block-standard` pins; the existing NFS PVCs won't migrate in place.
- **Record the deliberate divergences** (RHEL/UBI, Sysdig, Argo CD, Vault, Artifactory) as
  decisions in the docs so they don't read as oversights — see the alignment review.

## Priority 4 — Prove backup & restore (not just configure it)

The chart has pgBackRest and a weekly restore-rehearsal, but a backup you haven't restored
isn't a backup. Given the Galera split-brain that motivated this re-platform, **do a real
restore drill in `-test`**: take a backup, destroy the cluster, restore, verify Moodle
returns with data intact. Document the runbook — including **repointing Moodle's DB
connection** to the restored cluster (the operator regenerates the `pguser` password on
restore, so capture/rotate that too).

## Priority 5 — Application completeness

- **SSO** via Moodle core `admin/tool/oauth2/issuers.php` (not `auth_oidc`). The credential
  source — **the CSS/Pathfinder SSO integration request** at
  <https://bcgov.github.io/sso-requests> — is a lead-time item and "not yet requested";
  file it. Give each of dev/test/prod its own CSS client with a redirect URI matching that
  env's Route.
- **Validate the GitHub-cloned plugins/theme** (`itr8tech/pathcurator-moodle`, the
  `bcgovpsa` theme) function in the deployed instance, not just that they build.

## Then — Production cutover (separate track, later approval)

Out of scope until approved. Prerequisites — several have long lead times, so **start the
slow ones now** even though the cutover itself is deferred:

- **STRA** (Security Threat & Risk Assessment) with the Ministry Information Security
  Officer — *the longest-lead item*. Begin early.
- **Dedicated TLS certificate** via ADMS/MyServiceCentre — *only if* a custom/vanity
  hostname is chosen; staying on `*.apps.silver.devops.gov.bc.ca` needs none. Decide the
  prod hostname first.
- **Off-site backup** — `netapp-file-backup` quota (32 GiB) is already present, so this is
  unblocked: add a second pgBackRest repo on `netapp-file-backup` (or S3), and a moodledata
  rsync/tar → `netapp-file-backup` CronJob. Currently there is **no** off-cluster copy.
- **Valkey HA** — the single-replica session store is a SPOF with no PDB; adopt a Sentinel
  / operator HA topology (≥3 replicas, anti-affinity, PDB) and validate session survival.
- **HA profile validated in test** (multi-replica web/php/DB; the platform HA guidelines).
- **Monitoring maturity** — golden-signal SLIs (request latency/error-rate), an SLO, a team
  distribution list for alerts (not one personal mailbox), and an external black-box uptime
  check.
- **Prod values profile** + an immutable `latest → test → prod` image-promotion model.
- **PID-1 init reaper** (`tini`) in the php/web/cron images.
- A documented cutover/rollback from the old `bcgov/moodle-nginx` workloads, which the
  handover doc keeps running untouched alongside the new stack.

---

**Recommended immediate move:** file the Artifactory `a58ce1-tools` request and the CSS SSO
request today (longest lead times). While they're pending, knock out Priority 2 (`-test`)
and Priority 3 (reclaim the 12 GiB Galera leftover) — both are unblocked.
