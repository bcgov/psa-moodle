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
#
# RESTORE_SCOPE is REQUIRED (review V1005): `all`, or a comma list of replicas,env,cronjobs,configmaps,routes,maintenance.
# For example RESTORE_SCOPE=routes when abandoning a return, RESTORE_SCOPE=env,configmaps in bailout-unswitch.sh.
#
# Order (V1005, S14): ingress stays where it is until legacy is back in its captured maintenance state.
#   1. container env and ConfigMaps;  2. replicas, except cron workers (CRON_WORKLOADS, default Deployment/cron);
#   3. wait for legacy php;  4. maintenance mode, switching without an unprotected interval;
#   5. cron workers' replicas and CronJob suspend flags;  6. Routes, last.
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
[ -n "${RESTORE_SCOPE:-}" ] || { echo "RESTORE_SCOPE is required: all, or a list of replicas,env,cronjobs,configmaps,routes,maintenance" >&2; exit 2; }
[ "$RESTORE_SCOPE" = all ] && RESTORE_SCOPE=replicas,env,cronjobs,configmaps,routes,maintenance
for x in ${RESTORE_SCOPE//,/ }; do
  case "$x" in replicas|env|cronjobs|configmaps|routes|maintenance) ;; *) echo "unknown RESTORE_SCOPE item: $x" >&2; exit 2 ;; esac
done
SCOPE=",$RESTORE_SCOPE,"
CRON_WORKLOADS=" ${CRON_WORKLOADS:-Deployment/cron} "
in_scope() { [[ "$SCOPE" == *",$1,"* ]]; }
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

# 1. Container env (workloads) and, below, ConfigMaps.
current=$(oc get deploy,sts -n "$NS" -o json)
is_cron() { [[ "$CRON_WORKLOADS" == *" $1 "* ]]; }
replicas_step() { # $1 = cron | other
  while read -r item; do
    kind=$(jq -r .kind <<< "$item"); name=$(jq -r .name <<< "$item"); labels=$(jq -c .labels <<< "$item")
    lkind=$(tr '[:upper:]' '[:lower:]' <<< "$kind")   # macOS bash 3.2 has no ${var,,}
    is_release "$labels" && continue
    if is_cron "$kind/$name"; then [ "$1" = cron ] || continue; else [ "$1" = other ] || continue; fi
    live=$(jq -c --arg k "$kind" --arg n "$name" '.items[] | select(.kind == $k and .metadata.name == $n)' <<< "$current")
    [ -n "$live" ] || continue
    want=$(jq -r .replicas <<< "$item"); have=$(jq -r .spec.replicas <<< "$live")
    [ "$want" != "$have" ] && do_cmd "$kind/$name replicas $have -> $want" oc scale -n "$NS" "$lkind/$name" --replicas="$want"
  done < <(jq -c '.[]' "$CAP/workloads.json")
  return 0   # a last `[ ] && do_cmd` that found nothing to do must not stop the script under set -e
}
while read -r item; do
  kind=$(jq -r .kind <<< "$item"); name=$(jq -r .name <<< "$item"); labels=$(jq -c .labels <<< "$item")
  lkind=$(tr '[:upper:]' '[:lower:]' <<< "$kind")
  is_release "$labels" && continue
  live=$(jq -c --arg k "$kind" --arg n "$name" '.items[] | select(.kind == $k and .metadata.name == $n)' <<< "$current")
  if [ -z "$live" ]; then echo "MISSING $kind/$name (not recreated by this script)"; changes=$((changes + 1)); continue; fi
  n=$(jq '.env | length' <<< "$item")
  in_scope env || n=0
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

