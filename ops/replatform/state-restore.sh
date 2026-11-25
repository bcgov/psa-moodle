#!/usr/bin/env bash
# Restore LEGACY state exactly from a named capture (replatform runbook S14).
#
#   state-restore.sh <namespace> <name> [<helm release of the new stack>] [--apply]
#
# Without --apply it is a dry run: it compares the capture with the cluster and prints each difference and the command
# that would fix it. With --apply it runs those commands. Every change needs its own approval (CLAUDE.md).
#
# Restored: legacy Deployment/StatefulSet replicas; each legacy container's env array (DB_NAME, MANUAL_MODE) when it
# differs; legacy CronJob suspend flags; every Route captured (whole object: backend, alternates, annotations, TLS);
# legacy maintenance mode (file and setting). Objects of the new stack's Helm release are skipped: Helm owns them,
# and writer-fence.sh / writer-unfence.sh drive them (V501).
set -euo pipefail
NS=${1:?namespace}
NAME=${2:?capture name}
REL=""
APPLY=0
for a in "${@:3}"; do
  case "$a" in --apply) APPLY=1 ;; *) REL=$a ;; esac
done
CAP="$HOME/Moodle/private-backups/state-$NS-$NAME"
[ -d "$CAP" ] || { echo "no capture $CAP" >&2; exit 1; }
(cd "$CAP" && shasum -a 256 -c SHA256SUMS >/dev/null) || { echo "capture checksums do not match" >&2; exit 1; }
TMP=$(mktemp -d "$HOME/Moodle/private-backups/.restore-XXXXXX"); trap 'rm -rf "$TMP"' EXIT
changes=0

do_cmd() { # description, command...
  changes=$((changes + 1))
  echo "DIFF  $1"
  echo "      $(printf '%q ' "${@:2}")"
  if [ "$APPLY" -eq 1 ]; then "${@:2}"; fi
}
is_release() { # labels json -> true if the object belongs to the new stack's release
  [ -n "$REL" ] && [ "$(jq -r --arg r "$REL" '.["app.kubernetes.io/instance"] == $r' <<< "$1")" = "true" ]
}

# 1. Workloads: replicas and env.
current=$(oc get deploy,sts -n "$NS" -o json)
while read -r item; do
  kind=$(jq -r .kind <<< "$item"); name=$(jq -r .name <<< "$item"); labels=$(jq -c .labels <<< "$item")
  lkind=$(tr '[:upper:]' '[:lower:]' <<< "$kind")   # macOS bash 3.2 has no ${var,,}
  is_release "$labels" && continue
  live=$(jq -c --arg k "$kind" --arg n "$name" '.items[] | select(.kind == $k and .metadata.name == $n)' <<< "$current")
  if [ -z "$live" ]; then echo "MISSING $kind/$name (not recreated by this script)"; changes=$((changes + 1)); continue; fi
  want=$(jq -r .replicas <<< "$item"); have=$(jq -r .spec.replicas <<< "$live")
  [ "$want" != "$have" ] && do_cmd "$kind/$name replicas $have -> $want" oc scale -n "$NS" "$lkind/$name" --replicas="$want"
  n=$(jq '.env | length' <<< "$item")
  for ((i = 0; i < n; i++)); do
    cname=$(jq -r ".env[$i].container" <<< "$item"); wantenv=$(jq -c ".env[$i].env" <<< "$item")
    idx=$(jq --arg c "$cname" '[.spec.template.spec.containers[].name] | index($c)' <<< "$live")
    haveenv=$(jq -c --argjson i "$idx" '.spec.template.spec.containers[$i].env // []' <<< "$live")
    if [ "$(jq -S . <<< "$wantenv")" != "$(jq -S . <<< "$haveenv")" ]; then
      jq -n --argjson i "$idx" --argjson v "$wantenv" \
        '[{op: "replace", path: "/spec/template/spec/containers/\($i)/env", value: $v}]' > "$TMP/$kind-$name-$i.json"
      do_cmd "$kind/$name container $cname env differs ($(jq -r '[.[].name] | join(",")' <<< "$wantenv"))" \
        oc patch -n "$NS" "$lkind/$name" --type=json --patch-file="$TMP/$kind-$name-$i.json"
    fi
  done
