**Independent review of the PSA Moodle rapid assessment**

Reviewed 24 September 2026. Repository commit: `57f5ca7629e7442426af9131bbfdd6575997fafe` (6 June 2026).

Source: `psa-moodle-rapid-assessment-report.pdf`, 221 pages, assessment ID `ra-2026-09-09T045716Z`. Its opening assessment date is 9 September; some appended analyses were refreshed on 14 September.

**Decision for leadership**

Accept this report as an input to a hardening backlog, with corrections. Do not accept its `100/100 Critical` headline as an evidence-based rating of the deployed service, or interpret its 64 findings as 64 independently demonstrated vulnerabilities. It identifies real release-management, privilege, and configuration weaknesses, but mixes repeated findings, local-development settings, inactive features, and hypotheses about production. Some assertions are contradicted by the application and platform controls actually running.

The independent evidence also reveals more consequential gaps than several of the report's High findings: the public dev instance is behind security maintenance releases; existing namespace policies weaken the chart's intended network isolation; and application-file recovery and restore verification are not implemented/running in the deployed PoC. Production readiness remains unproven. That supports retaining the existing production gate, not declaring either a security incident or a clean bill of health.

**What the report says**

The report correctly recognizes this as a deployment repository: Moodle and its plugins are fetched during image builds, rather than stored as tracked application source here. It examines Containerfiles, PHP/nginx overlays, Helm resources, operational scripts, and workflows. Its main concerns are:

- Broad ops permissions to execute commands in pods, read Secrets, and create/delete database clusters.
- Floating plugin, core, image, and build-tool dependencies without an image/security scanning gate.
- Missing browser headers and overly broad outbound HTTPS permissions.
- Unnecessary application service-account tokens, writable filesystems, permissive data-directory modes, and transport hardening gaps.
- Limited behavioral/security tests and incomplete operational alerting.

It also credits non-root containers, dropped capabilities, generated credentials, default-deny network policies, and backup/restore automation. Some of that credit describes templates or intentions rather than active, verified controls.

Its headline counts are 0 Critical, 8 High, 18 Medium, 37 Low, and 1 Informational. The score is simply `min(100, 8*5 + 18*2 + 37*1) = 100`. This is a weighted finding-count formula, not a probability of compromise, impact assessment, CVSS score, or penetration-test result.

**Scope and evidence limits of this review**

I checked the 64-claim index and relevant detailed sections against tracked repository files, rendered the PoC/dev/test Helm profiles, and made read-only OpenShift investigations in this project's namespaces. Runtime checks included a normal unauthenticated login-page request, installed version/configuration reads, a Valkey PING without authentication, and PostgreSQL connection/authentication metadata. No application records or Secret values were retrieved for this review. No workloads, configuration, or application source were changed; this document is the only repository addition from the review.

The active CLI context initially pointed to another namespace; investigation commands explicitly selected `a58ce1-dev`, `a58ce1-test`, or `a58ce1-prod`. Findings here do not describe any separate legacy production Moodle deployment outside that scope.

This was not an exploitation exercise, authenticated application audit, full plugin review, image/SBOM vulnerability scan, disaster-recovery drill, or examination of cluster-wide controls. GitHub settings and actual Actions run history were not independently queried. The account could not list `EgressFirewall` objects in `a58ce1-dev`; additional platform egress restrictions therefore remain unknown. Storage/etcd encryption and central audit/log retention were not verified.

The ignored `plugins/` directory contains local material, but the Containerfile clones plugins from GitHub. Local ignored copies are not evidence of the source revision shipped in an image.

**Observed deployment on 24 September**

