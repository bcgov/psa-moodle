# psa-moodle — local development orchestration (Podman).
#
# Typical first-run sequence on a fresh checkout:
#   make build          # build php (clones plugins from GitHub), then web, cron, ops
#   make up             # start db, cache, php, web, cron
#   make install        # one-time: run Moodle CLI installer against the running DB
# Then browse to http://localhost:8080
#
# Variables overridable on the command line, e.g. `make build MOODLE_BRANCH=MOODLE_404_STABLE`.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# Tools
PODMAN        ?= podman
COMPOSE       ?= podman compose
PROJECT_NAME  ?= psa-moodle

# Build args
MOODLE_BRANCH         ?= MOODLE_405_STABLE
HVP_BRANCH            ?= master
MOODLE_CONFIG_VARIANT ?= local

# Image tags (local-only; OpenShift retags via CI)
TAG ?= dev
PHP_IMAGE  := localhost/psa-moodle-php:$(TAG)
WEB_IMAGE  := localhost/psa-moodle-web:$(TAG)
CRON_IMAGE := localhost/psa-moodle-cron:$(TAG)
OPS_IMAGE  := localhost/psa-moodle-ops:$(TAG)

# Admin user for `make install`
ADMIN_USER     ?= admin
ADMIN_PASS     ?= Admin-1234!
ADMIN_EMAIL    ?= admin@example.com
SITE_SHORTNAME ?= PSA
SITE_FULLNAME  ?= PSA Moodle (local)

## help: list targets
.PHONY: help
help:
	@awk 'BEGIN{printf "Targets:\n"} /^## [a-zA-Z0-9_.-]+:/ {sub(/^## /,""); split($$0,a,": "); printf "  %-16s %s\n", a[1], a[2]}' $(MAKEFILE_LIST)

## prep: create local bind-mount dirs with permissions the container can write
.PHONY: prep
prep:
	@mkdir -p moodledata
	@chmod 0777 moodledata

## build: build php (source-of-truth), then web/cron from php, plus the ops image
.PHONY: build build-php build-web build-cron build-ops
build: build-php build-web build-cron build-ops
build-php:
	$(PODMAN) build \
	  --build-arg MOODLE_BRANCH=$(MOODLE_BRANCH) \
	  --build-arg HVP_BRANCH=$(HVP_BRANCH) \
	  --build-arg MOODLE_CONFIG_VARIANT=$(MOODLE_CONFIG_VARIANT) \
	  -f Containerfile.php -t $(PHP_IMAGE) .
build-web: build-php
	$(PODMAN) build --build-arg PHP_IMAGE=$(PHP_IMAGE) -f Containerfile.web -t $(WEB_IMAGE) .
build-cron: build-php
	$(PODMAN) build --build-arg PHP_IMAGE=$(PHP_IMAGE) -f Containerfile.cron -t $(CRON_IMAGE) .
build-ops:
	$(PODMAN) build -f Containerfile.ops -t $(OPS_IMAGE) .

## up: start the compose stack
.PHONY: up
up: prep
	$(COMPOSE) up -d
	@echo
	@echo "Stack starting. Tail with: make logs"
	@echo "If this is a fresh DB, run: make install"

## down: stop the compose stack (keeps volumes)
.PHONY: down
down:
	$(COMPOSE) down

## clean: stop and remove volumes (DESTRUCTIVE — wipes local DB + moodledata)
.PHONY: clean
clean:
	$(COMPOSE) down -v
	rm -rf moodledata

## push: tag and push both image variants to Artifactory (Phase 2 — manual until CI lands)
##   Required env: VERSION=vX.Y.Z-dev1
##   Required: `podman login artifacts.developer.gov.bc.ca` already done
REGISTRY ?= artifacts.developer.gov.bc.ca
REPO     ?= $(REGISTRY)/a58ce1-tools/psa-moodle
.PHONY: push
push:
	@[ -n "$(VERSION)" ] || (echo "set VERSION, e.g. make push VERSION=v0.1.0-dev1" && exit 1)
	@echo "Building + tagging LOCAL variant: $(VERSION)-local"
	# Local variant: just the app images. Ops is config-agnostic; skip rebuilding it here.
	$(MAKE) build-php build-web build-cron MOODLE_CONFIG_VARIANT=local TAG=$(VERSION)-local
	for c in php web cron; do \
	  $(PODMAN) tag localhost/psa-moodle-$$c:$(VERSION)-local $(REPO)/$$c:$(VERSION)-local ; \
	  $(PODMAN) push $(REPO)/$$c:$(VERSION)-local ; \
	done
	@echo "Building + tagging OPENSHIFT variant: $(VERSION) (incl. ops, built once)"
	$(MAKE) build MOODLE_CONFIG_VARIANT=openshift TAG=$(VERSION)
	for c in php web cron ops; do \
	  $(PODMAN) tag localhost/psa-moodle-$$c:$(VERSION) $(REPO)/$$c:$(VERSION) ; \
	  $(PODMAN) push $(REPO)/$$c:$(VERSION) ; \
	done
	@echo "Done. Smoke-test with: TAG=$(VERSION)-local make smoke-registry"

