#!/usr/bin/env bash
# Assembles the licenses/ folder baked into the binary from licenses.manifest:
# shard texts are copied from disk; clib/runtime texts are grouped by SPDX id
# from the committed canonical texts in licenses-spdx/.
#
# WHY THIS EXISTS
#   A statically linked binary carries its dependencies' code, so it has to
#   carry their notices too. Harvesting them at build time — rather than
#   committing a hand-written NOTICE that rots — keeps the shipped artifact
#   honest as the dependency list moves.
#
# WHERE IT GOES
#   scripts/harvest-licenses.sh, driven by the `dev:licenses` mise task, which
#   every task that compiles the application declares in its `depends`. The
#   folder is generated, so it belongs in .gitignore — and a CI job that runs a
#   compiling task standalone will otherwise fail at macro time, since the
#   folder is read while the compiler runs.
#
# THE TWO INPUTS THE PROJECT OWNS
#   licenses.manifest — one entry per line, `kind | name | source`:
#       shard   | mcp      | lib/mcp/LICENSE      on-disk text, copied verbatim
#       project | myapp    | LICENSE              same, for the project itself
#       clib    | openssl  | Apache-2.0           SPDX id, grouped by that id
#       runtime | libgc    | Boehm-GC             same
#       clib    | libyaml  | licenses-upstream/libyaml.txt
#                                                 on-disk text, copied verbatim
#     `#` starts a comment. shard/project entries carry a real copyright line,
#     so they are copied as-is; clib/runtime entries share one canonical text
#     between several dependencies, hence the grouping.
#
#     A clib/runtime source that is a file is copied verbatim instead. That is
#     the form to use whenever the license asks for the copyright notice to be
#     reproduced (MIT, BSD, zlib): the SPDX text of those is a template whose
#     copyright line is a blank (`<year> <copyright holders>`), and shipping
#     the blank is shipping no notice. Commit the library's own license file,
#     taken from its sources at the version actually linked.
#   licenses-spdx/<id>.txt — the canonical text of each SPDX id used above,
#     committed once and never edited.
#
# The missing-file cases are hard errors on purpose: a notice silently absent
# from a redistributed binary is the failure this script exists to prevent.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MANIFEST=licenses.manifest
OUT=licenses

# A project that bakes no licenses can delete this script, the task and its
# `depends`. Until it does, skipping cleanly beats failing every build.
if [ ! -f "$MANIFEST" ]; then
  echo "harvest: no $MANIFEST, nothing to assemble"
  exit 0
fi

# Assembled beside the output, then swapped in by two renames: every compiling
# task depends on this script and reads licenses/ at macro time, so a second
# task started meanwhile must never see the directory half filled. (It can miss
# it for the instant between the two renames: a directory cannot be replaced by
# another in one step.)
BUILD="$OUT.tmp.$$"
trap 'rm -rf "$BUILD"' EXIT
rm -rf "$BUILD"
mkdir -p "$BUILD"

# clib/runtime licenses are grouped by SPDX id. macOS ships bash 3.2 (no
# associative arrays), so accumulate the "used by" names in per-id list files
# under a hidden scratch dir instead of `declare -A`. The dir is removed before
# the final count so it never lands in the baked output.
SCRATCH="$BUILD/.used"
mkdir -p "$SCRATCH"

while IFS='|' read -r kind name source; do
  kind="$(echo "$kind" | tr -d '[:space:]')"
  name="$(echo "$name" | tr -d '[:space:]')"
  source="$(echo "$source" | tr -d '[:space:]')"
  [ -z "$kind" ] && continue
  case "$kind" in
    \#*) continue ;;
  esac
  # An empty name would write a hidden ".txt" nothing embeds; a repeated one
  # would overwrite the notice written for the first. Either way a notice
  # would go missing without a word.
  if [ -z "$name" ]; then
    echo "harvest: an entry of kind '$kind' has no name" >&2
    exit 1
  fi
  if [ -e "$BUILD/$name.txt" ] || grep -qx "$name" "$SCRATCH/names" 2>/dev/null; then
    echo "harvest: two entries are named '$name'" >&2
    exit 1
  fi
  echo "$name" >> "$SCRATCH/names"
  case "$kind" in
    shard|project)
      # On-disk license text copied verbatim (carries a real copyright line):
      # shards from lib/<name>/LICENSE, the project from the root LICENSE.
      if [ ! -f "$source" ]; then
        echo "harvest: missing license '$source' for '$name' (run shards install / the submodule plan)" >&2
        exit 1
      fi
      cp "$source" "$BUILD/$name.txt"
      ;;
    clib|runtime)
      if [ -f "$source" ]; then
        # The library's own license file: verbatim, under the library's name.
        cp "$source" "$BUILD/$name.txt"
      elif [ -f "licenses-spdx/$source.txt" ]; then
        echo "$name" >> "$SCRATCH/$source.list"
      else
        echo "harvest: '$source' for '$name' is neither a file nor an SPDX id of licenses-spdx/" >&2
        exit 1
      fi
      ;;
    *)
      # A misspelt kind would otherwise drop the notice without a word.
      echo "harvest: unknown kind '$kind' for '$name' (expected shard, project, clib or runtime)" >&2
      exit 1
      ;;
  esac
done < <(grep -v '^#' "$MANIFEST")

# Sorted glob → deterministic baked output. Join the accumulated names with ", ".
for list in "$SCRATCH"/*.list; do
  [ -e "$list" ] || continue
  id="$(basename "$list" .list)"
  names="$(awk 'NR>1{printf ", "} {printf "%s", $0} END{print ""}' "$list")"
  {
    echo "Used by: $names"
    echo
    cat "licenses-spdx/$id.txt"
  } > "$BUILD/clib-$id.txt"
done

rm -rf "$SCRATCH"

# `mv` onto a directory that exists moves INTO it. When another run swapped its
# own output in between the two renames below, ours lands inside it: that
# output is complete and comes from the same manifest, so ours is dropped.
OLD="$OUT.old.$$"
rm -rf "$OLD"
if [ -d "$OUT" ]; then mv "$OUT" "$OLD" 2>/dev/null || true; fi
mv "$BUILD" "$OUT"
rm -rf "$OLD" "$OUT/$(basename "$BUILD")"

echo "harvested $(find "$OUT" -maxdepth 1 -type f | wc -l | tr -d ' ') license files into $OUT/"
