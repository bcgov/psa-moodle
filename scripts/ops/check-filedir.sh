#!/usr/bin/env bash
# check-filedir (runbook §8.3, §13.2, §14, §15; kept after Phase 5: restores use it too): does a filedir hold every file a database references, intact?
#
#   check-filedir.sh <filedir> <referenced.tsv> [<known-missing.txt>]
#
#   referenced.tsv      output of referenced-files.sql against the database being checked (hash, min size, max size)
#   known-missing.txt   content hashes accepted as missing (expected-differences.md); one per line, # comments allowed
#
# Every referenced hash must exist at <filedir>/<h:0:2>/<h:2:2>/<h>, with the recorded size, and its SHA-1 must equal
# its name. Prints counts and the offending hashes (hashes only: no names, paths or users).
# Exit 0 only if nothing is missing outside the known list and no file has a wrong size or a wrong SHA-1; also fails if
# the database records two sizes for one hash, or a known-missing hash is in fact present (the list is out of date).
set -euo pipefail
FILEDIR=${1:?filedir}; REF=${2:?referenced.tsv}; KNOWN=${3:-/dev/null}
[ -d "$FILEDIR" ] || { echo "no such filedir: $FILEDIR" >&2; exit 2; }
if command -v sha1sum >/dev/null; then sha1() { sha1sum "$@"; }; else sha1() { shasum -a 1 "$@"; }; fi
if stat -c %s /dev/null >/dev/null 2>&1; then size() { stat -c %s "$1"; }; else size() { stat -f %z "$1"; }; fi
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
grep -v '^\s*#' "$KNOWN" | awk 'NF {print $1}' | sort -u > "$work/known"

total=0; ok=0; : > "$work/missing"; : > "$work/size"; : > "$work/sha1"; : > "$work/inconsistent"; : > "$work/present"
while IFS=$'\t' read -r h min max; do
  [ -n "$h" ] || continue
  total=$((total + 1))
  [ "$min" = "$max" ] || echo "$h" >> "$work/inconsistent"
  f="$FILEDIR/${h:0:2}/${h:2:2}/$h"
  if [ ! -f "$f" ]; then echo "$h" >> "$work/missing"; continue; fi
  echo "$h" >> "$work/present"
  [ "$(size "$f")" = "$max" ] || { echo "$h" >> "$work/size"; continue; }
  [ "$(sha1 "$f" | cut -d' ' -f1)" = "$h" ] || { echo "$h" >> "$work/sha1"; continue; }
  ok=$((ok + 1))
done < "$REF"

sort -o "$work/missing" "$work/missing"; sort -o "$work/present" "$work/present"
# Set differences with awk, not comm (busybox has no comm). FILENAME, not NR==FNR, so an empty known list still works.
awk -v K="$work/known" 'FILENAME == K {k[$1] = 1; next} !($1 in k)' "$work/known" "$work/missing" > "$work/unexpected"
awk -v K="$work/known" 'FILENAME == K {k[$1] = 1; next} ($1 in k)' "$work/known" "$work/present" > "$work/stale"
n() { wc -l < "$1" | tr -d ' '; }
echo "referenced: $total; intact: $ok; missing: $(n "$work/missing") (known: $(( $(n "$work/missing") - $(n "$work/unexpected") )), unexpected: $(n "$work/unexpected")); wrong size: $(n "$work/size"); wrong SHA-1: $(n "$work/sha1"); two sizes in the database: $(n "$work/inconsistent"); known-missing but present: $(n "$work/stale")"
for k in unexpected size sha1 inconsistent stale; do
  [ -s "$work/$k" ] && { echo "-- $k:"; head -50 "$work/$k"; }
done
[ ! -s "$work/unexpected" ] && [ ! -s "$work/size" ] && [ ! -s "$work/sha1" ] && [ ! -s "$work/inconsistent" ] && [ ! -s "$work/stale" ]
