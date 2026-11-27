#!/usr/bin/env bash
# Copy a set of paths out of a pod in verified chunks (runbook S12 off-site copy, §13.3, §14.8). Read-only on the cluster:
# only `oc exec` running tar, grep and wc in an existing pod.
#
#   [CONTAINER=<name>] [LIST=<file in the pod>] offsite-copy.sh <namespace> <pod> <root in pod> <dest dir> <chunk>...
#
#   chunk   a shell glob relative to <root>, expanded IN the pod ('filedir/0*', 'lang', 'secret'); with LIST, an
#           extended regex selecting lines of that in-pod path list instead ('^filedir/0', '^(lang|secret)$').
#
# Why: in Pass B run 2 two single `oc exec ... tar` streams of about 130 MiB arrived short with exit status 0 (an exec
# stream can lose its last bytes), so no copy is trusted on its exit status. Each chunk is one tar stream; it counts only
# if its size equals the same tar measured in the pod, it lists cleanly, and its file count matches the pod's. A chunk
# is retried up to 3 times. Keep chunks to tens of MiB.
#
# Writes <dest>/part-NN.tar and <dest>/SHA256SUMS.txt, then extracts everything into <dest>/verify and checks each file
# under a filedir/ path: its SHA-1 must equal its name. Prints counts only, never names. Exit 0 only if all of it holds.
set -euo pipefail
NS=${1:?namespace}; POD=${2:?pod}; ROOT=${3:?root in pod}; DEST=${4:?dest dir}; shift 4
[ "$#" -gt 0 ] || { echo "no chunks given" >&2; exit 2; }
umask 077
mkdir -p "$DEST"; [ -z "$(ls -A "$DEST" 2>/dev/null)" ] || { echo "$DEST is not empty" >&2; exit 2; }
c=(); [ -n "${CONTAINER:-}" ] && c=(-c "$CONTAINER")
LIST=${LIST:-}

# The in-pod command for one chunk: a tar stream on stdout. $1 root, $2 chunk, $3 list (may be empty).
# shellcheck disable=SC2016  # expanded by the pod's shell
STREAM='cd "$1" || exit 1; if [ -n "$3" ]; then grep -E "$2" "$3" | tar -cf - -T -; else eval "set -- $2"; tar -cf - "$@"; fi'

n=0; total=0; files=0
for chunk in "$@"; do
  n=$((n + 1)); part=$(printf '%s/part-%02d.tar' "$DEST" "$n")
  read -r want wantfiles < <(oc exec -n "$NS" "$POD" ${c[@]+"${c[@]}"} -- sh -c \
    "s() { $STREAM; }; echo \"\$(s \"\$@\" | wc -c) \$(s \"\$@\" | tar -tf - | awk '!/\\/\$/ {n++} END {print n+0}')\"" sh "$ROOT" "$chunk" "$LIST")
  ok=0
  for try in 1 2 3; do
    oc exec -n "$NS" "$POD" ${c[@]+"${c[@]}"} -- sh -c "$STREAM" sh "$ROOT" "$chunk" "$LIST" > "$part" || true
    got=$(wc -c < "$part" | tr -d ' ')
    if [ "$got" = "$want" ] && gotfiles=$(tar -tf "$part" 2>/dev/null | awk '!/\/$/ {n++} END {print n+0}'); [ "${gotfiles:-x}" = "$wantfiles" ]; then
      ok=1; break
    fi
    echo "chunk $n: try $try arrived $got of $want bytes; retrying" >&2
  done
  [ "$ok" = 1 ] || { echo "chunk $n failed 3 times" >&2; exit 1; }
  total=$((total + want)); files=$((files + wantfiles))
done
(cd "$DEST" && shasum -a 256 part-*.tar > SHA256SUMS.txt)

mkdir "$DEST/verify"
for p in "$DEST"/part-*.tar; do tar -C "$DEST/verify" -xf "$p"; done
have=$(find "$DEST/verify" -type f | wc -l | tr -d ' ')
bad=0; checked=0
while IFS= read -r -d '' f; do
  checked=$((checked + 1))
  [ "$(shasum -a 1 "$f" | cut -d' ' -f1)" = "$(basename "$f")" ] || bad=$((bad + 1))
done < <(find "$DEST/verify" -path '*/filedir/*' -type f -print0)
echo "chunks: $n; bytes: $total; files: $files in the pod, $have extracted; filedir SHA-1 checked: $checked, mismatches: $bad"
[ "$have" = "$files" ] && [ "$bad" = 0 ]
