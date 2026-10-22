# psa-moodle

PSA Moodle on BC Gov Private Cloud (OpenShift Silver, license plate `a58ce1`).

A from-scratch re-platform of `bcgov/moodle-nginx`, deliberately removing the three architectural choices flagged in the [April 2026 assessment](../moodle-openshift-architecture-assessment-2026-04-12.md):

- ❌ MariaDB Galera multi-master &nbsp;→&nbsp; ✅ Crunchy Postgres for Kubernetes
- ❌ Shared RWX application code &nbsp;→&nbsp; ✅ immutable images, code baked in
- ❌ Custom Redis Sentinel proxy &nbsp;→&nbsp; ✅ Valkey (Linux Foundation Redis fork)

Production cutover is **out of scope** for the current iteration — we are building dev/test in `a58ce1-dev` and `a58ce1-test` first.

---

## Status

| Phase | Description | State |
|---|---|---|
| 0 | Namespace handover docs + discovery template | ✅ done — see [`docs/namespace-handover.md`](docs/namespace-handover.md) and [`docs/discovery-inventory.md`](docs/discovery-inventory.md) |
| 1 | Local Podman development environment | ✅ this README |
| 2 | Container images + Artifactory registry | ✅ done — see [`docs/phase2-images.md`](docs/phase2-images.md) (`make push`, `make smoke-registry`) |
| 3 | Helm chart + first OpenShift deploy | ✅ done — see [`docs/phase3-deploy.md`](docs/phase3-deploy.md); chart at `chart/psa-moodle/` |
| 4 | Operational hardening (PDB, HPA, topology spread, egress NetPol) | ✅ done — see [`docs/phase4-hardening.md`](docs/phase4-hardening.md); route timeout was already raised in Phase 3 |
| 5 | CI/CD (GitHub Actions → Helm) | ✅ done — see [`docs/phase5-cicd.md`](docs/phase5-cicd.md) |
| 6 | Backups, DR, backup-integrity fix (Warren's April incident) | ✅ done — see [`docs/phase6-backups.md`](docs/phase6-backups.md) |
| 7 | Data migration rehearsal (greenfield → realistic) | pending |
| 8 | Production go-live | gated — separate approval |

---

## Local development

### Prerequisites

- **Podman** ≥ 4.x with `podman compose` available, OR `podman-compose` installed separately. (Docker also works if you alias the commands, but Podman is the supported path here.)
- ~3 GB free disk for images + DB volume.

### First-time setup

```sh
make build          # builds psa-moodle-php (clones plugins + theme from GitHub), then web and cron
make up             # starts db (Postgres 15), cache (Valkey 7.2), php, web, cron
make install        # one-time: runs Moodle CLI installer against the running DB
```

Browse to <http://localhost:8080> — admin / `Admin-1234!`.

### Day-to-day

| Command | Purpose |
|---|---|
| `make up` | start the stack |
| `make down` | stop, keep volumes (DB + moodledata persist) |
| `make logs` | tail all service logs |
| `make ps` | list services and health |
| `make psql` | open a `psql` shell on the local Postgres |
| `make valkey` | open `valkey-cli` against the cache |
| `make shell-php` | bash into the php container |
| `make purge-cache` | run Moodle's CLI cache purge |
| `make upgrade` | run Moodle's CLI upgrade (after rebuilding the image) |
| `make clean` | **destructive** — `down -v` and delete `moodledata/` |

### What lives where

```
psa-moodle/
├── compose.yaml              # Podman compose stack (db, cache, php, web, cron)
├── Containerfile.php         # PHP-FPM 8.3.36 + Moodle source-of-truth
├── Containerfile.web         # nginx-unprivileged, code copied from php image
├── Containerfile.cron        # php-cli, code copied from php image
├── Makefile                  # canonical dev entrypoints
├── config/
│   ├── moodle/
│   │   ├── config.local.php       # baked into image when MOODLE_CONFIG_VARIANT=local
│   │   └── config.openshift.php   # baked when MOODLE_CONFIG_VARIANT=openshift
│   ├── nginx/default.conf
│   ├── php/{php.ini,php-fpm.conf}
│   └── valkey/valkey.conf
├── moodledata/               # GITIGNORED — local bind mount for Moodle's data dir
└── docs/                     # phase 0 deliverables
```

### PHP security updates

Both PHP-FPM and the CLI cron image are pinned to **PHP 8.3.36**, released on
**October 21, 2026**, to address PHP2Shell (CVE-2026-109618 and CVE-2026-109619).
See the [PHP security advisory](https://www.php.net/index.php) and
[8.3.36 release announcement](https://www.php.net/releases/8_3_36.php).
PHP 8.3 is the newest branch supported by this project's Moodle 4.5 release;
see [Moodle's PHP compatibility policy](https://moodledev.io/general/development/policies/php).

Update the version pins in `Containerfile.php` and `Containerfile.cron` together
for subsequent releases. Weekly rebuilds refresh the pinned images but do not
advance these PHP version pins. Rebuild all application images and recreate the
local containers to apply an update:

```sh
make build
podman compose up -d --force-recreate php web cron
podman compose exec -T php php -v
podman compose exec -T cron php -v
```

For OpenShift, build and publish a new image tag through the existing CI/CD
pipeline, deploy that tag, and verify PHP versions in both the PHP workload and
cron workload. Updating these files alone does not patch running containers.

For an urgent runtime-only update, `Containerfile.runtime-patch` can retain the
deployed application's files, including its environment-specific `config.php`.
Build the normal PHP and cron images first, then build a patch image for each:

```sh
podman build --platform=linux/amd64 \
  --build-arg DEPLOYED_IMAGE="$DEPLOYED_PHP_IMAGE" \
  --build-arg RUNTIME_IMAGE="$UPDATED_RUNTIME_IMAGE" \
  -f Containerfile.runtime-patch \
  -t "$PATCH_IMAGE" .
```

Use the deployed PHP image's digest for `DEPLOYED_PHP_IMAGE`. Set
`UPDATED_RUNTIME_IMAGE` to the newly built PHP or cron image, respectively, and
give each resulting `PATCH_IMAGE` a new release tag. The web image can retain its
existing contents because the Moodle source is unchanged. Verify application
file hashes, PHP versions, required extensions, and native FPM startup before
rolling out the patch. This path does not advance Moodle or require a Moodle
database upgrade.

### Plugin set (built into the image)

| Component | Source | Notes |
|---|---|---|
| `block_course_search` | [bcgov/moodle-course-search](https://github.com/bcgov/moodle-course-search) | cloned at build time |
| `local_githubsync` | [PSA-Corporate-Learning-Branch/moodle-local_githubsync](https://github.com/PSA-Corporate-Learning-Branch/moodle-local_githubsync) | cloned at build time |
| `local_psaelmsync` | [PSA-Corporate-Learning-Branch/psaelmsync](https://github.com/PSA-Corporate-Learning-Branch/psaelmsync) | cloned at build time |
| `mod_pathcurator` | [itr8tech/pathcurator-moodle](https://github.com/itr8tech/pathcurator-moodle) | cloned at build time |
| `mod_hvp` | [h5p/moodle-mod_hvp](https://github.com/h5p/moodle-mod_hvp) | upstream is unmaintained against 4.x — migration to core `mod_h5pactivity` is on the cutover decision list |
| `theme_bcgovpsa` | [bcgov/bcgovpsa-moodle](https://github.com/bcgov/bcgovpsa-moodle) | child theme, parent is core `boost` |

SSO is configured at runtime through Moodle core's OAuth2 support (`admin/tool/oauth2/issuers.php` + the core `auth_oauth2` plugin) — no third-party OIDC plugin is baked into the image. Phase 4 adds the egress NetworkPolicy allows so the OAuth2 flow can reach the IdP.

---

## Architecture (target, dev/test)

```
┌───────────────────────────────────────────────────────────────────────────┐
│  OpenShift Route (TLS, raised timeout)                                    │
│           │                                                               │
│           ▼                                                               │
│  ┌─────────────┐   PHP-FPM   ┌─────────────┐                              │
│  │  web (nginx)│ ──────────► │  php (fpm)  │                              │
│  │  immutable  │             │  immutable  │                              │
│  └─────────────┘             └──────┬──────┘                              │
│                                     │                                     │
│                              ┌──────┼──────┐                              │
│                              ▼      ▼      ▼                              │
│                          ┌──────┐ ┌────┐ ┌────────────────┐               │
│                          │valkey│ │ pg │ │ moodledata RWX │               │
│                          │(LF)  │ │HA  │ │ netapp-file-   │               │
│                          │      │ │    │ │ standard       │               │
│                          └──────┘ └────┘ └────────────────┘               │
│                                     ▲                                     │
│                                     │ pgBackRest → in-cluster PVC repo    │
│                              ┌──────┴──────┐                              │
│                              │ backup +    │                              │
│                              │ integrity   │                              │
│                              │ verify Cron │                              │
│                              └─────────────┘                              │
│                                                                           │
│  cron: Kubernetes CronJob (1 min, isolated pod per tick)                  │
└───────────────────────────────────────────────────────────────────────────┘
```

---

## Reference

- [Architecture assessment, 2026-04-12](../moodle-openshift-architecture-assessment-2026-04-12.md)
- [Restore/storage assessment, 2026-04-12](../moodle-openshift-restore-storage-assessment-2026-04-12.md)
- [Warren's April work review, 2026-05-16](../moodle-warren-april-review-2026-05-16.md) — drives the Phase 6 backup-integrity work
- [Original repo: `bcgov/moodle-nginx`](../moodle-nginx) — reference only; not deployed from
