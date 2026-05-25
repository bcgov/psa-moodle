# Phase 4 — Operational hardening

This phase tightens what Phase 3 deployed. None of it changes the application — it changes how the platform reacts when things go wrong (node drains, hot pods, hostile egress) so prod-shape failures surface in `a58ce1-test`, not in front of learners.

Route timeout (900s) was already done in Phase 3. Phase 4 adds:

| New / changed | What it does | Where to verify |
|---|---|---|
| `PodDisruptionBudget` × 2 (web, php) | `maxUnavailable: 1` — drains can't take *both* replicas down in test. In dev the single replica still drains (with a brief outage); accepted. | `oc get pdb` |
| `topologySpreadConstraints` on web + php Deployments | Spread replicas across `topology.kubernetes.io/zone`; `ScheduleAnyway` so single-AZ degradation doesn't block scheduling. | `oc get pods -o wide` — check the `NODE` column spans zones |
| `HorizontalPodAutoscaler` × 2 (web, php) | CPU-based, conservative bounds. **Off in dev, on in test** so the scale path is exercised before any prod talk. | `oc get hpa` |
| Egress `NetworkPolicy` × 7 | Default-deny egress + explicit allows: DNS, in-cluster pod-to-pod (web→php, app→valkey, app→postgres), external 443 (HTTPS), external 25 (SMTP from ops jobs). | `oc get networkpolicy` |

What this phase does **not** do:

- **No `auth_oidc` plugin.** PSA Moodle uses Moodle core's `admin/tool/oauth2/issuers.php` for SSO; that's an administrator-managed runtime config, not an image concern. The egress NetPol below allows the outbound HTTPS the OAuth2 flow needs.
- **No PriorityClass / preemption.** Out of scope; Silver doesn't expose custom priority classes to tenant namespaces.

---

## Egress: what the new policies actually allow

Before Phase 4 the chart had ingress-only NetworkPolicies; egress was wide-open by default in Kubernetes. After Phase 4:

| From | To | Port | Why |
|---|---|---|---|
| any psa-moodle pod | `kube-system` (CoreDNS) | UDP/TCP 53 | Name resolution. Everything else fails first without this. |
| `web` pod | `php` pod | TCP 9000 | FastCGI |
| `php` / `cron` / `install` | `valkey` pod | TCP 6379 | Sessions + MUC cache |
| `php` / `cron` / `install` / `backup-integrity` / `restore-rehearsal` | Crunchy Postgres pods (label `postgres-operator.crunchydata.com/cluster`) | TCP 5432 | DB queries; backup-side integrity checks |
| any psa-moodle pod | `0.0.0.0/0` | TCP 443 | OAuth2 IdP discovery + token (e.g. `loginproxy.gov.bc.ca`), `api.github.com` (`local_githubsync`), the ELM endpoint (`local_psaelmsync`), the kube API (`oc` calls from ops Jobs) |
| `backup-integrity` / `restore-rehearsal` / `moodledata-snapshot[-prune]` | `0.0.0.0/0` | TCP 25 | `apps.smtp.gov.bc.ca` — the backup alert mailer from Phase 6 |

### Why `0.0.0.0/0` and not per-FQDN

Kubernetes `NetworkPolicy` cannot express FQDN allowlists — only IP CIDR + pod/namespace selectors. For internet-bound traffic that means either:

1. Allow a broad CIDR (what we do — port-restricted: 443 and 25 only).
2. Pin to specific IP CIDRs of GitHub / the IdP / the SMTP relay — brittle, breaks on cloud-provider re-IP.
3. Layer **OpenShift `EgressFirewall`** on top of NetworkPolicy. `EgressFirewall` *does* support DNS names and is the right tool for per-FQDN restriction. If BC Gov Platform mandates this, the `EgressFirewall` lives at the namespace level and is layered on, not instead of — our NetworkPolicy keeps blocking everything except the ports we listed, and `EgressFirewall` further restricts the destinations.