# 1b. ConfigMaps that select a database (db-consumers.md), data exactly as captured. Older captures have none.
if in_scope configmaps && [ -f "$CAP/configmaps.json" ]; then
  while read -r cm; do
    name=$(jq -r .name <<< "$cm"); want=$(jq -S .data <<< "$cm")
    have=$(oc get configmap "$name" -n "$NS" -o json 2>/dev/null | jq -S '.data // {}' || echo missing)
    if [ "$want" != "$have" ]; then
      jq -n --argjson d "$want" '{data: $d}' > "$TMP/cm-$name.json"
      do_cmd "ConfigMap/$name data differs" oc patch -n "$NS" "configmap/$name" --type=merge --patch-file="$TMP/cm-$name.json"
    fi
  done < <(jq -c '.[]' "$CAP/configmaps.json")
fi

# 2. Replicas, except cron workers.
in_scope replicas && replicas_step other

# 3. Wait for legacy php before touching maintenance (apply only).
if [ "$APPLY" -eq 1 ] && in_scope maintenance && in_scope replicas; then oc rollout status deploy/php -n "$NS" --timeout=10m || true; fi

# 4. Legacy maintenance mode. Needs legacy php running; otherwise it is reported, not guessed. Every switch keeps some
# maintenance active throughout (V1005): Moodle's --enableold sets the web setting and leaves the CLI file, so going
# from CLI to web maintenance is --enableold first and then removing the file, never --disable in between.
wantfile=$(jq -r .climaintenance_file "$CAP/maintenance.json"); wantset=$(jq -r .maintenance_enabled "$CAP/maintenance.json")
if in_scope maintenance && [ "$wantfile" != "null" ]; then
  if [ "$(oc get deploy php -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = "" ]; then
    echo "SKIP  maintenance: legacy php not ready (captured file=$wantfile setting=$wantset)"; changes=$((changes + 1))
  else
    mphp() { oc exec -n "$NS" deploy/php -c php -- php /var/www/html/admin/cli/maintenance.php "$@"; }
    havefile=$(oc exec -n "$NS" deploy/php -c php -- sh -c 'test -f /var/www/moodledata/climaintenance.html && echo true || echo false')
    haveset=$(oc exec -n "$NS" deploy/php -c php -- php /var/www/html/admin/cli/cfg.php --name=maintenance_enabled 2>/dev/null | tail -1)
    if [ "$wantfile" != "$havefile" ] || [ "$wantset" != "$haveset" ]; then
      if [ "$wantfile" = true ]; then
        do_cmd "maintenance $havefile/$haveset -> CLI ($wantfile/$wantset)" mphp --enable
      elif [ "$wantset" != "0" ] && [ -n "$wantset" ]; then
        [ "$haveset" = 1 ] || do_cmd "maintenance $havefile/$haveset -> web: set it first" mphp --enableold
        [ "$havefile" = true ] && do_cmd "maintenance -> web: then remove the CLI file" \
          oc exec -n "$NS" deploy/php -c php -- rm -f /var/www/moodledata/climaintenance.html
      else
        do_cmd "maintenance $havefile/$haveset -> off" mphp --disable
      fi
    fi
  fi
fi

# 5. Cron workers' replicas, then CronJobs: only once maintenance is as captured.
in_scope replicas && replicas_step cron

# 5b. CronJobs.
in_scope cronjobs && while read -r cj; do
  is_release "$(jq -c .labels <<< "$cj")" && continue
  name=$(jq -r .name <<< "$cj"); want=$(jq -r .suspend <<< "$cj")
  have=$(oc get cronjob "$name" -n "$NS" -o jsonpath='{.spec.suspend}' 2>/dev/null || echo missing)
  [ "$have" = "" ] && have=false
  [ "$want" != "$have" ] && do_cmd "CronJob/$name suspend $have -> $want" \
    oc patch -n "$NS" "cronjob/$name" --type=merge -p "{\"spec\":{\"suspend\":$want}}"
done < <(jq -c '.[]' "$CAP/cronjobs.json")

# 6. Routes, LAST: whole objects, exactly as captured.
in_scope routes && while read -r route; do
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

if [ "$changes" -eq 0 ]; then echo "matches capture '$NAME'"; exit 0; fi
if [ "$APPLY" -eq 1 ]; then echo "applied $changes change(s); run again without --apply to confirm it matches"; else echo "$changes difference(s); dry run, nothing changed"; exit 3; fi
