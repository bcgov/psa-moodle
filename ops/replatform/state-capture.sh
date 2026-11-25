#!/usr/bin/env bash
# Capture an environment's state into an immutable, NAMED capture (replatform runbook S14). Read-only on the cluster:
# `oc get`, `helm get`, and `oc exec` running only file tests and Moodle's read-only cfg.php.
#
#   state-capture.sh <namespace> <name> [<helm release of the new stack>]
#
# Names used by the runbook: precutover (§13 T0) and prereturn (§14). The capture is private (S9): Route YAML holds TLS
# private keys. It goes to ~/Moodle/private-backups/state-<namespace>-<name>/ and is made read-only; an existing
# capture is never overwritten.
#
# Contents:
#   workloads.json    every Deployment and StatefulSet: kind, name, replicas, labels, and each container's env array
#                     (env holds DB_NAME and MANUAL_MODE; Secret references are kept as references, never values)
#   routes.json       every Route, whole objects (spec, annotations, TLS)
#   cronjobs.json     every CronJob: name, suspend
#   configmaps.json   the ConfigMaps in db-consumers.md that select a database (default: legacy's backup target)
#   maintenance.json  legacy: CLI maintenance file present?, maintenance_enabled (via legacy's own php CLI)
#   helm.txt          the new stack's release status and values, if a release is named
#   SHA256SUMS
set -euo pipefail
NS=${1:?namespace}
NAME=${2:?capture name}
REL=${3:-}
OUT="$HOME/Moodle/private-backups/state-$NS-$NAME"
[ -e "$OUT" ] && { echo "capture $OUT already exists; captures are immutable" >&2; exit 1; }
umask 077
mkdir -p "$OUT"

{
  echo "namespace: $NS"; echo "name: $NAME"; echo "captured: $(date -u +%FT%TZ)"
  echo "by: $(oc whoami)"; echo "server: $(oc whoami --show-server)"; echo "release: ${REL:-none}"
} > "$OUT/meta.txt"

oc get deploy,sts -n "$NS" -o json | jq '[.items[] | {kind, name: .metadata.name, replicas: .spec.replicas,
  labels: (.metadata.labels // {}),
  env: [.spec.template.spec.containers[] | {container: .name, env: (.env // [])}]}]' > "$OUT/workloads.json"

oc get routes -n "$NS" -o json | jq '[.items[] | del(.status, .metadata.resourceVersion, .metadata.uid,
  .metadata.creationTimestamp, .metadata.generation, .metadata.managedFields)]' > "$OUT/routes.json"

CAPTURE_CONFIGMAPS=${CAPTURE_CONFIGMAPS:-moodle-db-backup-storage-config}
for cm in $CAPTURE_CONFIGMAPS; do oc get configmap "$cm" -n "$NS" -o json 2>/dev/null || true; done \
  | jq -s '[.[] | {name: .metadata.name, data: (.data // {})}]' > "$OUT/configmaps.json"

oc get cronjobs -n "$NS" -o json | jq '[.items[] | {name: .metadata.name, suspend: (.spec.suspend // false),
  labels: (.metadata.labels // {})}]' > "$OUT/cronjobs.json"

# Legacy maintenance: CLI maintenance is a file in moodledata; web maintenance is the maintenance_enabled setting.
if oc get deploy php -n "$NS" >/dev/null 2>&1 && [ "$(oc get deploy php -n "$NS" -o jsonpath='{.status.readyReplicas}')" != "" ]; then
  file=$(oc exec -n "$NS" deploy/php -c php -- sh -c 'test -f /var/www/moodledata/climaintenance.html && echo true || echo false')
  setting=$(oc exec -n "$NS" deploy/php -c php -- php /var/www/html/admin/cli/cfg.php --name=maintenance_enabled 2>/dev/null | tail -1)
  jq -n --arg f "$file" --arg s "$setting" '{source: "legacy php", climaintenance_file: ($f == "true"), maintenance_enabled: $s}' \
    > "$OUT/maintenance.json"
else
  jq -n '{source: "unavailable: legacy php not ready", climaintenance_file: null, maintenance_enabled: null}' > "$OUT/maintenance.json"
fi

if [ -n "$REL" ]; then
  { helm status "$REL" -n "$NS" 2>&1 | head -8; echo "--- values"; helm get values "$REL" -n "$NS" -o yaml 2>&1; } > "$OUT/helm.txt"
fi

(cd "$OUT" && shasum -a 256 ./*.json ./*.txt > SHA256SUMS)
chmod -R a-w "$OUT"
echo "captured $NS as '$NAME' in $OUT"
jq -r '.[] | "  \(.kind) \(.name) replicas=\(.replicas)"' "$OUT/workloads.json"
jq -r '.[] | "  Route \(.metadata.name) -> \(.spec.to.name)\(if .spec.alternateBackends then " +alternates" else "" end)\(if .metadata.annotations["haproxy.router.openshift.io/ip_whitelist"] then " (restricted)" else "" end)"' "$OUT/routes.json"
jq -r '"  maintenance: file=\(.climaintenance_file) setting=\(.maintenance_enabled) (\(.source))"' "$OUT/maintenance.json"