| Evidence | Observation | Meaning |
| --- | --- | --- |
| Application workloads | `psa-moodle-web`, `psa-moodle-php`, and `psa-moodle-cron`, each one replica, using `v0.1.0-poc5` in `a58ce1-dev` | The running release remains the PoC profile. |
| Application image age | These application pods were created on 6 June 2026 | A weekly rebuild declaration is not evidence that patches reached the running service. |
| Installed software | Moodle `4.5.11+ (Build: 20260525)`, PHP `8.3.31`; HTTP advertises nginx `1.27.5` | Concrete installed versions are available; a branch/tag-only inventory is insufficient. |
| Test/prod inventories | No Deployments, StatefulSets, or CronJobs from this release in `a58ce1-test` or `a58ce1-prod`; unrelated routes/legacy resources exist | The report's repeated claims about this release shipping directly to production are unsupported. |
| Route | Edge TLS, HTTP redirect, 900-second timeout | The expected external TLS configuration is present. |
| Pod admission | `restricted-v2`, arbitrary non-root UID, dropped capabilities, no privilege escalation | Important containment controls are active. |
| Application tokens/filesystems | Web/PHP/cron/Valkey have projected API tokens and writable root filesystems | The hardening omissions are present, but a token is not proof of administrative privileges. |
| Ops role | Namespace-wide exec, Secret reads, and PostgresCluster create/delete grants exist | Broad privileges remain provisioned despite no active ops pods. |
| PostgreSQL | Observed a `moodle` connection using TLS 1.3; HBA permits general network clients through `hostssl ... scram-sha-256` | The deployed server requires encrypted client transport; client certificate verification is a separate gap. |
| Valkey | PING with `REDISCLI_AUTH` removed returned `NOAUTH Authentication required.` | Deployed session storage does enforce authentication. |
| Database backups | Full backup CronJob last succeeded at `2026-09-24T02:00:38Z`; hourly incremental at `2026-09-24T23:00:16Z` | Database backups are running. Success status alone does not prove recoverability. |
| Extra backup/monitoring resources | No application integrity/rehearsal CronJobs, PodMonitors, ServiceMonitors, or application PrometheusRules; a platform rule exists | PoC monitoring and extra backup checks are disabled; platform monitoring must not be confused with application monitoring. |
| Storage | Current PostgreSQL data and repository PVCs use `netapp-file-standard`, despite newer chart defaults requesting block | Repository defaults and deployed state differ. No file-backup PVC or VolumeSnapshots were observed. |

**Where I concur, and where conclusions need correction**

**1. Ops permissions: valid finding, with a narrower deployment context.**

[The ops Role](../chart/psa-moodle/templates/rbac-ops.yaml) really grants unrestricted namespace-level `pods/exec`, Secret `get/list`, and PostgresCluster `create/delete`. The live Role matches. An attacker who acquires that identity has a serious ability to read credentials, execute commands, and disrupt databases in that namespace. The report does not demonstrate how an unauthenticated outsider acquires it, and the dev Role does not authorize deletion in a separate production namespace.

No active ops pods were observed, and PoC operational jobs are disabled, but their Role and binding are rendered unconditionally. Remove unused permissions when features are disabled. Separate integrity checking from restore provisioning. Prefer a specifically named Secret `get` permission without `list`, or direct Secret injection where appropriate. Limit deletion to the rehearsal resource and consider a separate rehearsal namespace.