If you want to narrow the CIDR yourself (e.g. to a vetted BC Gov egress range), override in `values-<env>.yaml`:

```yaml
networkPolicy:
  egress:
    externalHttpsCidr: "142.34.0.0/16"   # example only — replace with the real range
    externalSmtpCidr:  "142.34.0.0/16"
```

---

## Apply

Phase 4 is purely chart changes — no image rebuilds, no new Containerfile.

```sh
# Local sanity check first (no cluster required).
make chart-check

# Server-side dry-run against a58ce1-dev (needs `oc login`, no apply).
make chart-dryrun-dev

# Apply.
helm upgrade --install psa-moodle ./chart/psa-moodle \
  -n a58ce1-dev \
  -f ./chart/psa-moodle/values-dev.yaml \
  --set image.tag=v0.1.0-dev1 \
  --wait \
  --timeout 10m
```

For test:

```sh
helm upgrade --install psa-moodle ./chart/psa-moodle \
  -n a58ce1-test \
  -f ./chart/psa-moodle/values-test.yaml \
  --set image.tag=v0.1.0-dev1 \
  --wait \
  --timeout 10m
```

---

## Verify

### PodDisruptionBudgets

```sh
oc -n a58ce1-dev get pdb -l app.kubernetes.io/instance=psa-moodle
# Expected: psa-moodle-web and psa-moodle-php, MAXUNAVAILABLE=1, ALLOWED-DISRUPTIONS=0 or 1
```

Cordon a node hosting one of the pods and run `oc adm drain --ignore-daemonsets --delete-emptydir-data <node>`. In test (2 replicas), the drain should complete and at no point should both replicas be `NotReady` simultaneously. **Roll the cordon back when you're done** (`oc adm uncordon <node>`).

### Topology spread

```sh
oc -n a58ce1-test get pods -l app.kubernetes.io/component=web -o wide
oc -n a58ce1-test get pods -l app.kubernetes.io/component=php -o wide
# Read the NODE column. In a multi-AZ cluster, web's two pods should land on
# nodes in different zones — likewise php.
oc get nodes -L topology.kubernetes.io/zone
```

If both replicas of a component land in one zone, the scheduler honoured `whenUnsatisfiable: ScheduleAnyway` because the other zone couldn't fit them (resource pressure). That's correct behaviour — it's a soft constraint by design.

### HPA

```sh
oc -n a58ce1-test get hpa -l app.kubernetes.io/instance=psa-moodle
# Expected: psa-moodle-web (2→4) and psa-moodle-php (2→6).
# TARGETS column should show a number like "5%/70%" — if it's "<unknown>/70%",
# the metrics-server isn't returning Pod metrics for this namespace.
```

If you see `<unknown>`: check `oc adm top pods -n a58ce1-test`. If that also fails, OpenShift's user-workload-monitoring or metrics-server isn't reaching these pods. That's a Platform-side fix (file with Platform Services, not a chart change).

To prove scale-up actually triggers, run `apache-bench` or `hey` from inside the cluster against the Route for ~2 minutes:

```sh
oc -n a58ce1-test run hey --rm -it --image=docker.io/rakyll/hey -- \
  -z 2m -c 50 https://psa-moodle-test.apps.silver.devops.gov.bc.ca/
oc -n a58ce1-test get hpa -w
```

Watch REPLICAS climb toward `maxReplicas` while load is on; it should settle back to `minReplicas` ~5 min after the load stops (the `scaleDown.stabilizationWindowSeconds: 300` in the HPA).

### NetworkPolicy — egress allows the right things

The cheap positive check: pods stay healthy after `helm upgrade`. Egress is the most likely thing to silently break — if you see `php` failing readiness because it can't reach `valkey` or Postgres, the most likely cause is a missing egress rule on a component that wasn't anticipated.

