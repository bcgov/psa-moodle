# Phase 5 — CI/CD via GitHub Actions

Three workflows automate everything Phase 2 and Phase 3 documented as manual:

| Workflow | Triggers | Job |
|---|---|---|
| [`lint.yml`](../.github/workflows/lint.yml) | PR + push to main | helm lint/template, shellcheck, yamllint |
| [`build.yml`](../.github/workflows/build.yml) | PR + push to main | Build both image variants; push to Artifactory on main only |
| [`deploy.yml`](../.github/workflows/deploy.yml) | After build on main → dev; `workflow_dispatch` → test | `helm upgrade --install`, idempotent Moodle CLI upgrade, smoke test |

Production is deliberately not a deploy target. `values-prod.yaml` does not exist yet — Phase 8 will add it behind a separate approval.

---

## Step 0 — One-time: commit plugins and theme into the repo

Until now plugins lived only in `../moodle-dev/` and `make sync-plugins` copied them into the gitignored `plugins/` directory. CI can't reach `../moodle-dev` so the plugin source-of-truth has to move into this repo.

You have two options:

### Option A — Flat copy (simpler, recommended for now)

```sh
make sync-plugins
git add plugins themes
git commit -m "Phase 5: bring plugins and theme into the repo for CI builds"
```

The committed copy becomes the canonical source. `make sync-plugins` still works locally for grabbing fresh changes from `../moodle-dev`, but CI ignores that path entirely.

### Option B — Git subtree (preserves upstream history; better for ongoing plugin development)

Per plugin:

```sh
git subtree add --prefix=plugins/blocks/course_search \
  ../moodle-dev/plugins/course_search HEAD --squash
git subtree add --prefix=plugins/local/githubsync \
  ../moodle-dev/plugins/githubsync HEAD --squash
git subtree add --prefix=plugins/local/psaelmsync \
  ../moodle-dev/plugins/psaelmsync HEAD --squash
git subtree add --prefix=plugins/mod/pathcurator \
  ../moodle-dev/plugins/pathcurator HEAD --squash
git subtree add --prefix=themes/bcgovpsa \
  ../moodle-dev/themes/bcgovpsa HEAD --squash
```

Then later: `git subtree pull --prefix=plugins/blocks/course_search ../moodle-dev/plugins/course_search HEAD --squash`.

Either option leaves the CI workflow unchanged — both end with `plugins/` and `themes/` committed in this repo. `.gitignore` no longer excludes them as of Phase 5.

---

## Secrets and variables — populated in Phase 0

The deploy workflow expects everything you already configured in [`namespace-handover.md`](namespace-handover.md) Step 4. Quick reference:

**Repository Secrets** (Settings → Secrets and variables → Actions):

| Name | Source |
|---|---|
| `OPENSHIFT_SERVER` | `https://api.silver.devops.gov.bc.ca:6443` |
| `OPENSHIFT_TOKEN_DEV` | SA token from `a58ce1-dev` |
| `OPENSHIFT_TOKEN_TEST` | SA token from `a58ce1-test` |
| `OPENSHIFT_NAMESPACE_DEV` | `a58ce1-dev` |
| `OPENSHIFT_NAMESPACE_TEST` | `a58ce1-test` |
| `ARTIFACTORY_USERNAME` | `a58ce1+psa-moodle-ci` |
| `ARTIFACTORY_PASSWORD` | Artifactory robot token |

No notification integration is wired in. Watch the Actions tab, or wire a notifier in a follow-up — BC Gov no longer runs Rocket.Chat, so any channel choice (Teams, email, webhook to a custom listener) is a fresh decision.

---

## GitHub Environments — gating the test promotion

Create two environments under repo Settings → Environments:

### `dev`

- No restrictions
- No reviewers
- Used by the auto-deploy job that fires after every `main` build

### `test`

- **Required reviewers:** at least one person (probably you, the user, plus a teammate)
- Optional: deployment branches restricted to `main`
- Used by the manual-dispatch promotion path

When a teammate triggers `deploy.yml` with `environment=test`, the workflow pauses at the deploy job until a required reviewer approves it in the GitHub UI. This is the only release gate between us and production until Phase 8 adds prod.

---

## Branch model and deploy flow

