#!/usr/bin/env bash
# Legacy recovery package (replatform runbook S8, RB09): everything needed to start fresh legacy pods WITHOUT the old
# pipeline. Read-only on the cluster: `oc get`, `oc exec` running tar and sha256sum, and image pulls with your own token.
#
#   recovery-package.sh <namespace> [--with-secret-values]
#
# Output: ~/Moodle/private-backups/recovery-package-<namespace>-<UTC time>/ (owner-only, read-only once written):
#   manifests/<kind>.json   legacy objects of every kind a restart needs (`oc apply -f` accepts them), without status and
#                           server fields; the new stack's Helm-release objects are left out
#   images.tsv              each pod's containers: image as written, and the digest actually running (imageID)
#   images/<name>/          the namespace's own images (its internal registry), copied by digest with skopeo `dir:`, so
#                           the manifest's sha256 IS the running digest (checked); `skopeo copy --preserve-digests
#                           dir:images/<name> docker://...` puts it back unchanged. Images from Artifactory are recorded
#                           by digest only (their registry keeps them; copying needs its pull secret).
#   secrets.tsv             each Secret: name, type and keys (no values)
#   secrets/secrets.json    ONLY with --with-secret-values (private; never shared)
#   code/                   the code PVC as a php pod sees /var/www/html (moodle-app-data, plus config.php and
#                           redis-stats.php mounted over it): code.tar.gz, and code.sha256 taken in the pod and checked
#                           against the copy
#   SHA256SUMS
set -euo pipefail
NS=${1:?namespace}
WITH_VALUES=0; [ "${2:-}" = "--with-secret-values" ] && WITH_VALUES=1
SKOPEO_IMAGE=quay.io/skopeo/stable:v1.16.1
PUBLIC_REGISTRY=$(oc registry info --public)
OUT="$HOME/Moodle/private-backups/recovery-package-$NS-$(date -u +%Y%m%dT%H%M%SZ)"
umask 077
mkdir -p "$OUT/manifests" "$OUT/images" "$OUT/code"
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
not_release='[.items[] | select(((.metadata.labels // {})["app.kubernetes.io/managed-by"] == "Helm"
  and ((.metadata.labels // {})["app.kubernetes.io/name"] // "") == "psa-moodle") | not)]'
clean='del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.generation,
  .metadata.managedFields, .metadata.ownerReferences, .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"],
  .status)'

# 1. Manifests.
for kind in deployments statefulsets services routes configmaps persistentvolumeclaims cronjobs networkpolicies \
            horizontalpodautoscalers poddisruptionbudgets serviceaccounts roles rolebindings imagestreams buildconfigs; do
  oc get "$kind" -n "$NS" -o json \
    | jq "{apiVersion: \"v1\", kind: \"List\", items: ($not_release | map($clean))}" > "$OUT/manifests/$kind.json"
  log "manifests/$kind: $(jq '.items | length' "$OUT/manifests/$kind.json")"
done

# 2. Images: what each pod runs, and a by-digest copy of the namespace's own.
oc get pods -n "$NS" -o json | jq -r '.items[] | .metadata.name as $p | (.status.containerStatuses // [])[]
  | [$p, .name, .image, .imageID] | @tsv' > "$OUT/images.tsv"
auth=$(mktemp -d); trap 'rm -rf "$auth"' EXIT
oc whoami -t | podman login --authfile "$auth/auth.json" -u unused --password-stdin "$PUBLIC_REGISTRY" >/dev/null
cut -f2,4 "$OUT/images.tsv" | sort -u | while IFS=$'\t' read -r name id; do
  ref=${id#*://}
  case "$ref" in
    image-registry.openshift-image-registry.svc:5000/"$NS"/*) ;;
    *) continue ;;
  esac
  digest=${ref##*@}
  src="docker://$PUBLIC_REGISTRY/${ref#image-registry.openshift-image-registry.svc:5000/}"
  podman run --rm -v "$auth:/auth:ro" -v "$OUT/images:/out" "$SKOPEO_IMAGE" copy --quiet --all \
    --src-authfile /auth/auth.json "$src" "dir:/out/$name" </dev/null
  got="sha256:$(shasum -a 256 "$OUT/images/$name/manifest.json" | cut -d' ' -f1)"
  [ "$got" = "$digest" ] || { log "IMAGE COPY MISMATCH for $name: $got != $digest"; exit 1; }
  log "images/$name: $digest ($(du -sh "$OUT/images/$name" | cut -f1))"
done
log "images: $(cut -f4 "$OUT/images.tsv" | sort -u | wc -l | tr -d ' ') distinct running digests recorded"

# 3. Secrets: names and keys; values only on request.
oc get secrets -n "$NS" -o json | jq -r '.items[] | [.metadata.name, .type, ((.data // {}) | keys | join(","))] | @tsv' \
  > "$OUT/secrets.tsv"
if [ "$WITH_VALUES" -eq 1 ]; then
  mkdir -p "$OUT/secrets"
  oc get secrets -n "$NS" -o json | jq "{apiVersion: \"v1\", kind: \"List\", items: (.items | map($clean))}" \
    > "$OUT/secrets/secrets.json"
  log "secrets: values saved (private)"
fi
log "secrets: $(wc -l < "$OUT/secrets.tsv" | tr -d ' ') names recorded"

# 4. Code, as a running php pod sees it.
pod=$(oc get pods -n "$NS" -l deployment=php --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
oc exec -n "$NS" "$pod" -c php -- tar -C /var/www/html -czf - . > "$OUT/code/code.tar.gz"
oc exec -n "$NS" "$pod" -c php -- sh -c \
  'cd /var/www/html && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum' > "$OUT/code/code.sha256"
mkdir -p "$OUT/code/check" && tar -C "$OUT/code/check" -xzf "$OUT/code/code.tar.gz"
(cd "$OUT/code/check" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256) > "$OUT/code/check.sha256"
if ! diff -q "$OUT/code/code.sha256" "$OUT/code/check.sha256" >/dev/null; then
  log "CODE COPY DIFFERS from the pod: see $OUT/code"; exit 1
fi
chmod -R u+w "$OUT/code/check"; rm -rf "$OUT/code/check" "$OUT/code/check.sha256"
log "code: $(wc -l < "$OUT/code/code.sha256" | tr -d ' ') files from $pod, the copy matches the pod"

(cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 > SHA256SUMS)
chmod -R a-w "$OUT"
log "recovery package: $OUT ($(du -sh "$OUT" | cut -f1))"