```sh
# Should be 12 NetworkPolicies (5 ingress + 7 egress).
oc -n a58ce1-dev get networkpolicy -l app.kubernetes.io/instance=psa-moodle

# DNS works?
oc -n a58ce1-dev exec deploy/psa-moodle-php -- getent hosts api.github.com

# Postgres reachable?
oc -n a58ce1-dev exec deploy/psa-moodle-php -- bash -c \
  'php -r "var_dump(@fsockopen(getenv(\"DB_HOST\"), (int)getenv(\"DB_PORT\"), \$e, \$es, 3));"'

# OAuth2 IdP discovery reachable? (substitute your real issuer)
oc -n a58ce1-dev exec deploy/psa-moodle-php -- \
  curl -s -o /dev/null -w '%{http_code}\n' https://loginproxy.gov.bc.ca/auth/realms/standard/.well-known/openid-configuration
```

### NetworkPolicy — egress denies the wrong things

```sh
# Should fail — port 80 isn't on the allowlist.
oc -n a58ce1-dev exec deploy/psa-moodle-php -- \
  curl -s -o /dev/null -w '%{http_code}\n' --max-time 3 http://example.com/ || echo "blocked (expected)"

# Should also fail — port 443 is allowed, but to web pods only outbound to php
# is allowed by the web-to-php-egress policy; web should NOT be able to reach
# external HTTPS… actually web DOES match the all-pods allow-external-https
# rule. So this is allowed by design. Don't try to assert otherwise.
```

If you want to *prove* the default-deny is in force, temporarily flip a known-good rule off (`networkPolicy.egress.enabled=false`) and observe that pods are unhealthy — then turn it back on. **Do not do this on prod.** Dev is the right place.

---

## SSO note

SSO is configured at runtime via Moodle UI:

> Site administration → Server → OAuth 2 services → Add issuer

…then enable the core `auth_oauth2` plugin under Site administration → Plugins → Authentication. No code change, no chart change, no image rebuild. The Phase 4 egress policy gives the php pods outbound HTTPS so the OAuth2 token / userinfo / JWKS calls actually leave the namespace.

If at some future point you decide you *do* want auth_oidc (e.g. for advanced claim mapping the core plugin doesn't support), that's a Containerfile change: clone `https://github.com/Microsoft/o365-moodle/tree/master/auth/oidc` or the Catalyst fork into `${MOODLE_SRC}/auth/oidc` in the `src` stage. It's not on the Phase 4 list because the existing setup doesn't need it.

---

## Rollback

Each Phase 4 feature has a single toggle in `values.yaml`:

```yaml
pdb:
  enabled: false              # turn off PDBs

hpa:
  web:  { enabled: false }    # turn off HPAs (also re-enables spec.replicas)
  php:  { enabled: false }

topologySpread:
  enabled: false              # remove spread constraints

networkPolicy:
  egress:
    enabled: false            # leave ingress rules, drop all egress restriction
```

Then `helm upgrade` with the override. No data loss path — Phase 4 doesn't touch storage, secrets, or the database.

---

## Phase 4 acceptance criteria

- [ ] `make chart-check` clean on both `values-dev` and `values-test`
- [ ] `make chart-dryrun-dev` and `chart-dryrun-test` succeed (server-side validation against the cluster)
- [ ] `helm upgrade --install` succeeds against `a58ce1-dev`
- [ ] All pods Ready after upgrade; install Job is not re-run (Helm post-install hook stays idempotent)
- [ ] Two PDBs visible (`oc get pdb`)
- [ ] In test only: two HPAs visible and reporting actual CPU % (not `<unknown>`)
- [ ] 12 NetworkPolicies visible (5 ingress + 7 egress)
- [ ] OAuth2 login still works against the configured issuer (manual: log in via the SSO button)
- [ ] Backup alert mailer still works (manual: `oc create job --from=cronjob/psa-moodle-backup-integrity test-alert-$(date +%s) -n a58ce1-dev` — confirm the email lands)
- [ ] `oc adm drain` of a worker hosting a php pod completes without dropping the Moodle login page (test only)

When the boxes are ticked, Phase 4 is done and Phase 7 (data migration rehearsal) is unblocked.