Do not mechanically add `resourceNames` everywhere: Kubernetes cannot name-restrict top-level `create` requests, and dynamically named pods complicate exec scoping. Use a combination of separated identities, namespace boundaries, and admission restrictions as needed. [Kubernetes RBAC documentation](https://kubernetes.io/docs/reference/access-authn-authz/rbac/).

**2. Supply chain: valid and important; automatic production deployment is not established.**

[Containerfile.php](../Containerfile.php) clones Moodle's stable branch, HVP's master branch, and five other plugin/theme default branches. It downloads floating build scripts without checksums; [Containerfile.ops](../Containerfile.ops) downloads versioned tools without verification. [The workflows](../.github/workflows/build.yml) contain no explicit image/dependency/secret scanning gate. These are reproducibility and compromise-prevention gaps, even where upstream repositories are trusted.

However, the deploy workflow explicitly supports only dev/test, and pushing/deploying is conditional on credentials. No production values profile exists. Replace the report's assertion that upstream commits automatically become production code with the more defensible claim that uncontrolled upstream changes can enter subsequent builds.

Pin reviewed source revisions and deployment digests, record a build manifest/SBOM, verify downloaded tools, and automate reviewed security updates. Pinning must be paired with patch delivery; frozen dependencies are not a security solution.

**3. Browser headers: partially false positive, partly real hardening work.**

The report's CONFIG-001 calls missing CSP and X-Frame-Options a High finding, reasoning that nginx is the only place headers could be set (PDF pp. 113-116). That is wrong: the upstream application can emit headers too. A normal GET to the deployed `/login/index.php` returned `X-Frame-Options: sameorigin`.

CSP, X-Content-Type-Options, Referrer-Policy, Permissions-Policy, and HSTS were not present on that response. This supports a measured header review, but does not establish XSS, clickjacking, or exploitability. Test actual responses for login, authenticated content, file delivery, and errors; design CSP around Moodle/H5P/SSO behavior. The single sampled response does not prove coverage on every endpoint.

**4. Database TLS: server enforcement is present; client trust hardening remains.**

CONFIG-004/CRYPTO-002 correctly identify no explicit client TLS policy/CA mounting in [config.openshift.php](../config/moodle/config.openshift.php). They should not be reported as evidence of current plaintext database traffic. PostgreSQL HBA rules require TLS for the application's network connections, and `pg_stat_ssl` showed TLS 1.3 for an active `moodle` connection.

The unresolved concern is explicit client-side verification of the server identity and fail-closed configuration. The installed Moodle driver reads `$CFG->dboptions['ssl']`, accepting `disable`, `prefer`, `require`, and `verify-full`; blindly adding a `dbsslmode` key would not implement that control in this driver. Plan verified TLS with the proper trust material and hostname. The same inspection also showed the driver's timeout key is `connecttimeout`, while this overlay sets `connect_timeout`; that setting should be corrected during config cleanup.

**5. Service-account tokens, egress, and writable code: real containment work.**

AUTHZ-005 through AUTHZ-009 describe one repeated root cause. Tokens are mounted in the active application pods, but no namespace-admin permission for the default identity was established. Disable automount for workloads that do not use the Kubernetes API, retaining deliberate API access only for jobs that need it.

CONFIG-006 is accurate: the deployed chart policy permits TCP 443 to `0.0.0.0/0` release-wide, including nginx and Valkey. Narrow the component selector and required destinations. This is a containment weakness, not an initial-compromise mechanism; I would normally treat the standalone finding as Medium pending a threat/data assessment. A TCP port rule does not itself verify that the traffic is HTTPS or encrypted, contrary to the report's explanation on p. 120. Additional EgressFirewall controls could not be inspected.

CONFIG-007 deserves more practical attention than its Low label suggests. The PHP image makes `/var/www/html` group-writable, and `is_writable('/var/www/html/config.php')` returned `yes` as the running container user. Code baked into an image is not necessarily immutable at runtime. This allows a prior application compromise to modify container-local application files until the pod is replaced; it is not proof of an existing compromise or persistence across fresh pods. Use read-only application code/root filesystems and explicit writable data/cache/temp mounts, after compatibility checks.

**6. Backup and recovery credit is overstated.**

TEST-004 states that moodledata is snapshotted daily (PDF pp. 219-220). [Base values](../chart/psa-moodle/values.yaml) explicitly disable snapshots, explain that this design was unsuitable for the RWX data volume, and record the missing replacement. Neither dev nor test enables them. The deployed PoC additionally disables integrity checks and restore rehearsal in [values-poc.yaml](../chart/psa-moodle/values-poc.yaml).

The accurate state is: database backup jobs run, but no application-managed moodledata backup/recovery path was demonstrated; no deployed restore rehearsal was found. [The existing backlog](next-steps.md) already acknowledges off-site backups and an actual restore drill. That is a production-readiness blocker with important data-loss implications, not simply a Low-rated missing snapshot test. Platform storage protection, if any, needs separate confirmation.

The dormant scripts are not sufficient evidence of comprehensive recovery testing. Snapshot creation exits before checking `readyToUse`, and a denied snapshot-class lookup is treated like a missing class and returns success after a warning. `alert.sh` swallows mail-delivery failure. Backup/rehearsal scripts also have early command failures that can bypass their custom `fail()` notification paths. These are source-level observations, not failures reproduced by running recovery jobs. Prove a complete restore of both database and uploaded files, with compatible recovery points and measured RPO/RTO, in isolated test resources.

**7. Versions: the PHP EOL assertion is incorrect, while Alpine needs stronger wording.**

DEP-006 says PHP 8.3 is approaching full EOL around November 2026 (PDF p. 207). Official PHP documentation says active support ended 31 December 2025 and security support continues through 31 December 2027. Being in security-only support is not the same as being unsupported. Moodle 4.5 supports PHP 8.3; do not force a runtime jump without checking compatibility. [PHP support schedule](https://www.php.net/supported-versions.php), [Moodle 4.5 requirements](https://moodledev.io/general/releases/4.5).

Alpine 3.20's regular support ended 1 April 2026; official status is now support on request. DEP-008 should say past normal support, not merely approaching it. This image is for currently disabled ops jobs, which changes immediate exposure but not the need to update it before use. [Alpine release schedule](https://www.alpinelinux.org/releases/).

**Additional findings and priorities from the independent review**

| Priority | Finding and evidence | Recommended outcome |
| --- | --- | --- |
| Address promptly | The public dev instance reports Moodle 4.5.11+ from May. Official 4.5.13 and 4.5.14 release notes include later security fixes. | Inventory the installed core/plugins, assess relevant advisories and data exposure, build/test a current supported maintenance release, and deploy it through a controlled path. No exploit was attempted. |
| Address promptly | Live namespace policies `allow-same-namespace` and `allow-all-internal` select all destination pods and allow broader ingress than the chart's per-hop rules. | Review the union of namespace policies and source egress controls, coordinate changes with coexisting workloads, and verify both allowed and blocked traffic. |
| Before production or valuable data | Only DB backups were demonstrated; file backup, off-site recovery, and restore validation remain unproven. | Implement and rehearse combined DB/file recovery and alert on missing/stale backup success. |
| Before relying on automated patching | Builds use only the repository's short SHA as image tag. A scheduled rebuild of unchanged HEAD reuses the tag, and the chart defaults to `IfNotPresent`. No unique build revision forces a new pod template. | Produce a unique immutable build identity/digest, promote that exact artifact, and verify the running digest/version after deployment. |
| Before expanding exposure | Broad ops Role remains even with ops jobs off; unnecessary API tokens and writable code expand the impact of a compromise. | Conditional/split ops RBAC, no application token automount, and read-only code. |
| Before production promotion | The workflow waits for new application pods before invoking the database upgrade, with no maintenance-mode or cron-quiescence procedure in that workflow. | Establish a tested upgrade/rollback sequence that accounts for schema changes and concurrent requests/tasks. |
| Production readiness | PoC single replicas, no application monitoring, no validated HA/test deployment, and existing NFS PostgreSQL PVCs remain. | Complete the already documented test, monitoring, storage, SSO, HA, and cutover work with evidence of operation. |

The version comparison is based on official [Moodle 4.5.13](https://moodledev.io/general/releases/4.5/4.5.13) and [4.5.14](https://moodledev.io/general/releases/4.5/4.5.14) release notes. Version 4.5.14 was released after the assessment's original 9 September date; 4.5.13 predates it. This review establishes a maintenance gap, not that every later advisory is exploitable under the site's configuration. Individual advisory pages returned HTTP 403 during this review, so their prerequisites were not independently checked.

The network-policy conclusion follows from the live manifests and Kubernetes' documented additive semantics: an allow rule in one policy is not overridden by a deny-by-default policy. End-to-end reachability can still be constrained by source egress or other platform controls; no packet-path exploitation was attempted. [Kubernetes NetworkPolicies](https://kubernetes.io/docs/concepts/services-networking/network-policies/).

The repeated-tag concern is a source-level inference, not a claim about an observed Actions failure: rebuilding an unchanged tag does not itself change a Deployment's pod template. [Kubernetes Deployment rollout behavior](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/).

**Disposition of all 64 report findings**

“Accept” below confirms the stated configuration/assurance gap, not demonstrated exploitation or the report's severity. “Qualify” preserves part of the issue but changes its context or impact. “Correct” means a material premise is wrong or misleading. Related IDs are consolidated into common remediation items rather than counted again as independent risk.

| Report IDs | Disposition | Independent evaluation |
| --- | --- | --- |
| AUTH-001 | Qualify | Empty client AUTH fallback exists. Local Valkey deliberately has no password; deployed Valkey requires one. Omitting the client password does not bypass an authenticated server. |
| AUTH-002 | Accept, local only | Local Valkey is unauthenticated but has no host-published cache port. Do not apply this claim to the deployed authenticated Valkey. |
| AUTHZ-001 | Accept | Namespace-wide pod exec exists in source and live ops Role. Serious conditional impact after identity compromise. |
| AUTHZ-002 | Accept | Namespace-wide Secret get/list exists. Reduce to actual required access. No Secret values were read in this review. |
| AUTHZ-003 | Accept with scope correction | Ops identity may delete databases in its namespace. The dev Role does not grant deletion in prod. No delete was attempted. |
| AUTHZ-004 | Accept, dormant | Optional broad ClusterRoleBinding is a poor pattern; the flag is false and this template is not rendered in checked profiles. Use a minimal dedicated role if needed. |
| AUTHZ-005, AUTHZ-006, AUTHZ-007, AUTHZ-008, AUTHZ-009 | Accept, consolidate | Five instances of token-automount hardening. Active web/PHP/cron/Valkey mounts confirmed; install job is transient. Effective administrative power is not established by token presence. |
| VULN-001, VULN-002, CONFIG-010 | Accept, consolidate | Permissive data modes exist; deployed data/filedir modes observed as 777. Tighten after testing arbitrary UID/fsGroup behavior. Shared PHP/cron access is intentional and not eliminated merely by changing mode. |
| VULN-003, VULN-005 | Accept, low priority | Login response advertises PHP/nginx versions. Hiding banners is useful hygiene but does not replace patching. |
| VULN-004 | Qualify | Empty disable_functions is not an application vulnerability by itself. Evaluate compatibility and threat model; PHP documents that this mechanism is not sufficient isolation. |
| VULN-006, CONFIG-001 | Correct/qualify | No nginx directives, but live login has X-Frame-Options. CSP is absent on that response. Missing defense in depth is not a demonstrated XSS/clickjacking exploit. |
| VULN-007, VULN-008 | Qualify | Heredoc YAML uses operator-controlled variables. Validate inputs for robustness; no lower-trust attacker-controlled entry point was identified. |
| CONFIG-002, CONFIG-003 | Accept for sampled response | Listed headers absent on login. Add/test compatible policy; avoid implying every application endpoint was checked. |
| CONFIG-004, CRYPTO-002 | Qualify, consolidate | Client TLS/trust config absent; deployed PostgreSQL requires TLS and observed connection uses TLS 1.3. Use the driver's actual `ssl` key and validate server identity. |
| CONFIG-005 | Correct | Values inject MOODLE_DEBUG, but config.openshift.php never reads it. The claimed debug-output effect does not follow from these overlays. Runtime DB-configured debugging was not evaluated. |
| CONFIG-006 | Accept, severity/context adjustment | Broad port-443 egress is deployed. Normally a Medium containment issue alone, potentially more serious in a chain. Other egress controls unverified. |
| CONFIG-007 | Accept; prioritize writable code | Active application root filesystems are writable and PHP can write config.php. Meaningful post-compromise containment gap. |
| CONFIG-008, SECRET-001, SECRET-002 | Accept, consolidate/local | Known local DB defaults are real, not leaked production credentials. Local DB port mapping lacks a localhost bind; bind to loopback and keep sensitive data out of disposable stacks. Actual host reachability depends on Podman/network/firewall behavior. |
| CONFIG-009 | Accept, dormant in PoC | Monitoring policy selects namespace-wide ports 9187/9253. Narrow destination selectors when enabling it. Larger live broad-ingress policies deserve attention first. |
| CRYPTO-001 | Accept with platform caveat | Valkey protocol lacks application TLS but has authentication. Overlay/network encryption was not checked; packet interception was not demonstrated. |
| CRYPTO-003 | Accept as design observation | No pgBackRest archive cipher configured. Underlying storage encryption is unknown; this is not proof of universally unencrypted storage. |
| CRYPTO-004, LOG-003 | Accept, consolidate/dormant | swaks invocation has no TLS option. Delivery path is inactive in current PoC. Confirm relay-supported secure transport and data handling before enabling. |
| CRYPTO-005, LOG-004 | Qualify, consolidate/dormant | `requireTLS: false` permits plaintext, but does not establish that every delivery uses plaintext. Actual negotiated transport not tested; application AlertmanagerConfig is absent in PoC. |
| CRYPTO-006 | Informational | Base64 encoding is not encryption; actual etcd encryption is platform-owned and unverified. Not an independent application vulnerability. |
| DEP-001, DEP-002 | Accept, consolidate | Floating HVP/plugin/theme revisions are a genuine build-control gap. No upstream compromise or automated production path was demonstrated. |
| DEP-003, DEP-004, DEP-009 | Accept, consolidate | Downloads are unverified; extension installer/healthcheck are floating, oc/swaks versioned but lack integrity checks. |
| DEP-005 | Accept | Core revision is floating. Pair reproducible builds with timely maintenance releases; actual deployed core is stale. |
| DEP-006 | Correct | PHP 8.3 security support ends 31 December 2027, not around November 2026. Installed patch level still requires normal advisory checking. |
| DEP-007, DEP-011, DEP-013 | Accept, consolidate | Floating nginx/Valkey/PHP CLI tags prevent immutable artifact identification. Record actual digests and update deliberately. |
| DEP-008 | Correct wording; accept risk | Alpine 3.20 is past normal support, not just approaching it. Ops workload currently inactive. |
| DEP-010 | Qualify | Operator-managed Postgres patch selection is not automatically a defect. Live image identifies PostgreSQL 15.15; record its digest and confirm the platform's supported update process. |
| DEP-012 | Accept, local only | Mutable local registry fallback tag is reproducibility hygiene, not established remote exploitation. |
| LOG-001 | Accept | Cron writes heartbeat even after nonzero exit; process liveness is not task success. Add failure/staleness alerting and check Moodle task-level failures as well as exit code. |
| LOG-002 | Accept, bounded | Installer expands admin password into process argv. Exposure requires appropriate process/node/exec/log access during installation. It is not printed literally in the manifest, nor exposed to every unrelated pod. Verify a supported safer bootstrap mechanism. |
| LOG-005 | Accept local debug risk; qualify detail | Local config enables SMTP debugging by default through Compose. Use synthetic data and separate debugging toggles. Actual sensitive transcript contents were not captured or verified. |
| LOG-006 | Qualify | FPM-specific request log is disabled, but nginx access logs exist. Decide whether execution timing/script detail is needed rather than count this as absent access auditing. |
| LOG-007 | Accept, minor hygiene | Temporary file cleanup is missing in ephemeral rehearsal pod. Report overstates its contents: the script tees the generated manifest, not all subsequent output, into that file. |
| TEST-001 | Accept assurance gap; challenge High | Behavioral/security tests are absent from tracked config/deploy workflows. This does not demonstrate an authentication vulnerability. Add focused end-to-end authorization/SSO/session/file-access tests. |
| TEST-002 | Accept | No explicit CI security scan gates. GitHub-hosted features/settings remain independently unverified; empty alert lists cannot establish coverage. Scan built images and the fetched application/plugin sources. |
| TEST-003 | Accept | PoC profile missing from CI lint/render matrix. Manual PoC/dev/test lint and render checks all passed in this review. |
| TEST-004 | Correct premise; increase readiness priority | File snapshots are disabled across checked profiles. Need an actual file-backup and restore strategy, not only a test for an existing daily snapshot. |
| TEST-005 | Qualify | Hook relies on installer exit status; deploy workflow has a login smoke test afterward. Independent clean-install/upgrade verification is valuable but this is not absence of all validation. |
| TEST-006 | Correct part/accept part | CI builds both local and OpenShift image variants. It does not start/exercise the Compose stack. “Never built” is too broad; missing runtime integration test is accurate. |
| TEST-007 | Accept; raise practical priority | No automated network-policy connectivity checks. Live additive policies demonstrate why this matters. |

PHP's own [directive documentation](https://www.php.net/manual/en/ini.core.php) supports treating `disable_functions` as limited defense in depth. [Alertmanager configuration documentation](https://prometheus.io/docs/alerting/latest/configuration/) describes TLS requirement settings; allowing unencrypted delivery and proving a plaintext session are different claims.

**Quality issues in the assessment itself**

- The opening says 8 High findings, while the prose on p. 2 still says 9. Some domain rollups retain obsolete highest-severity entries after finding downgrades.
- The introduction and worker-status table say GitHub checks were unavailable/out of scope, while pp. 164-181 contain later successful-query summaries. The executive summary was not reconciled with the appended refreshes.
- Finding count is inflated by multiple IDs for the same root cause: database TLS, SMTP transport, writable data directories, local credentials, browser headers, and five token mounts. Useful component tracking is being conflated with independent risk accumulation.
- The report says no known CVEs, but also explains that installed patch levels and a live CVE inventory were not established. The defensible conclusion is “no confirmed CVEs identified by this assessment,” not “the deployment has none.” Zero repository alerts do not cover code cloned at build time.
- The testing section credits comprehensive backup/ops coverage without execution evidence, treats disabled snapshots as running, and marks deployment protection present merely because a GitHub Environment can be configured with required reviewers.
- A missing hashing tool is given as the reason some attack chains were not emitted. That is a report-generation limitation; computing a chain identifier would not validate exploitability.
- Several omissions are raised as security findings without an attacker path: absent Permissions-Policy, optional PHP function restrictions, operator-supplied YAML variables, and local default credentials. These belong in contextual hardening/assurance work, not an undifferentiated incident narrative.

**Validation performed and what remains**

Helm lint passed for PoC, dev, and test, with only the optional chart-icon recommendation. All three profiles rendered successfully. Bash syntax checks passed for the five ops scripts. The rendered PoC includes the broad ops Role but none of its optional operational CronJobs; dev includes integrity checking without rehearsal; test includes both; none includes moodledata snapshots. These checks validate syntax/template behavior only, not functionality or recoverability.

Runtime evidence came from explicit-namespace `oc get` inventories, read-only `oc exec` source/version checks, `SELECT` queries against `pg_stat_ssl`/`pg_stat_activity` and `pg_hba_file_rules`, a normal HTTPS login request, and an unauthenticated Valkey PING. No recovery jobs, upgrades, scans with payloads, or failure-injection tests were run.

The next useful evidence is a current image/source inventory and advisory triage, effective-network-policy tests in isolated test resources, and a documented combined database/file restore. Those results should drive an environment-specific risk decision and production gate. A second additive score would not improve that decision.
