#!/usr/bin/env bash
# Build an environment's exact Moodle code tree from public commits and prove it equals legacy's (runbook C10, C13).
#
#   build-exact-tree.sh build <env> <out dir>     clone core + add-ons at exact-code.json's commits, apply the overlay,
#                                                 drop the excluded paths, and refuse unless the tree hash matches
#   build-exact-tree.sh hash  <env> <sha256 list> the tree hash of a checksum list made the same way, e.g. the list taken
#                                                 from a legacy pod (`find . -type f -print0 | LC_ALL=C sort -z |
#                                                 xargs -0 sha256sum`), to record or recheck tree_sha256
#
# Tree hash: SHA-256 of the checksum list (`<sha256>  ./<path>`, paths in C-locale order), after removing .git
# metadata, the excluded top-level entries and paths, and (where legacy's build stripped them) .gitignore files.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
J="$HERE/exact-code.json"
MODE=${1:?build|hash}; ENVN=${2:?env}
jq -e --arg e "$ENVN" '.environments[$e]' "$J" >/dev/null || { echo "no environment $ENVN in exact-code.json" >&2; exit 2; }
cfg() { jq -r --arg e "$ENVN" ".environments[\$e]$1" "$J"; }

# Filter a checksum list on stdin with the agreed exclusions; print the tree hash.
tree_hash() {
  local strip; strip=$(cfg .strip_gitignore)
  awk -v tops="$(jq -r '.exclude_top_level | join(" ")' "$J")" -v paths="$(jq -r '.exclude_paths | join(" ")' "$J")" \
      -v strip="$strip" '
    BEGIN { n = split(tops, t, " "); m = split(paths, q, " ") }
    {
      p = substr($0, 67)                                   # after "<64 hex>  "
      if (p ~ /\/\.git(\/|$)/) next
      if (strip == "true" && p ~ /(^|\/)\.gitignore$/) next
      for (i = 1; i <= n; i++) if (p == "./" t[i] || index(p, "./" t[i] "/") == 1) next
      for (i = 1; i <= m; i++) if (p == "./" q[i] || index(p, "./" q[i] "/") == 1) next
      print
    }' | sha256sum | cut -d' ' -f1
}

if [ "$MODE" = hash ]; then tree_hash < "${3:?sha256 list}"; exit 0; fi
[ "$MODE" = build ] || { echo "build|hash" >&2; exit 2; }

OUT=${3:?out dir}
[ ! -e "$OUT" ] || [ -z "$(ls -A "$OUT")" ] || { echo "$OUT must be empty" >&2; exit 1; }
fetch() { # dir repo commit
  mkdir -p "$1"; git -C "$1" init -q; git -C "$1" remote add origin "$2"
  git -C "$1" fetch -q --depth 1 origin "$3"; git -C "$1" checkout -q FETCH_HEAD
  git -C "$1" submodule -q update --init --recursive --depth 1
  [ "$(git -C "$1" rev-parse HEAD)" = "$3" ] || { echo "$2: got $(git -C "$1" rev-parse HEAD), wanted $3" >&2; exit 1; }
}
fetch "$OUT" "$(jq -r .core_repo "$J")" "$(cfg .core_commit)"
echo "core $(cfg .core_commit | cut -c1-12)"
while IFS=$'\t' read -r path repo commit; do
  rm -rf "${OUT:?}/$path"; fetch "$OUT/$path" "$repo" "$commit"; echo "$path ${commit:0:12}"
done < <(cfg '.addons[] | [.path, .repo, .commit] | @tsv')
(cd "$HERE/../.." && cp -R "$(cfg .overlay)/." "$OUT/")
find "$OUT" -name .git -prune -exec rm -rf {} +
[ "$(cfg .strip_gitignore)" = true ] && find "$OUT" -name .gitignore -type f -delete
for p in $(jq -r '.exclude_paths[]' "$J"); do rm -rf "${OUT:?}/$p"; done

want=$(cfg .tree_sha256)
have=$(cd "$OUT" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | tree_hash)
echo "tree hash $have"
if [ -z "$want" ]; then echo "exact-code.json has no tree_sha256 for $ENVN: record it from the legacy copy first" >&2; exit 1; fi
[ "$have" = "$want" ] || { echo "MISMATCH: $ENVN tree is not legacy's code (want $want): refusing" >&2; exit 1; }
echo "$ENVN: the tree equals legacy's code ($(cfg .release))"
