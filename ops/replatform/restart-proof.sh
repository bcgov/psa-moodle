#!/usr/bin/env bash
# Restart proof for a legacy recovery package (runbook S8, RB09): fresh legacy php, web and cron pods start from what the
# package recorded, with the old pipeline untouched.
#
#   restart-proof.sh <namespace> <package-dir>            checks only (read-only)
#   restart-proof.sh <namespace> <package-dir> --apply    ALSO deletes one php, web and cron pod, waits for the
#                                                         replacements, and repeats every check on them (a cluster
#                                                         change: run only with the owner's approval)
# Checks:
#   1. each Deployment's live pod template equals the package's (so a recreated pod IS the package);
#   2. each running pod's image digest is one the package copied, and the copy's manifest has that digest;
#   3. the code a running php pod sees equals the package's code.sha256, file for file;
#   4. the login page renders through the web Service with the site's own host name (HTTP 200 and a username field);
#   5. cron has completed a run in the last 5 minutes.
set -euo pipefail
NS=${1:?namespace}; PKG=${2:?package dir}; APPLY=0; [ "${3:-}" = "--apply" ] && APPLY=1
[ -f "$PKG/SHA256SUMS" ] || { echo "not a recovery package: $PKG" >&2; exit 2; }
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
fail() { log "FAIL: $*"; exit 1; }
sel() { case "$1" in cron) echo app=cron ;; *) echo "deployment=$1" ;; esac; }   # macOS bash 3.2: no associative arrays
HOST=$(jq -r '.items[] | select(.metadata.name == "moodle-web") | .spec.host' "$PKG/manifests/routes.json")

(cd "$PKG" && shasum -a 256 -c SHA256SUMS --quiet) || fail "package checksums"
log "package $PKG: checksums ok; site host $HOST"

checks() {
  local c live pkg pods ids id php
  for c in php web cron; do
    live=$(oc get deploy "$c" -n "$NS" -o json | jq -S '.spec.template')
    pkg=$(jq -S --arg c "$c" '.items[] | select(.metadata.name == $c) | .spec.template' "$PKG/manifests/deployments.json")
    [ "$live" = "$pkg" ] || { diff <(echo "$pkg") <(echo "$live") | head -20; fail "$c: live pod template differs from the package"; }
    ids=$(oc get pods -n "$NS" -l "$(sel "$c")" --field-selector=status.phase=Running -o json \
          | jq -r --arg c "$c" '.items[].status.containerStatuses[] | select(.name == $c) | .imageID | sub("^.*@"; "")' | sort -u)
    [ -n "$ids" ] || fail "$c: no running pod"
    for id in $ids; do
      [ "sha256:$(shasum -a 256 "$PKG/images/$c/manifest.json" | cut -d' ' -f1)" = "$id" ] \
        || fail "$c: running digest $id is not the package's copy"
    done
    pods=$(oc get pods -n "$NS" -l "$(sel "$c")" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}')
    log "check 1-2 $c: template = package; running $id ($pods)"
  done
  php=$(oc get pods -n "$NS" -l deployment=php --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
  oc exec -n "$NS" "$php" -c php -- sh -c 'cd /var/www/html && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum' \
    | diff -q "$PKG/code/code.sha256" - >/dev/null || fail "code in $php differs from the package"
  log "check 3 code: $php sees the package's $(wc -l < "$PKG/code/code.sha256" | tr -d ' ') files exactly"
  oc exec -n "$NS" "$php" -c php -- sh -c "curl -s -o /tmp/rp-proof.html -w '%{http_code}' -H 'Host: $HOST' \
      -H 'X-Forwarded-Proto: https' http://web:8080/login/index.php; echo \" \$(grep -c 'name=\"username\"' /tmp/rp-proof.html)\"; rm -f /tmp/rp-proof.html" \
    | { read -r code fields; [ "$code" = 200 ] && [ "${fields:-0}" -ge 1 ] || fail "login page: HTTP $code, username fields ${fields:-0}"; }
  log "check 4 site: login page renders (HTTP 200) for $HOST"
  oc logs -n "$NS" deploy/cron --since=5m 2>/dev/null | grep -q 'Cron run completed correctly' || fail "cron: no completed run in 5 minutes"
  log "check 5 cron: completed a run in the last 5 minutes"
}

checks
[ "$APPLY" -eq 1 ] || { log "read-only checks passed; rerun with --apply to replace the pods"; exit 0; }

old=""
for c in php web cron; do
  pod=$(oc get pods -n "$NS" -l "$(sel "$c")" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
  old="$old $pod"
  log "deleting $c pod $pod"
  oc delete pod -n "$NS" "$pod" --wait=false
done
for c in php web cron; do oc rollout status deploy/"$c" -n "$NS" --timeout=10m; done
for c in php web cron; do
  oc wait pod -n "$NS" -l "$(sel "$c")" --for=condition=Ready --timeout=10m >/dev/null
done
for p in $old; do
  if oc get pod -n "$NS" "$p" >/dev/null 2>&1; then
    oc wait pod -n "$NS" "$p" --for=delete --timeout=5m >/dev/null || fail "old pod $p still present"
  fi
done
log "replacement pods ready; waiting 90 s for a cron run"
sleep 90
checks
log "RESTART PROOF PASSED: fresh php, web and cron pods run the package's images and code, and the site works"
