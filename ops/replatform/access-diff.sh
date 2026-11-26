#!/usr/bin/env bash
# S16 access gate (runbook §3): may a copy of <source>'s real data go into <target> without anyone gaining access to
# records they can't already see? Read-only.
#
#   access-diff.sh <source-namespace> <target-namespace>      e.g. access-diff.sh 950003-prod 950003-dev
#
# Compares the users and groups bound to any role in each namespace (RoleBindings; cluster-wide bindings apply to both
# alike and aren't listed). Prints, to this terminal only, every user or group with access to the target but not the
# source, and exits 1 if there is one: each must be confirmed by the owner or have its target access paused for the pass.
# Group membership isn't expanded (that needs cluster rights); a group is compared by name. The target's own service
# accounts are listed separately: they are the namespace's automation, reached through its deploy pipeline.
# The output names people: keep it out of git, chat and tickets; the window log records the counts and the decision.
set -euo pipefail
SRC=${1:?source namespace}; DST=${2:?target namespace}

subjects() {  # kind<TAB>name, for every subject bound to any role in namespace $1
  oc get rolebindings -n "$1" -o json \
    | jq -r --arg ns "$1" '.items[] | .subjects[]? |
        if .kind == "ServiceAccount" then "ServiceAccount\t\(.namespace // $ns)/\(.name)" else "\(.kind)\t\(.name)" end' \
    | sort -u
}

src=$(subjects "$SRC"); dst=$(subjects "$DST")
extra=$(comm -13 <(grep -v '^ServiceAccount' <<< "$src" || true) <(grep -v '^ServiceAccount' <<< "$dst" || true))
sas=$(grep '^ServiceAccount' <<< "$dst" || true)

echo "== users and groups with access to $DST but not to $SRC: $(grep -c . <<< "$extra" || true)"
[ -z "$extra" ] || sed 's/^/   /' <<< "$extra"
echo "== service accounts with access to $DST (its automation): $(grep -c . <<< "$sas" || true)"
[ -z "$sas" ] || cut -f2 <<< "$sas" | sed 's/^/   /'
if [ -n "$extra" ]; then
  echo "RESULT: NOT CLEAR. Confirm each name above with the owner, or pause its $DST access for the pass (S16)."; exit 1
fi
echo "RESULT: clear. Nobody gains access to $SRC's records by a copy in $DST."
