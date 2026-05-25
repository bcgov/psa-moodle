# Containerfile.php — PHP-FPM runtime for Moodle 4.5
#
# This image is also the source-of-truth for Moodle code: web and cron images
# COPY --from=this image so we clone Moodle exactly once per build cycle.
#
# Built non-root, on an arbitrary UID friendly to OpenShift's restricted SCC.

# =============================================================================
# Stage 1 — source builder: clones Moodle, layers plugins + theme + config.
# =============================================================================
FROM debian:bookworm-slim AS src

ARG MOODLE_BRANCH=MOODLE_405_STABLE
ARG HVP_BRANCH=master
ARG MOODLE_CONFIG_VARIANT=local

ENV MOODLE_SRC=/opt/moodle/html
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install --no-install-recommends -y \
      git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Moodle core
RUN git clone --depth=1 --branch ${MOODLE_BRANCH} --single-branch \
      https://github.com/moodle/moodle.git ${MOODLE_SRC}

# HVP plugin (upstream); subtrees include the h5p-php-library submodule.
# Pin via HVP_BRANCH or by mounting a SHA file in CI.
RUN git clone --recurse-submodules --depth=1 --branch ${HVP_BRANCH} --single-branch \
      https://github.com/h5p/moodle-mod_hvp ${MOODLE_SRC}/mod/hvp

# First-party PSA plugins (synced into the build context by `make sync-plugins`).
# Layout under plugins/ mirrors Moodle's component-type directory tree.
COPY plugins/blocks/course_search ${MOODLE_SRC}/blocks/course_search
COPY plugins/local/githubsync     ${MOODLE_SRC}/local/githubsync
COPY plugins/local/psaelmsync     ${MOODLE_SRC}/local/psaelmsync
COPY plugins/mod/pathcurator      ${MOODLE_SRC}/mod/pathcurator

# BC Gov PSA child theme
COPY themes/bcgovpsa ${MOODLE_SRC}/theme/bcgovpsa

# Moodle config: local (Podman compose) or openshift (Helm).
COPY config/moodle/config.${MOODLE_CONFIG_VARIANT}.php ${MOODLE_SRC}/config.php

# Strip git metadata to keep the runtime image lean.
RUN find ${MOODLE_SRC} -name '.git' -type d -prune -exec rm -rf {} + \
 && find ${MOODLE_SRC} -name '.gitignore' -delete \
 && find ${MOODLE_SRC} -name '.DS_Store' -delete

# =============================================================================
# Stage 2 — runtime: php-fpm 8.3 with Moodle's required extensions.
# =============================================================================
FROM php:8.3-fpm-bookworm

ENV DEBIAN_FRONTEND=noninteractive

# OS deps for the PHP extensions we install below.
RUN apt-get update && apt-get install --no-install-recommends -y \
      libfreetype-dev libjpeg62-turbo-dev libpng-dev libwebp-dev \
      libzip-dev libxml2-dev libxslt-dev libldap-dev \
      libonig-dev libicu-dev libpq-dev libfcgi-bin \
      libcurl4-openssl-dev \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# install-php-extensions (mlocati) handles GD configure flags, pecl quirks, etc.
ADD https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/
RUN chmod +x /usr/local/bin/install-php-extensions \
 && install-php-extensions \
      gd \
      intl \
      ldap \
      exif \
      mbstring \
      opcache \
      pdo_pgsql \
      pgsql \
      soap \
      xsl \
      zip \
      redis

# php-fpm-healthcheck for liveness/readiness probes.
# `chmod 755` (not `+x`): ADD downloads with mode 600, so `+x` alone would only
# add the execute bit, leaving the file unreadable to non-root. Shell scripts
# need read permission to execute (the kernel reads the shebang line).
ADD https://raw.githubusercontent.com/renatomefi/php-fpm-healthcheck/master/php-fpm-healthcheck /usr/local/bin/php-fpm-healthcheck
RUN chmod 755 /usr/local/bin/php-fpm-healthcheck

# Use the production php.ini as base and overlay our tuning.
RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"
COPY config/php/php.ini      $PHP_INI_DIR/conf.d/zz-moodle.ini
# Overwrite the upstream www.conf so only our pool is loaded — otherwise both
# [www] (from the base image) and [moodle] try to bind 0.0.0.0:9000 and FPM
# fails to start with exit 78.
COPY config/php/php-fpm.conf /usr/local/etc/php-fpm.d/www.conf

# Application code from the src stage.
COPY --from=src --chown=www-data:0 /opt/moodle/html /var/www/html

# moodledata, localcachedir mount points (mode 02775 so root-group writes work
# under OpenShift's arbitrary-UID SCC).
RUN mkdir -p /var/www/moodledata /var/local-cache \
 && chown -R www-data:0 /var/www/moodledata /var/local-cache \
 && chmod -R g+rwX /var/www/moodledata /var/local-cache \
 && chmod -R g+rwX /var/www/html

WORKDIR /var/www/html
USER www-data
EXPOSE 9000
CMD ["php-fpm", "-F"]
