# Next steps — psa-moodle after the PoC

The PoC proved the architecture works on BC Gov Silver: Moodle 4.5 on Crunchy
Postgres is **deployed and live** in `a58ce1-dev` at
<https://psa-moodle-dev.apps.silver.devops.gov.bc.ca/>. The job now is to turn a
single-namespace demo into a production-grade dev/test pipeline, then line up the
prod cutover (a separate, later approval).

This plan is sequenced by dependency and impact. Items in Priority 1 gate the
rest, so start there.

## Priority 1 — Unblock CI/CD

Today images are built locally (under QEMU on Apple Silicon) and pushed to the
cluster's internal registry by hand. That's the single biggest fragility: a
one-person, one-machine dependency.

- **Request the `a58ce1-tools` Artifactory repo** from Platform Services. This is
  a lead-time item (ticket + provisioning), so file it first — it gates
  `build.yml` / `deploy.yml`. Confirm the current BC Gov request channel before
  filing (Rocket.Chat is discontinued).
- Once provisioned, add the `ARTIFACTORY_USERNAME` / `ARTIFACTORY_PASSWORD`
  GitHub Actions secrets. `build.yml` already builds `linux/amd64` natively (no
  QEMU) and will start pushing automatically once the secret is present.
- Point the existing weekly `scheduled-rebuild.yml` at the real registry.
- **Outcome:** a `git push` deploys; no laptop in the loop.

## Priority 2 — Stand up `a58ce1-test`

Only `-dev` exists today; the handover doc scopes dev/test/tools.

- Apply the chart with the `values-test.yaml` profile.
- This doubles as the **clean-install regression check** — it proves the
  "no manual SQL / config / NetworkPolicy steps" claim holds on a fresh
  namespace, not just the hand-tuned one.

## Priority 3 — Close the PoC shortcuts for dev/test

These were deliberately disabled to get the demo up; they're real gaps for a
shared environment.

1. **Re-enable the egress NetworkPolicy.** Currently OFF because the DNS-allow
   rule never worked on Silver's OVN. This is the most important security item —
   an open environment means unrestricted egress. Needs an OVN-compatible policy
   (likely an explicit allow for DNS to the cluster resolver). Budget real
   debugging time.
2. **Fix the cron cadence.** Convert the hourly, Kyverno-throttled CronJob to a
   long-running Deployment that loops `cron.php` every 60s (Deployments aren't
   subject to the policy). Hourly cron breaks Moodle's normal scheduled-task
   cadence — fine for a demo, not for test.
3. **Re-enable monitoring + add-on backups.** Prometheus monitoring/exporters/
   alerts and the pgBackRest add-on backups are off in the PoC profile. Turn them
   on for dev/test and confirm the Alertmanager recipient (swap to a team
   distribution list when one exists).

## Priority 4 — Prove backup & restore (not just configure it)

The chart has pgBackRest and a moodledata snapshot path, but a backup you haven't
restored isn't a backup. Given the Galera split-brain incident that motivated
this re-platform, **do a real restore drill in `-test`**: take a backup, destroy
the cluster, restore, verify Moodle returns with data intact. Document the
runbook.

## Priority 5 — Application completeness

- **SSO** via Moodle core `admin/tool/oauth2/issuers.php` (not `auth_oidc`) —
  configure the BC Gov IDP issuer.
- **Validate the GitHub-cloned plugins/theme** (`itr8tech/pathcurator-moodle`,
  the `bcgovpsa` theme) actually function in the deployed instance, not just that
  they build.

## Then — Production cutover (separate track, later approval)

Out of scope until approved. Prerequisites to have ready:

- HA profile validated in test (multi-replica; the platform HA-guidelines
  alignment).
- Restore drill passing.
- Egress hardened; monitoring/alerting live.
- A documented cutover/rollback from the old `bcgov/moodle-nginx` workloads,
  which the handover doc keeps running untouched alongside the new stack.

---

**Recommended immediate move:** file the Artifactory `a58ce1-tools` request today
(longest lead time). While it's pending, knock out Priority 2 (`-test` namespace)
and start the egress-NetworkPolicy debugging in Priority 3 — both are unblocked.