## smoke-registry: Phase 2 acceptance — run the stack from registry-pulled images
##   Required env: TAG=<version>-local  (matches a tag pushed by `make push`)
.PHONY: smoke-registry
smoke-registry: prep
	@[ -n "$(TAG)" ] || (echo "set TAG, e.g. TAG=v0.1.0-dev1-local make smoke-registry" && exit 1)
	@echo "Pulling registry images for TAG=$(TAG)"
	TAG=$(TAG) $(COMPOSE) -f compose.yaml -f compose.registry.yaml pull
	@echo "Bringing up the stack from pulled images"
	TAG=$(TAG) $(COMPOSE) -f compose.yaml -f compose.registry.yaml up -d
	@echo "Waiting 30s for healthchecks..."
	@sleep 30
	TAG=$(TAG) $(COMPOSE) -f compose.yaml -f compose.registry.yaml ps
	@echo
	@echo "Run 'make install' next, then browse http://localhost:8080"
	@echo "Tear down with: TAG=$(TAG) $(COMPOSE) -f compose.yaml -f compose.registry.yaml down"

## install: run Moodle CLI install against the running DB (one-time per fresh DB)
.PHONY: install
install:
	$(COMPOSE) exec -T php php /var/www/html/admin/cli/install_database.php \
	  --agree-license \
	  --adminuser=$(ADMIN_USER) \
	  --adminpass='$(ADMIN_PASS)' \
	  --adminemail=$(ADMIN_EMAIL) \
	  --shortname='$(SITE_SHORTNAME)' \
	  --fullname='$(SITE_FULLNAME)'
	@echo
	@echo "Install complete. Browse to http://localhost:8080"
	@echo "  user: $(ADMIN_USER)   pass: $(ADMIN_PASS)"

## upgrade: run Moodle CLI upgrade (after pulling new code into image)
.PHONY: upgrade
upgrade:
	$(COMPOSE) exec -T php php /var/www/html/admin/cli/upgrade.php --non-interactive

## logs: tail logs from all services
.PHONY: logs
logs:
	$(COMPOSE) logs -f

## ps: list compose services
.PHONY: ps
ps:
	$(COMPOSE) ps

## psql: open a psql shell against the local Postgres
.PHONY: psql
psql:
	$(COMPOSE) exec db psql -U moodle moodle

## shell-php: shell into the php container
.PHONY: shell-php
shell-php:
	$(COMPOSE) exec php bash

## shell-web: shell into the web container
.PHONY: shell-web
shell-web:
	$(COMPOSE) exec web sh

## valkey: open a valkey-cli session
.PHONY: valkey
valkey:
	$(COMPOSE) exec cache valkey-cli

## moodle-shell: drop into a `php -a` REPL inside the php container
.PHONY: moodle-shell
moodle-shell:
	$(COMPOSE) exec php php -a

## purge-cache: clear Moodle's caches
.PHONY: purge-cache
purge-cache:
	$(COMPOSE) exec -T php php /var/www/html/admin/cli/purge_caches.php

# -----------------------------------------------------------------------------
# Helm chart checks — fast local validation, no cluster required.
# -----------------------------------------------------------------------------
HELM        ?= helm
CHART_DIR   ?= chart/psa-moodle
CHART_TAG   ?= v0.1.0-dev1
RENDER_OUT  ?= /tmp/psa-moodle-rendered

## chart-check: helm lint + template against values-dev and values-test (no cluster)
.PHONY: chart-check chart-lint chart-template
chart-check: chart-lint chart-template
	@echo
	@echo "Chart check passed. Rendered output: $(RENDER_OUT)-{dev,test}.yaml"

chart-lint:
	$(HELM) lint $(CHART_DIR) -f $(CHART_DIR)/values-dev.yaml
	$(HELM) lint $(CHART_DIR) -f $(CHART_DIR)/values-test.yaml

chart-template:
	@mkdir -p $(dir $(RENDER_OUT))
	$(HELM) template psa-moodle $(CHART_DIR) \
	  -n a58ce1-dev \
	  -f $(CHART_DIR)/values-dev.yaml \
	  --set image.tag=$(CHART_TAG) \
	  > $(RENDER_OUT)-dev.yaml
	$(HELM) template psa-moodle $(CHART_DIR) \
	  -n a58ce1-test \
	  -f $(CHART_DIR)/values-test.yaml \
	  --set image.tag=$(CHART_TAG) \
	  > $(RENDER_OUT)-test.yaml
	@echo "Resource kinds rendered (dev):"
	@grep -E '^kind:' $(RENDER_OUT)-dev.yaml | sort | uniq -c | sed 's/^/  /'
	@echo "Resource kinds rendered (test):"
	@grep -E '^kind:' $(RENDER_OUT)-test.yaml | sort | uniq -c | sed 's/^/  /'

## chart-dryrun: helm install --dry-run against the cluster (needs oc login)
##   Server-side validation: CRDs, RBAC, schema. Does NOT apply anything.
.PHONY: chart-dryrun-dev chart-dryrun-test
chart-dryrun-dev:
	$(HELM) install psa-moodle $(CHART_DIR) \
	  -n a58ce1-dev \
	  -f $(CHART_DIR)/values-dev.yaml \
	  --set image.tag=$(CHART_TAG) \
	  --dry-run --debug
chart-dryrun-test:
	$(HELM) install psa-moodle $(CHART_DIR) \
	  -n a58ce1-test \
	  -f $(CHART_DIR)/values-test.yaml \
	  --set image.tag=$(CHART_TAG) \
	  --dry-run --debug
