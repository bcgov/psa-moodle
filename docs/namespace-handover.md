# Namespace Handover: `moodle-nginx` → `psa-moodle`

**Cluster:** BC Gov Silver — `api.silver.devops.gov.bc.ca:6443`
**License plate:** `a58ce1`
**Namespaces in scope:** `a58ce1-dev`, `a58ce1-test`, `a58ce1-tools`
**Out of scope (deliberately):** `a58ce1-prod` — production cutover is a separate later approval.

This document is the runbook for re-pointing the existing namespaces from the `bcgov/moodle-nginx` repo to this `psa-moodle` repo. **Old workloads stay running untouched** while the new architecture is built alongside them. New workloads use a distinct `app.kubernetes.io/instance: psa-moodle` selector so the two coexist.

---

## Pre-flight checks

Run these once, before any of the changes below.

### 1. Confirm cluster access

```sh
oc login --server=https://api.silver.devops.gov.bc.ca:6443
oc projects | grep a58ce1
```

You should see all three namespaces. If any are missing, file a [BC Gov Platform Services request](https://digital.gov.bc.ca/cloud/services/private/) to provision them.

### 2. Confirm Crunchy Postgres Operator is available

```sh
oc get crd | grep -i postgrescluster
# expected: postgresclusters.postgres-operator.crunchydata.com
```

If absent: the cluster operator is normally pre-installed on BC Gov Silver. Open a Rocket.Chat ticket with `#devops-operations` referencing "Crunchy Postgres for Kubernetes operator not visible in `a58ce1-*`".

### 3. Confirm the storage class exists

```sh
oc get storageclass | grep -i netapp-file-standard
```

This is the RWX storage class we use for `moodledata` and pgBackRest's repo PVC.

### 4. Audit what's currently in the namespace (do NOT delete anything yet)

```sh
oc -n a58ce1-dev get deploy,sts,svc,route,cm,secret,pvc \
  -l 'app in (moodle, moodle-nginx)' -o name > /tmp/a58ce1-dev-old-resources.txt
oc -n a58ce1-test get deploy,sts,svc,route,cm,secret,pvc \
  -l 'app in (moodle, moodle-nginx)' -o name > /tmp/a58ce1-test-old-resources.txt
```

Keep these files — they're the inventory you'll decommission in Phase 8 (post-cutover), not now.

---

## Step 1 — Create a deploy ServiceAccount in each target namespace

The current `moodle-nginx` workflow likely runs as `default` or a long-lived deployer SA. We want a fresh SA scoped to this repo so we can revoke the old one cleanly.

Repeat for both `a58ce1-dev` and `a58ce1-test`:

```sh
NS=a58ce1-dev   # then re-run with NS=a58ce1-test

oc -n "$NS" create serviceaccount psa-moodle-deploy

oc -n "$NS" create rolebinding psa-moodle-deploy-edit \
  --clusterrole=edit \
  --serviceaccount="$NS:psa-moodle-deploy"
```

### Mint a long-lived token (for GitHub Actions)

OpenShift 4.11+ does not auto-create SA secrets. Create one explicitly:

```sh
cat <<EOF | oc -n "$NS" apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: psa-moodle-deploy-token
  annotations:
    kubernetes.io/service-account.name: psa-moodle-deploy
type: kubernetes.io/service-account-token
EOF

# Read the token (treat output as secret)
oc -n "$NS" get secret psa-moodle-deploy-token \
  -o jsonpath='{.data.token}' | base64 -d
```

Save the output. You'll paste it into a GitHub secret in Step 4.

---

## Step 2 — Artifactory credentials (Identity Token)

Images push to `artifacts.developer.gov.bc.ca/a58ce1-tools/psa-moodle/{web,php,cron}:<sha>` and pull from each namespace.

BC Gov's Artifactory is **JFrog** — the credential you use for `docker`/`podman`
login (and for the pull Secret) is a JFrog **Identity Token**, not a "robot
account." Generate one from your own user profile:

1. Open [BC Gov Artifactory](https://artifacts.developer.gov.bc.ca) → log in with IDIR
2. Go to your **user profile / settings** (top-right). You do **not** need to
   navigate to the `a58ce1` project — the token is tied to your account and
   carries your permissions (as `a58ce1` TO you can pull from `a58ce1-tools`).
3. Note your **Username** (exact string shown in the profile) — this is the
   `--docker-username` value below.
4. Click **Generate an Identity Token**, give it a description (e.g.
   `psa-moodle pull`), and **copy the token immediately** — it's shown once.

Save the username + token for the next step.

> A personal Identity Token unblocks deploys, but ties image pulls to *your*
> account. For CI and the permanent dev/test setup, prefer a dedicated
> service/technical account with `a58ce1-tools` Push and `a58ce1-dev`/`-test`
> Pull, if the platform provides one. The personal token is the self-serve path
> that always works.

---

## Step 3 — Image pull secret in each runtime namespace

So pods in `a58ce1-dev` / `a58ce1-test` can pull images that live in `a58ce1-tools`:

```sh
NS=a58ce1-dev   # then re-run with NS=a58ce1-test

oc -n "$NS" create secret docker-registry artifactory-pull \
  --docker-server=artifacts.developer.gov.bc.ca \
  --docker-username='<YOUR-ARTIFACTORY-USERNAME>' \
  --docker-password='<PASTE-IDENTITY-TOKEN>' \
  --docker-email='unused@example.com'

oc -n "$NS" patch serviceaccount default \
  -p '{"imagePullSecrets":[{"name":"artifactory-pull"}]}'
```

This patches the `default` SA — that's deliberate. Helm releases use the default SA unless overridden, and our Helm chart in Phase 3 will not override it.

---

## Step 4 — GitHub repository secrets

In the `psa-moodle` repo on GitHub → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**. Add:

| Name | Value |
|---|---|
| `OPENSHIFT_SERVER` | `https://api.silver.devops.gov.bc.ca:6443` |
| `OPENSHIFT_TOKEN_DEV` | output from Step 1 for `a58ce1-dev` |
| `OPENSHIFT_TOKEN_TEST` | output from Step 1 for `a58ce1-test` |
| `OPENSHIFT_NAMESPACE_DEV` | `a58ce1-dev` |
| `OPENSHIFT_NAMESPACE_TEST` | `a58ce1-test` |
| `OPENSHIFT_NAMESPACE_TOOLS` | `a58ce1-tools` |
| `ARTIFACTORY_USERNAME` | `a58ce1+psa-moodle-ci` |
| `ARTIFACTORY_PASSWORD` | the Artifactory token from Step 2 |

Phase 5 (CI workflows) consumes these. They are not used yet.

---

## Step 5 — Revoke / rotate the `moodle-nginx` repo's access

This is the actual "handover" — once new credentials work end-to-end, the old repo must lose write access so it can't accidentally redeploy on top of new workloads.

### What to revoke

1. **In the `bcgov/moodle-nginx` GitHub repo:** rotate or delete `OPENSHIFT_TOKEN`-style secrets pointed at `a58ce1-*`. Do not delete the repo or workflows themselves — they're still your historical reference.
2. **In the cluster:** find any ServiceAccounts the old workflow used:
   ```sh
   oc -n a58ce1-dev get sa
   oc -n a58ce1-dev get rolebinding -o wide | grep -v psa-moodle-deploy
   ```
   For each one used by the old workflow (typical names: `deployer`, `github-actions`, `moodle-deploy`), either:
   - rotate its token (recreate the SA-token Secret), or
   - delete it if you're confident nothing else uses it.
3. **In Artifactory:** revoke or scope down any robot accounts named `moodle-nginx-*`.

### Do NOT revoke

- Cluster-scoped operators (Crunchy Postgres, Sysdig agent, ingress)
- The `default` ServiceAccount — patched in Step 3, still needed
- Anything labeled `app.kubernetes.io/instance: moodle-nginx` or `app=moodle` — those are the live old workloads, and they need to keep running until cutover

---

## Step 6 — Verify the handover from a runner

From your laptop (or a clean GHA runner job), confirm the new credentials work:

```sh
oc login --server=https://api.silver.devops.gov.bc.ca:6443 --token="$OPENSHIFT_TOKEN_DEV"
oc whoami
# expected: system:serviceaccount:a58ce1-dev:psa-moodle-deploy

oc -n a58ce1-dev auth can-i create deployment
# expected: yes

oc -n a58ce1-dev auth can-i delete deployment -l app.kubernetes.io/instance=moodle-nginx
# expected: yes — but you won't actually run this until cutover
```

Same again with `OPENSHIFT_TOKEN_TEST` against `a58ce1-test`.

---

## Step 7 — Confirm the old repo can no longer deploy

This is the verification of Step 5. From a clean shell:

```sh
# Using the OLD moodle-nginx token (or attempting to run the old workflow):
oc login --server=https://api.silver.devops.gov.bc.ca:6443 --token="<OLD_TOKEN>"
# Expected: authentication error, OR the SA still exists but can't do anything useful.
```

If the old token still works, return to Step 5.

---

## Coexistence labels (important for the build phases)

Until cutover, both `psa-moodle` and `moodle-nginx` workloads live in the same namespaces. Every resource the new Helm chart creates **must** carry:

```yaml
metadata:
  labels:
    app.kubernetes.io/name: psa-moodle
    app.kubernetes.io/instance: psa-moodle
    app.kubernetes.io/part-of: psa-moodle
```

And selectors should match on `app.kubernetes.io/instance: psa-moodle`. Helm 3 does most of this automatically via `Chart.yaml`, but verify in Phase 3 when the chart goes in.

The old `moodle-nginx` resources carry `app: moodle` (no `app.kubernetes.io/*`), so the two will not collide.

---

## What does NOT happen in this phase

- No old workloads are stopped, scaled, or deleted
- No DNS changes
- No `Route` is created for the new system yet — that lands in Phase 3 with a deliberately distinct hostname (e.g. `psa-moodle-dev.apps.silver.devops.gov.bc.ca`)
- No data migration. The new system gets a clean Postgres and clean `moodledata` PVC; production data stays where it is until Phase 7 rehearsals + Phase 8 cutover

---

## Completion checklist

- [ ] `psa-moodle-deploy` SA exists in `a58ce1-dev` and `a58ce1-test`
- [ ] Token Secret created and exfiltrated to GitHub secrets
- [ ] Artifactory robot `psa-moodle-ci` created with correct scopes
- [ ] `artifactory-pull` Secret exists in each runtime namespace and is attached to `default` SA
- [ ] All eight GitHub repo secrets populated
- [ ] Old `moodle-nginx` credentials revoked or rotated
- [ ] `oc auth can-i` checks pass from the new token
- [ ] Old workloads still running unaffected (`oc -n a58ce1-dev get pods` looks the same as before)

Once all checked, Phase 0 namespace work is done and Phase 1 (local Podman dev environment) is unblocked.
