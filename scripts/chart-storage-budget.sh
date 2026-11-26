#!/usr/bin/env bash
# Storage a rendered release will claim, every volume included (runbook §9 storage budget; review V1205).
#
#   chart-storage-budget.sh [--extra <GiB> <label>]... -- <helm template arguments...>
#
# Counts the chart's PersistentVolumeClaims, each StatefulSet's volumeClaimTemplates times its replicas, and the volumes
# Crunchy creates from the PostgresCluster: every instance set's data volume times its replicas, and each pgBackRest
# repository volume. --extra adds volumes outside the release (a fixture, a paired restore's own volumes) to the total.
# Prints one line per volume and the total in GiB.
set -euo pipefail
CHART=${CHART:-chart/psa-moodle}
extras=()
while [ "${1:-}" = "--extra" ]; do extras+=("$2" "$3"); shift 3; done
[ "${1:-}" = "--" ] && shift

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
helm template budget "$CHART" "$@" > "$work/r.yaml"
if yq --version 2>/dev/null | grep -q mikefarah; then         # as chart-egress-matrix.sh: CI's yq, or the same in Podman
  yq -o=json -I=0 'select(. != null)' "$work/r.yaml"
else
  podman run --rm -i docker.io/mikefarah/yq:4.44.3 -o=json -I=0 'select(. != null)' < "$work/r.yaml"
fi | jq -s '.' > "$work/r.json"
extra_json='[]'
for ((i = 0; i < ${#extras[@]}; i += 2)); do
  extra_json=$(jq -c --argjson g "${extras[i]}" --arg l "${extras[i+1]}" '. + [{gib: $g, label: $l}]' <<< "$extra_json")
done

jq -r --argjson extras "$extra_json" '
  def gib: if test("Gi$") then (sub("Gi$"; "") | tonumber) elif test("Mi$") then ((sub("Mi$"; "") | tonumber) / 1024)
           elif test("Ti$") then ((sub("Ti$"; "") | tonumber) * 1024) else error("unknown size \(.)") end;
  [ .[] |
    if .kind == "PersistentVolumeClaim" then {label: "PVC \(.metadata.name)", gib: (.spec.resources.requests.storage | gib)}
    elif .kind == "StatefulSet" then .spec.replicas as $r | (.spec.volumeClaimTemplates // [])[] |
      {label: "StatefulSet volume \(.metadata.name) x\($r)", gib: ((.spec.resources.requests.storage | gib) * $r)}
    elif .kind == "PostgresCluster" then
      (.spec.instances[] | {label: "Postgres instance set \(.name // "instance") x\(.replicas // 1)",
                            gib: ((.dataVolumeClaimSpec.resources.requests.storage | gib) * (.replicas // 1))}),
      (.spec.backups.pgbackrest.repos[] | select(.volume) |
        {label: "pgBackRest \(.name)", gib: (.volume.volumeClaimSpec.resources.requests.storage | gib)})
    else empty end ] + [ $extras[] | {label: "outside the release: \(.label)", gib} ]
  | (.[] | "\(.gib) GiB\t\(.label)"), "\(map(.gib) | add) GiB\tTOTAL"' "$work/r.json" | column -t -s $'\t'
