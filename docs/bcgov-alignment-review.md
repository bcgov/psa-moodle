# BC Gov Private Cloud alignment review — psa-moodle

**Date:** 2026-06-06
**Source of truth:** [bcgov/platform-developer-docs](https://github.com/bcgov/platform-developer-docs)
(`src/docs/**`, the scrapeable form of the Private Cloud Technical Documentation —
70 docs across 13 areas).
**Method:** every doc was read and reduced to concrete, checkable rules, compared
against this repo's actual manifests / configs / CI (not the roadmap), then each
candidate gap was adversarially re-verified against the real files. Findings were
further confirmed against the **live `a58ce1-dev` cluster** via `oc`.

## Headline

**psa-moodle is well-aligned with the platform docs.** Across 12 domains the review
produced **0 critical, 0 high, 14 medium, 55 low, 26 info** findings (13 further
candidates were rejected as false-positives on verification). Nothing is on-fire in
dev/test; the medium tier is dominated by **production-cutover lead-time items** that
are correctly deferred but were not yet tracked.

### What we already do well (independently confirmed)

- **Networking** — declarative default-deny NetworkPolicy, per-component least-privilege
  allows, only the web tier exposed (everything else ClusterIP), scoped to
  `app.kubernetes.io/instance` so it doesn't disturb the coexisting legacy `moodle-nginx`.
- **RBAC & secrets** — namespaced least-privilege ops SA (`edit`, not `admin`), no
  plaintext secrets committed, DB creds read from the Crunchy `pguser` Secret via
  `secretKeyRef`, admin password generated in-cluster and preserved across upgrades.
- **Resourcing** — memory-only limits with CPU requests (the BC Gov anti-CPU-throttle
  guidance), nothing BestEffort, HPAs only on stateless tiers, quota sized against real
  per-pod requests with auto-approval thresholds cited.
- **DB & backups** — Crunchy HA (3 instances + anti-affinity), pgBackRest full+incremental,
  **plus** a daily integrity check and a weekly restore-rehearsal that provisions a temp
  cluster from the repo. Ahead of most teams.
- **Images** — multi-stage, non-root, restricted-v2-SCC-friendly (group-0, no hardcoded
  UID/fsGroup), `linux/amd64` enforced, no `:latest`.
- **Cron** — long-running loop Deployment (the platform-endorsed pattern for PVC-mounting
  cron on Silver), not a Kyverno-throttled CronJob.

## Live-cluster verification (`oc`, a58ce1-dev, 2026-06-06)

| Check | Result |
|---|---|
| `netapp-block-standard` exists? | ✅ yes (provisioner `csi.trident.netapp.io`); quota **0/64Gi free** |
| `netapp-file-backup` exists? | ✅ yes; quota **0/32Gi free** (off-site backup is *unblocked*) |
| Default storage class | `netapp-file-standard` (NFS) |
| Live psa-moodle PVCs | Postgres datafiles, pgBackRest repo, **and** Valkey all on `netapp-file-standard` (NFS) — confirms M5 |
| VolumeSnapshotClass | only **`netapp`** exists — the chart pointed at `netapp-file-standard` (a *storage*-class name), so snapshots silently no-op'd — confirms M8 |
| snapshot-quota | 5 (so daily snapshots at retention 14 would have blown it anyway) |
| compute-long-running | CPU **900m/1 (90%)** — matches the dev quota-bump request |
| **Orphaned legacy workload** | a scaled-to-0 `mysql` StatefulSet + `mysql-read` Service + **3× `data-mysql-*` PVCs = 12Gi of 19Gi used** still in `a58ce1-dev` (the Galera leftover). Reclaimable. |

## Tier 1 — fixed in this branch (`fix/bcgov-alignment-tier1`)

These were the only findings that were actually wrong in **dev/test today** (not just prod).

| ID | Fix | Files |
|---|---|---|
| **M5** | Pin Postgres datafiles + pgBackRest repo to `netapp-block-standard` (was empty → NFS default). Block quota confirmed free. *Valkey stays on file — it's an RDB cache, and its StatefulSet `volumeClaimTemplate` is immutable so pinning would break `helm upgrade`. Note: these are operator-managed CRs, so the pin lands on a **fresh** deploy; the live dev DB needs a backup+restore (or fresh redeploy) to migrate off NFS.* | `values.yaml` |
| **M8** | Disable the moodledata VolumeSnapshot path (it could never run: moodledata is RWX/NFS, snapshots are block-only, and the class name was wrong) — stops the daily "SKIPPED" warning email. Corrected the misleading `snapshotClass` in `values-dev/test`. | `values.yaml`, `values-dev.yaml`, `values-test.yaml` |
| **LOG-05** | nginx now recovers the real client IP from `X-Forwarded-For` (`set_real_ip_from` RFC1918 + `real_ip_recursive`) and logs it via a custom `log_format main_xff` to stdout — access/audit logs attribute requests to learners, not the router pod IP. | `config/nginx/default.conf` |
| **Valkey auth** | Valkey now requires a password (generated `Secret`, `--requirepass`, `REDISCLI_AUTH` for the probe), and every cache client (`php`, `cron`, install Job) gets `CACHE_PASSWORD` via `appEnv`. Defense-in-depth on top of the existing NetworkPolicy. | new `templates/secret-valkey.yaml`, `_helpers.tpl`, `valkey-statefulset.yaml` |

Validated with `helm lint` + `helm template` across dev/test/poc; all render.

## Tier 2 — doc / decision hygiene (cheap)

- **Roadmap refresh** — `next-steps.md` has been rewritten to mark the completed P3 trio
  (egress / cron / monitoring) as done and to add the prod-cutover backlog below.
- **Stale runbook** — `poc-deploy-runbook.md` said egress was OFF and cron hourly; both
  are fixed. Corrected.
- **Storage-class doc contradiction** — `poc-quota-request.md` listed the DB PVCs as
  `block-standard` while `quota-request.md` listed everything as `file-standard`; reality
  was file. With the chart now pinning block, the **full-profile `quota-request.md` should
  split storage across the block and file class quotas**, and the VolumeSnapshot quota
  bump (→10/20) is **no longer needed** (snapshots are disabled).
- **Deliberate divergences worth recording as decisions, not oversights:** Debian/Alpine
  bases over RHEL/UBI; `tool_oauth2` over `auth_oidc`; user-workload-monitoring over
  Sysdig; GitHub Actions + Helm over Argo CD/GitOps; internal registry over Artifactory
  (interim).
- **Vault** — the standout secrets finding: Vault is **already entitled to `a58ce1`**
  (zero request, unlike Artifactory) yet is neither used nor mentioned. At minimum record
  the deferral; note External Secrets Operator is the no-chart-change adoption path.

## Tier 3 — production-cutover backlog (lead-time; track now even though deferred)

Most downgraded-from-high findings are legitimately deferred, but several are **long-lead**
and were missing from the cutover prerequisites:

- [ ] **STRA** (Security Threat & Risk Assessment) with the Ministry ISO — *longest lead time* (M9).
- [ ] **CSS/Pathfinder SSO request** — the credential source for IDIR/BCeID OIDC; "not yet requested" (M14).
- [ ] **Dedicated TLS cert via ADMS/Entrust** — *only if* a vanity domain is chosen; staying on `*.apps.silver` needs none (M3/M10).
- [ ] **Off-site backup** — currently **zero** off-cluster copy of DB or moodledata. `netapp-file-backup` quota (32Gi) is already present, so this is **unblocked**: move the pgBackRest repo to a second `netapp-file-backup` (or S3) repo, and add a moodledata rsync/tar → `netapp-file-backup` CronJob (M6/M7).
- [ ] **Valkey HA** — single-pod session SPOF; the deferral pointed at "Phase 4," which shipped without it (M4).
- [ ] **Artifactory `a58ce1-tools`** — gate for CI push *and* Xray image scanning (M1/M2/M12).
- [ ] **CI security scanning now** — Trivy (image CVE) + CodeQL/SonarCloud (SAST) don't need Artifactory and can land immediately (M13).
- [ ] **Monitoring maturity** — golden-signal SLIs (latency/error-rate, only FPM metrics today), an SLO, a team distribution list instead of one personal mailbox, an external black-box uptime check, an incident runbook.
- [ ] **Prod values profile** + immutable `latest→test→prod` image-promotion model.
- [ ] **PID-1 init reaper** (`tini`) in php/web/cron images — exec probes fork each interval with no reaper (the ops image already has tini).
- [ ] **Reclaim the orphaned `mysql` StatefulSet + `data-mysql-*` PVCs** (12Gi) once confirmed unneeded.

## The 14 medium findings (detail)

| ID | Domain | Finding | Disposition |
|---|---|---|---|
| M1 | build | Artifactory project/repo to push images not provisioned | Roadmap (P1); CI self-enables once the secret exists |
| M2 | deploy | Images hand-pushed to internal registry; chart default Artifactory repo absent | Same root cause as M1 |
| M3 | deploy | No Entrust/OCIO cert path for a prod custom hostname | Prod-cutover, **conditional** on vanity domain |
| M4 | resiliency | Single-replica Valkey = session/cache SPOF, no PDB | Prod-cutover (HA topology) |
| M5 | database | DB/repo PVCs silently on NFS, not block | **Fixed (chart)**; live migrate on redeploy |
| M6 | backup | All backups on-cluster only; no off-site copy | Prod-cutover; `netapp-file-backup`/S3 (unblocked) |
| M7 | backup | Backup PVCs not on `netapp-file-backup` (only OCIO-backed class) | Prod-cutover; quota present |
| M8 | backup | moodledata snapshot configured on a file class (can't snapshot) | **Fixed (disabled + corrected)** |
| M9 | security | No STRA started | Prod-cutover; longest lead time |
| M10 | security | No dedicated prod TLS cert ordered (ADMS) | Prod-cutover, conditional (see M3) |
| M11 | monitoring | nginx logs router IP, not real client IP | **Fixed (nginx real_ip)** |
| M12 | cicd | Build+push still a manual local hand-push | Roadmap (P1) |
| M13 | provisioning | No SAST/DAST/image CVE scanning in CI | Trivy/CodeQL addable now; Xray gated on M1 |
| M14 | provisioning | SSO IdP credential path (CSS) not requested; no per-env client config | Prod-cutover; file the CSS request |

## Low / info themes (55 + 26, condensed)

- **Build/registry** — bases pulled direct (not via Artifactory remote cache/Xray);
  `install-php-extensions` pinned to `latest`; Moodle core/plugins cloned from default
  branches without revision pinning; no registry pruning/quota plan.
- **Resiliency** — no PID-1 reaper; no explicit SIGTERM draining; requests estimated not
  metric-derived; in-cluster load test lacks the platform's approval/scheduling controls.
- **Backup/recovery** — Secrets (DB password regenerated on restore, OAuth2 client secret)
  not captured for namespace recovery; no "rebuild an empty namespace" recovery doc; no DB
  storage ≤80% / log-error alerting; retention is full-count only.
- **Networking** — egress uses `podSelector` on the `to` side (OVN-only; would no-op on
  legacy SDN); external 443/25 egress allowed from all pods incl. web; `0.0.0.0/0` CIDR
  (k8s can't do per-FQDN — EgressFirewall is the tool); Silver shared egress IP not noted
  for any IP-allowlisted partner (ELM/SMTP).
- **Secrets** — Vault entitled but unused/undocumented; no tier-aware Vault engine selector;
  Valkey auth absent (**fixed**).
- **Security** — plain etcd Secrets vs Vault; no image scanning; not built from BC Gov
  security-pipeline-templates; MFA/IDIR-link onboarding control not written down.
- **Monitoring** — no Sysdig onboarding; no golden-signal SLIs/SLO; single personal-mailbox
  alert recipient; no external/black-box uptime check; no incident runbook; php-fpm access
  log disabled; email-only alerting is slow off-hours.
- **Quotas** — operator-injected pods (repo-host, sidecars) cost unset/estimated; no
  pre-deploy "sum of requests fits quota" check; HPA-max coverage unvalidated under load.
- **CI/CD** — GitHub Actions + `helm upgrade --install` rather than Argo CD/GitOps; no
  gated prod path; internal-registry image accumulation with no cleanup; actions not SHA-pinned.
- **Provisioning** — `a58ce1-test` not yet created; pull secret + deploy SA created by hand
  (not IaC); SMTP relay instead of CHES for programmatic email; no pre-commit hooks; `oc`
  version sync not documented.

## Methodology note

Verification was adversarial: of 108 candidate gaps, 13 were rejected (e.g. claims based on
over-stated rules, invented rule IDs, or already-handled cases), 47 were downgraded as
"partial" (real but mis-scoped), and several "high" candidates were correctly reclassed to
"medium" because they are prod-cutover-deferred or conditional. This review reflects the
chart and cluster state on 2026-06-06.