done < <(jq -c '.[]' "$CAP/workloads.json")

# 2. CronJobs.
while read -r cj; do
  is_release "$(jq -c .labels <<< "$cj")" && continue
  name=$(jq -r .name <<< "$cj"); want=$(jq -r .suspend <<< "$cj")
  have=$(oc get cronjob "$name" -n "$NS" -o jsonpath='{.spec.suspend}' 2>/dev/null || echo missing)
  [ "$have" = "" ] && have=false
  [ "$want" != "$have" ] && do_cmd "CronJob/$name suspend $have -> $want" \
    oc patch -n "$NS" "cronjob/$name" --type=merge -p "{\"spec\":{\"suspend\":$want}}"
done < <(jq -c '.[]' "$CAP/cronjobs.json")

# 3. Routes: whole objects, exactly as captured.
while read -r route; do
  name=$(jq -r .metadata.name <<< "$route")
  live=$(oc get route "$name" -n "$NS" -o json 2>/dev/null | jq -c 'del(.status, .metadata.resourceVersion, .metadata.uid,
    .metadata.creationTimestamp, .metadata.generation, .metadata.managedFields)' || true)
  cmp() { jq -S '{spec, annotations: (.metadata.annotations // {} | del(.["openshift.io/host.generated"])), labels: (.metadata.labels // {})}'; }
  if [ -z "$live" ] || [ "$(cmp <<< "$route")" != "$(cmp <<< "$live")" ]; then
    echo "$route" > "$TMP/route-$name.json"
    if [ -z "$live" ]; then
      do_cmd "Route/$name missing" oc create -n "$NS" -f "$TMP/route-$name.json"
    else
      do_cmd "Route/$name differs (backend now $(jq -r .spec.to.name <<< "$live"), captured $(jq -r .spec.to.name <<< "$route"))" \
        oc replace -n "$NS" -f "$TMP/route-$name.json"
    fi
  fi
done < <(jq -c '.[]' "$CAP/routes.json")

# 4. Legacy maintenance mode. Needs legacy php running; otherwise it is reported, not guessed.
wantfile=$(jq -r .climaintenance_file "$CAP/maintenance.json"); wantset=$(jq -r .maintenance_enabled "$CAP/maintenance.json")
if [ "$wantfile" != "null" ]; then
  if [ "$(oc get deploy php -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = "" ]; then
    echo "SKIP  maintenance: legacy php not ready (captured file=$wantfile setting=$wantset)"; changes=$((changes + 1))
  else
    havefile=$(oc exec -n "$NS" deploy/php -c php -- sh -c 'test -f /var/www/moodledata/climaintenance.html && echo true || echo false')
    haveset=$(oc exec -n "$NS" deploy/php -c php -- php /var/www/html/admin/cli/cfg.php --name=maintenance_enabled 2>/dev/null | tail -1)
    if [ "$wantfile" != "$havefile" ] || [ "$wantset" != "$haveset" ]; then
      if [ "$wantfile" = "true" ]; then mode=--enable; elif [ "$wantset" != "0" ]; then mode=--enableold; else mode=--disable; fi
      [ "$mode" != --disable ] && [ "$havefile$haveset" != "false0" ] && \
        do_cmd "maintenance: clear first" oc exec -n "$NS" deploy/php -c php -- php /var/www/html/admin/cli/maintenance.php --disable
      do_cmd "maintenance file $havefile/$haveset -> $wantfile/$wantset" \
        oc exec -n "$NS" deploy/php -c php -- php /var/www/html/admin/cli/maintenance.php "$mode"
    fi
  fi
fi

if [ "$changes" -eq 0 ]; then echo "matches capture '$NAME'"; exit 0; fi
if [ "$APPLY" -eq 1 ]; then echo "applied $changes change(s); run again without --apply to confirm it matches"; else echo "$changes difference(s); dry run, nothing changed"; exit 3; fi
