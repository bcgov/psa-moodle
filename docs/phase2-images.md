# Phase 2 — Container images & registry

Phase 1 produced working images for local Podman dev. Phase 2's job is the bridge to OpenShift:

1. Confirm the images are OpenShift-safe (non-root, arbitrary UID, group 0 writes).
2. Build the two configuration variants (`local` for Podman, `openshift` for Helm) and tag both.
3. Push to Artifactory under `a58ce1-tools/psa-moodle/`.
4. **Pull them back and smoke-test the registry artifacts via Podman** before we trust them on cluster.
5. Decide on SBOMs and image signing.

This phase has no CI dependency — everything is manual. Phase 5 automates all of it.

---

## 1. Image hardening — already in place

The Phase 1 Containerfiles satisfy OpenShift's restricted-v2 SCC out of the box. Notable choices:

| Pattern | Where | Why |
|---|---|---|
| `USER www-data` (PHP/cron) and `USER 101` (web) | end of each runtime Containerfile | runs non-root locally; SCC reassigns UID on cluster |
| `chown -R <user>:0 /var/www/html /var/www/moodledata /var/local-cache` | runtime stages | group 0 has rwx; OpenShift assigns reassigned UID to group 0 |
| `chmod -R g+rwX` on writable paths | runtime stages | reassigned UID can still write through group 0 |
| no `runAsUser` / no `fsGroup` in the chart | `chart/psa-moodle/values.yaml`, deployment templates | let SCC pick |
| multi-stage build, code only `COPY --from=src` | `Containerfile.php` (and `.web`/`.cron` reference `psa-moodle-php` as `src`) | clones happen once per build cycle, runtime image stays lean |
| `nginxinc/nginx-unprivileged` (not `nginx`) | `Containerfile.web` | listens on 8080 as UID 101 — no root required, no `setcap` |
| `php-fpm-healthcheck` baked in | `Containerfile.php` | drives liveness/readiness probes via the FPM status endpoint |
| `allowPrivilegeEscalation: false`, `capabilities: drop: [ALL]` | chart templates | matches SCC defaults |

If any of these break under restricted-v2 on first deploy, the fix is one-line in the Containerfile, not architectural.

---

## 2. Build both config variants and tag for Artifactory

The image source is identical between local and OpenShift; only `config/moodle/config.<variant>.php` differs (compose-aware env vars vs. Helm-aware env vars). Build both:

```sh
cd /Users/ahaggett/Moodle/psa-moodle

VERSION=v0.1.0-dev1
REGISTRY=artifacts.developer.gov.bc.ca
REPO=$REGISTRY/a58ce1-tools/psa-moodle

# Sync plugins into the build context (idempotent).
make sync-plugins

# --- LOCAL variant: tagged "<version>-local" -----------------------------------
make build MOODLE_CONFIG_VARIANT=local TAG=$VERSION-local
for c in php web cron; do
  podman tag localhost/psa-moodle-$c:$VERSION-local $REPO/$c:$VERSION-local
done

# --- OPENSHIFT variant: tagged "<version>" (no suffix) -------------------------
make build MOODLE_CONFIG_VARIANT=openshift TAG=$VERSION
for c in php web cron; do
  podman tag localhost/psa-moodle-$c:$VERSION $REPO/$c:$VERSION
done
```

Tagging convention:

| Tag | Config baked in | Used by |
|---|---|---|
| `<version>-local` | `config.local.php` (compose env vars) | Phase 2 smoke test, ad-hoc local pull-and-run |
| `<version>` | `config.openshift.php` (Helm env vars) | Phase 3 OpenShift deploy |

---

## 3. Push to Artifactory

Log in once per session with the robot account from Phase 0 (`docs/namespace-handover.md` Step 2):

```sh
podman login $REGISTRY \
  -u 'a58ce1+psa-moodle-ci' \
  -p '<paste-robot-token>'
```

Push both variants:

```sh
for c in php web cron; do
  podman push $REPO/$c:$VERSION-local
  podman push $REPO/$c:$VERSION
done
```

If pushes 404, the Artifactory repository path `a58ce1-tools/psa-moodle` may need to be created in the UI first.

---

## 4. Smoke test — pull from Artifactory and run via compose

This is the Phase 2 acceptance criterion: **a registry-pulled image runs locally with the same compose stack as Phase 1.** Equivalent to "would the OpenShift node pull and start this?" — proven on your laptop before you trust it on cluster.

```sh
# Force a clean pull by deleting the local builds.
podman rmi -f \
  localhost/psa-moodle-php:$VERSION-local \
  localhost/psa-moodle-web:$VERSION-local \
  localhost/psa-moodle-cron:$VERSION-local || true

# Run via compose with the registry overlay.
TAG=$VERSION-local make smoke-registry
```

What `make smoke-registry` does:

1. `podman compose -f compose.yaml -f compose.registry.yaml pull` — pulls the registry-tagged images
2. `podman compose -f compose.yaml -f compose.registry.yaml up -d`
3. waits for healthchecks
4. runs `make install` against the running stack
5. curls `http://localhost:8080/health` and the Moodle login page

Expected: same outcome as Phase 1 `make up && make install` — login page renders with the `bcgovpsa` theme, admin login works.

Tear down with `make down`.

---

## 5. SBOMs and image signing — decision

**Recommendation: defer to Phase 5.**

There is no current BC Gov policy I'm aware of that mandates either for application workloads on Silver. Phase 5 (CI on GitHub Actions) is the cheapest place to add them because:

- **Syft** (Anchore) generates an SPDX SBOM from a built image in one step — natural fit as a GHA step after `buildah build`.
- **Cosign** (Sigstore) signs the image; keyless mode via Fulcio works inside GHA's OIDC token, no key management.
- Both produce artifacts that ride alongside the image tag in Artifactory.

Doing them now, manually, gives no real protection (no consumer is verifying them) and costs setup time. Phase 5 will:

1. Add `syft scan` after the buildah build step and publish the SBOM as a `.spdx.json` to Artifactory next to the image.
2. Add `cosign sign --keyless` via GHA's OIDC identity.
3. Optional: add a Kyverno or admission-controller policy to require signatures at deploy time, if BC Gov platform-services confirms support.

If a security review escalates this between now and Phase 5, the override is straightforward — add `syft` and `cosign` to the `make build` and `make push` flow in `Makefile` and re-run.

**For Phase 2: nothing else to do here. The decision is logged.**

---

## Phase 2 acceptance criteria

- [ ] Both image variants build cleanly with `make build` (variants `local` and `openshift`)
- [ ] All six tags (`php`, `web`, `cron` × `<version>-local`, `<version>`) push to `a58ce1-tools/psa-moodle/` without errors
- [ ] `make smoke-registry` brings up a working Moodle install using **only** the registry-pulled `<version>-local` images
- [ ] `make down` cleans up
- [ ] SBOM/signing decision documented (this file is the artifact)

Phase 2 is done when these are ticked. Phase 3 (OpenShift deploy) consumes the `<version>` (no-suffix) tags via Helm.
