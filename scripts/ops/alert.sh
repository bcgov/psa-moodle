#!/usr/bin/env bash
# alert.sh — send an email via the unauth'd BC Gov SMTP relay.
#
# Used by every Phase 6 CronJob. Subject and body are positional args; envelope
# headers come from environment variables that the chart wires from values.yaml.
#
# Usage:
#   alert.sh "psa-moodle: backup integrity FAIL" "details... ${LOGFILE}"

set -eu

: "${ALERT_SMTP_HOST:?ALERT_SMTP_HOST not set}"
: "${ALERT_FROM:?ALERT_FROM not set}"
: "${ALERT_TO:?ALERT_TO not set (comma-separated)}"

SUBJECT="${1:?subject required}"
BODY="${2:-(no body)}"

# Each recipient gets its own swaks invocation — simpler than handling
# comma-separated lists inside swaks's --to.
IFS=',' read -ra RECIPIENTS <<< "$ALERT_TO"
for to in "${RECIPIENTS[@]}"; do
  to_trimmed="$(echo "$to" | tr -d ' ')"
  [ -z "$to_trimmed" ] && continue
  swaks \
    --server "$ALERT_SMTP_HOST" \
    --port 25 \
    --from "$ALERT_FROM" \
    --to "$to_trimmed" \
    --h-Subject "$SUBJECT" \
    --body "$BODY" \
    --suppress-data \
    || echo "alert.sh: WARNING — swaks failed for $to_trimmed (exit $?)" >&2
done
