#!/usr/bin/env bash
# Sync first-party plugins + child theme from the dev workspace (../moodle-dev)
# into this repo's build context. Run once before `make build`, and any time
# the dev plugins change.
#
# The dev workspace is the source of truth; this repo embeds copies for the
# container build. .git and .DS_Store are excluded.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DEV_ROOT="${MOODLE_DEV_ROOT:-${REPO_ROOT}/../moodle-dev}"

if [[ ! -d "${DEV_ROOT}" ]]; then
  echo "error: ${DEV_ROOT} not found. Set MOODLE_DEV_ROOT or place moodle-dev next to psa-moodle." >&2
  exit 1
fi

# Mapping: source dir in moodle-dev/plugins  ->  Moodle component path in plugins/
#   (component path matches Moodle's directory layout so Containerfile COPYs
#   land in the right place: blocks/X, local/X, mod/X, theme/X)
plugins=(
  "course_search:blocks/course_search"
  "githubsync:local/githubsync"
  "psaelmsync:local/psaelmsync"
  "pathcurator:mod/pathcurator"
)

rsync_flags=(
  --archive
  --delete
  --exclude='.git'
  --exclude='.git/**'
  --exclude='.DS_Store'
  --exclude='node_modules'
)

for entry in "${plugins[@]}"; do
  src_name="${entry%%:*}"
  dst_path="${entry##*:}"
  src="${DEV_ROOT}/plugins/${src_name}/"
  dst="${REPO_ROOT}/plugins/${dst_path}/"

  if [[ ! -d "${src}" ]]; then
    echo "skip: ${src} not found"
    continue
  fi

  mkdir -p "${dst}"
  echo "sync: ${src_name} -> plugins/${dst_path}/"
  rsync "${rsync_flags[@]}" "${src}" "${dst}"
done

# Child theme
theme_src="${DEV_ROOT}/themes/bcgovpsa/"
theme_dst="${REPO_ROOT}/themes/bcgovpsa/"
if [[ -d "${theme_src}" ]]; then
  mkdir -p "${theme_dst}"
  echo "sync: theme_bcgovpsa -> themes/bcgovpsa/"
  rsync "${rsync_flags[@]}" "${theme_src}" "${theme_dst}"
else
  echo "skip: ${theme_src} not found"
fi

echo "done."
