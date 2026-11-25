#!/usr/bin/env bash
# Lift the writer fence (replatform runbook S13, §14 "Abandon and resume"). CHANGES THE CLUSTER: needs approval.
#
#   writer-unfence.sh <namespace> <release> <chart dir>
#
# `helm upgrade --reuse-values` with migration.state=normal, then waits for web and php to be ready. Public Routes are
# NOT moved here: restore them from the named capture with state-restore.sh (e.g. `prereturn`), so they return exactly
# to where they were.
set -euo pipefail
NS=${1:?namespace}
REL=${2:?release}
CHART=${3:?chart dir}
SEL="app.kubernetes.io/instance=$REL"

helm upgrade "$REL" "$CHART" -n "$NS" --reuse-values --set migration.state=normal
for c in web php; do
  for d in $(oc get deploy -n "$NS" -l "$SEL,app.kubernetes.io/component=$c" -o name); do
    oc rollout status -n "$NS" "$d" --timeout=600s
  done
done
# A backup that died mid-pause leaves its maintenance file (C8, J1); the cron loop removes it after 15 minutes, but a
# resumed site shouldn't wait for that.
pod=$(oc get pods -n "$NS" -l "$SEL,app.kubernetes.io/component=php" -o jsonpath='{.items[0].metadata.name}')
if oc exec -n "$NS" "$pod" -- grep -qs 'rp-backup-fence' /var/www/moodledata/climaintenance.html; then
  echo "WARNING: a backup-marked climaintenance.html is present; the site stays in maintenance until it is removed" >&2
fi
echo "unfenced: $(oc get deploy -n "$NS" -l "$SEL" -o jsonpath='{range .items[*]}{.metadata.name}={.status.readyReplicas}/{.spec.replicas} {end}')"
