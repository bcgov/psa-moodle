# PSA Moodle

A replacement deployment of PSA Moodle for the BC Gov Private Cloud on
OpenShift Silver. This repository contains the container builds, local Podman
stack, Helm chart, deployment workflows, and operational scripts for the new
platform.

The application uses Moodle 4.5 with PostgreSQL, Valkey, nginx, and PHP-FPM.
Moodle, its plugins, and the PSA theme are packaged into container images;
shared storage holds Moodle data rather than application code. The design
replaces the legacy `bcgov/moodle-nginx` deployment's MariaDB Galera database,
shared application-code volume, and custom Redis proxy arrangement.

## Current direction

**The next step is to request a new Silver project set.** The `a58ce1` license
plate hosts the proof of concept; it is not the destination for the full
replacement. The new license plate has not yet been assigned.

| Project set | Role |
|---|---|
| `950003` | Existing Moodle deployment |
| `a58ce1` | Replacement proof of concept, deployed in `a58ce1-dev` |
| New license plate, pending | Intended home for the replacement's dev, test, prod, and tools namespaces |

Register the new project set first, then use the
[quota request](docs/quota-request.md) for the capacity adjustment. It contains
proposed totals, form responses, and allocation calculations. The accompanying
[evidence report](docs/quota-evidence.md) adds fresh inventories and fourteen days
of production and prototype metrics collected on 2026-10-26. The totals below
remain provisional pending agreement on the deployment and recovery scope.

| Namespace | Requested CPU (cores) | Requested memory (GiB) | Requested storage (GiB) |
|---|---:|---:|---:|
| Development | 6 | 32 | 256 |
| Test | 6 | 32 | 256 |
| Production | 6 | 32 | 256 |
| Tools | 0.5 | 2 | 1 |

These are proposed initial totals, with CPU and memory budgeted as pod requests.
Matching dev/test/prod ceilings allow the same topology, scaling, rollout, and
recovery exercises in each environment. They are not measured production
requirements, and some of the budgeted components still need implementation.

**Production cutover remains a separate, later decision.** Provisioning a new
project set does not mean the replacement is ready to take production traffic.

## What is implemented, and what remains

The proof of concept demonstrates Moodle running on Crunchy PostgreSQL in
Silver. The repository also contains multi-replica chart settings, network
policies, monitoring, autoscaling, and backup verification tooling. Those files
are not evidence that every feature has been deployed or validated.

| Area | Current implementation and remaining work |
|---|---|
| Application | Images include Moodle, five plugins, and the PSA theme. Plugin behaviour, SSO, and representative course workflows still need validation. |
| Database | Crunchy PostgreSQL with pgBackRest. The chart supports three instances; the PoC uses one. Migration from the existing database, sizing, and failover need rehearsal. |
| Sessions and cache | Authenticated Valkey in OpenShift, currently a single replica. HA and session survival during failover remain to be implemented and tested. |
| Moodle tasks | A single long-running cron Deployment loops `cron.php` with a 60-second interval. The chart retains a CronJob option. |
| Backup and recovery | Database backup configuration and integrity/restore jobs exist. Moodle file backups, a secondary database backup destination, and a complete recovery drill remain outstanding. Moodle data snapshots are disabled. |
| Monitoring | Exporters, monitoring resources, and alert rules are in the chart; monitoring is disabled in the PoC profile. Alert routing and operational validation remain. |
| Delivery | GitHub Actions workflows exist for builds, deployment, and scheduled rebuilds. Registry provisioning and deployment credentials are outstanding in the recorded plan. There is no production values file or production deployment workflow path. |

The [quota request](docs/quota-request.md) defines the new environment's planning
assumptions and implementation boundaries. The [next steps](docs/next-steps.md)
and [platform alignment review](docs/bcgov-alignment-review.md) provide further
operational context; their older namespace-specific instructions need adapting
to the new project set.

## Preparing the new project set

The current configuration still contains `a58ce1` registry paths, namespace
examples, and PoC route names. The existing dev profile also uses fewer replicas
than test, so it does not yet implement the new plan for matching HA topology.

Once the new license plate is assigned:

1. Confirm the provisioned quotas, storage-class allowances, and operator access
   against the [initial quota request](docs/quota-request.md).
2. Configure the image registry and build credentials for the new project.
   Update registry paths in the Makefile, chart values, Compose registry
   overrides, and GitHub Actions workflows.
3. Prepare environment values, routes, SSO clients, alert recipients, and
   deployment secrets for the new namespaces. Reconcile the existing dev/test
   profiles with the proposed topology and resource budget.
4. Validate a clean installation, then exercise scaling, failover, backups, and
   complete recovery with representative data before planning cutover.