```
              PR opened             PR merged to main
   ┌─────────┐    ▼       ┌────────┐     ▼      ┌─────────┐
   │ feature │──── lint ──│  main  │──── lint ──│  main   │
   │ branch  │    build   │ (HEAD) │    build   │ (HEAD)  │
   └─────────┘     ▲      └────────┘     ▼      └─────────┘
                  PR                  push img       ▼
                  builds              <sha>          deploy
                  only                <sha>-local    a58ce1-dev (auto)
                                                     ▼
                                           workflow_dispatch
                                                     ▼
                                              deploy a58ce1-test
                                              (approval gated)
```

On every PR: lint + build (no push). Failures block the merge.

On every merge to main: lint + build + push (image tag = 7-char git SHA) + auto-deploy to `a58ce1-dev`.

Test promotion is opt-in via workflow_dispatch. Pick any image tag (defaults to latest main SHA) and target environment.

---

## Rollback procedure

Two rollback paths depending on what's wrong.

### Image-level rollback (most common — deploy succeeded but new code is broken)

Re-trigger `deploy.yml` via workflow_dispatch with `image_tag=<previous-good-sha>`. Helm rolls back to the older image in ~2 min.

### Helm-level rollback (chart-template change broke something)

```sh
oc login --server="$OPENSHIFT_SERVER" --token="$OPENSHIFT_TOKEN_DEV"
helm -n a58ce1-dev history psa-moodle
helm -n a58ce1-dev rollback psa-moodle <revision>
```

Helm preserves the last 10 revisions by default — that's the rollback window.

### Database rollback (rarely safe)

Don't. If a Moodle schema upgrade went bad, restore from pgBackRest (see Phase 6 once it exists). Running `upgrade.php` is one-way; rolling code back without rolling the schema back leaves you with code that doesn't match the DB.

---

## What CI does NOT automate (by design)

- **Moodle major-version upgrades** (e.g. 4.5 → 4.6). These need maintenance mode and a backup-first runbook — the post-deploy `php admin/cli/upgrade.php` step handles point releases idempotently, but anything that changes `lib/upgrade.txt` major bumps should be operator-driven.
- **Production deploys.** No `values-prod.yaml`, no `production` environment, no prod token in secrets. Deliberate — Phase 8.
- **PR preview environments.** Plan left this optional; defer until Phase 6 is solid.
- **DB schema migrations beyond Moodle's own `upgrade.php`.** Any out-of-band DB change should go through a PR with a documented migration runbook.

---

## Common first-run issues

| Symptom | Cause | Fix |
|---|---|---|
| `build.yml` fails at `make build` with "no such file or directory: plugins/blocks/course_search" | Step 0 not done — plugins still gitignored | Do Step 0 above |
| `build.yml` push step 401s on Artifactory | `ARTIFACTORY_PASSWORD` secret wrong/expired | Regenerate the robot token in Artifactory, update secret |
| `deploy.yml` fails at `oc login` | Token wrong, or SA rolebinding missing | Re-do Phase 0 Steps 1–4 for the target namespace |
| `Moodle CLI upgrade` step times out | The php Deployment didn't roll | Inspect `oc rollout status` output in the job logs; usually a Helm value problem |
| Smoke test fails but pods are Ready | Route timeout still 30s, or DNS not propagated | Compare `oc get route` output to `values-<env>.yaml route.host` |
| `test` deploy stuck "waiting for review" | Required reviewer not configured or not responding | Repo Settings → Environments → test → Required reviewers |

---

## Phase 5 acceptance criteria

- [ ] Plugins + theme committed (Step 0 above)
- [ ] All eight GitHub secrets populated, two environments created
- [ ] PR triggers `lint.yml` + `build.yml` (no push) and both pass
- [ ] Merge to main pushes images to Artifactory and auto-deploys to `a58ce1-dev`
- [ ] Smoke test step passes against the dev Route
- [ ] `workflow_dispatch` with `environment=test` prompts for approval and then deploys
- [ ] Rollback to a prior image SHA works (test by re-dispatching with an older tag)

Once these are ticked, Phase 5 is done. Phase 4 (operational hardening — PDB/HPA/topology + refined NetworkPolicies + `auth_oidc`/CSS) is next; or Phase 6 (backups + the April-2026 backup-integrity fix) if you'd rather get the backup story right before adding more deployment surface.
