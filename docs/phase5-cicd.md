# Phase 5 — CI/CD via GitHub Actions

Three workflows automate everything Phase 2 and Phase 3 documented as manual:

| Workflow | Triggers | Job |
|---|---|---|
| [`lint.yml`](../.github/workflows/lint.yml) | PR + push to main | helm lint/template, shellcheck, yamllint |
| [`build.yml`](../.github/workflows/build.yml) | PR + push to main | Build both image variants; push to Artifactory on main only |
| [`deploy.yml`](../.github/workflows/deploy.yml) | After build on main → dev; `workflow_dispatch` → test | `helm upgrade --install`, idempotent Moodle CLI upgrade, smoke test |

Production is deliberately not a deploy target. `values-prod.yaml` does not exist yet — Phase 8 will add it behind a separate approval.

---

## Plugin and theme sources

Plugins and the bcgovpsa theme are cloned from GitHub at image build time inside `Containerfile.php`. No local checkout or committed copy is required — CI and local `make build` both pull the latest `main` branch of each repo:

| Component | GitHub repo |
|---|---|
| `block_course_search` | `bcgov/moodle-course-search` |
| `local_githubsync` | `PSA-Corporate-Learning-Branch/moodle-local_githubsync` |
| `local_psaelmsync` | `PSA-Corporate-Learning-Branch/psaelmsync` |
| `mod_pathcurator` | `itr8tech/pathcurator-moodle` |
| `mod_hvp` | `h5p/moodle-mod_hvp` |
| `theme_bcgovpsa` | `bcgov/bcgovpsa-moodle` |

To pin a plugin to a specific branch or tag, pass `--branch <ref>` on the corresponding `git clone` line in `Containerfile.php`.

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
| `build.yml` fails at `git clone` for a plugin repo | GitHub token lacks SSO authorization for `bcgov` org, or plugin repo is private | Re-authorize with `gh auth refresh -s read:org`, or confirm repo visibility |
| `build.yml` push step 401s on Artifactory | `ARTIFACTORY_PASSWORD` secret wrong/expired | Regenerate the robot token in Artifactory, update secret |
| `deploy.yml` fails at `oc login` | Token wrong, or SA rolebinding missing | Re-do Phase 0 Steps 1–4 for the target namespace |
| `Moodle CLI upgrade` step times out | The php Deployment didn't roll | Inspect `oc rollout status` output in the job logs; usually a Helm value problem |
| Smoke test fails but pods are Ready | Route timeout still 30s, or DNS not propagated | Compare `oc get route` output to `values-<env>.yaml route.host` |
| `test` deploy stuck "waiting for review" | Required reviewer not configured or not responding | Repo Settings → Environments → test → Required reviewers |

---

## Phase 5 acceptance criteria

- [ ] Plugin repos accessible from CI (public, or GitHub token authorized for the orgs)
- [ ] All eight GitHub secrets populated, two environments created
- [ ] PR triggers `lint.yml` + `build.yml` (no push) and both pass
- [ ] Merge to main pushes images to Artifactory and auto-deploys to `a58ce1-dev`
- [ ] Smoke test step passes against the dev Route
- [ ] `workflow_dispatch` with `environment=test` prompts for approval and then deploys
- [ ] Rollback to a prior image SHA works (test by re-dispatching with an older tag)

Once these are ticked, Phase 5 is done. Phase 4 (operational hardening — PDB/HPA/topology + refined NetworkPolicies + `auth_oidc`/CSS) is next; or Phase 6 (backups + the April-2026 backup-integrity fix) if you'd rather get the backup story right before adding more deployment surface.