The [PoC deploy runbook](docs/poc-deploy-runbook.md) records how the demonstration
was deployed. Treat its internal-registry settings and `a58ce1-dev` commands as
PoC-specific instructions, not as the new environment's deployment defaults.

## Local development

Use GNU Make and a running Podman installation with `podman compose` available.
Builds need network access to fetch base images, Moodle, plugins, and the theme.
If using standalone `podman-compose`, pass `COMPOSE=podman-compose` to Make.

From the repository root:

```sh
make build
make up
make ps

# Once the database and PHP service are healthy, initialize a fresh database.
make install
```

Open <http://localhost:8080>. The default local login is `admin` with password
`Admin-1234!`; these are development credentials. The installer accepts
`ADMIN_USER`, `ADMIN_PASS`, and `ADMIN_EMAIL` overrides.

Builds default to `linux/amd64` to match OpenShift. For native local builds on
Apple Silicon, use `make build PLATFORM=linux/arm64`.

The local stack runs PostgreSQL 15, Valkey 7.2, PHP-FPM, nginx, and the cron
runner. Database and Valkey volumes persist between runs; Moodle files live in
the ignored `moodledata/` bind mount.

| Command | Purpose |
|---|---|
| `make help` | List available targets |
| `make up` / `make down` | Start or stop the stack while retaining data |
| `make logs` / `make ps` | Inspect logs or service state |
| `make shell-php` | Open a shell in the PHP container |
| `make psql` / `make valkey` | Open the local database or cache CLI |
| `make purge-cache` | Purge Moodle caches |
| `make upgrade` | Run Moodle's CLI database upgrade after updating the application images |
| `make chart-check` | Lint and render the dev/test Helm profiles locally; requires Helm |
| `make clean` | **Delete local database/cache volumes and `moodledata/`** |

## Images and application updates

[Containerfile.php](Containerfile.php) fetches Moodle from `MOODLE_405_STABLE`
and assembles the application tree. The web and cron builds copy that tree so
all three images share the same application code. The build includes
`block_course_search`, `local_githubsync`, `local_psaelmsync`, `mod_pathcurator`,
`mod_hvp`, and `theme_bcgovpsa`.

Local and OpenShift builds use separate configuration variants under
[config/moodle](config/moodle/). Use `MOODLE_CONFIG_VARIANT=openshift` for cluster
images. Normal builds fetch upstream branches, so rebuilding may also change
Moodle, plugin, or theme code.

The PHP-FPM and cron Containerfiles currently pin PHP to `8.3.36`. Update both
pins together when changing the runtime. A rebuild does not advance an explicit
version pin, and changing a Containerfile does not update running containers.
For local updates:

```sh
make build
podman compose up -d --force-recreate php web cron
podman compose exec -T php php -v
podman compose exec -T cron php -v
```

For a runtime-only patch that must preserve deployed application code and
configuration, [Containerfile.runtime-patch](Containerfile.runtime-patch) accepts
`DEPLOYED_IMAGE` and `RUNTIME_IMAGE`. Build separate PHP and cron patch images
from the appropriate updated runtimes, use the deployed PHP image's digest as
the application source, and verify code hashes, extensions, and startup before
rollout. Normal releases should promote tested image tags through environments.

## Repository guide

| Location | Contents |
|---|---|
| [Makefile](Makefile) and [compose.yaml](compose.yaml) | Local build and development commands |
| `Containerfile.*` | PHP, web, cron, operations, and runtime-patch image builds |
| [config/](config/) | Moodle, nginx, PHP, and Valkey configuration |
| [chart/psa-moodle/](chart/psa-moodle/) | Helm templates and default, dev, test, and PoC values |
| [.github/workflows/](.github/workflows/) | Build, lint, deploy, and scheduled rebuild workflows |
| [scripts/ops/](scripts/ops/) | Backup integrity, restore rehearsal, snapshot, and alert scripts |
| [docs/](docs/) | Planning documents, reviews, and operational runbooks |

Start with the [quota request](docs/quota-request.md) for the new project set.
For implementation details, see the [image build guide](docs/phase2-images.md),
[Helm deployment guide](docs/phase3-deploy.md),
[hardening notes](docs/phase4-hardening.md),
[CI/CD guide](docs/phase5-cicd.md), and
[backup tooling guide](docs/phase6-backups.md). These guides record earlier
implementation work and may retain PoC settings; check the current chart and
new project plan before applying their commands.

The original architecture and incident assessments are separate background
working documents, not dependencies of this repository. This README summarizes
the design rationale and links only to documentation and source files included
in the checkout.
