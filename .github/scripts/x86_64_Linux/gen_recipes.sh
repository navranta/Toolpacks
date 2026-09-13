#!/usr/bin/env bash
#
# Generate RECIPES.txt: the explicit allowlist of recipes this build produces.
#
# Scope is defined by the two upstream installers (installers/upstream/),
# NOT by what happens to exist in bins/. The installers fetch binaries; this
# script resolves those binary names back to the recipes that produce them.
#
# Usage:
#   ./gen_recipes.sh              # write RECIPES.txt
#   ./gen_recipes.sh --check      # verify RECIPES.txt is current (CI); exit 1 on drift
#
# Hermetic: reads only files in this repo, so it passes the blackhole CI job.

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BINS_DIR="${SCRIPT_DIR}/bins"
INSTALLERS_DIR="${SCRIPT_DIR}/installers/upstream"
RECIPES_FILE="${SCRIPT_DIR}/RECIPES.txt"
DROP_FILE="${SCRIPT_DIR}/DROPPED.txt"

CHECK_MODE=0
[ "${1:-}" = "--check" ] && CHECK_MODE=1

for d in "$BINS_DIR" "$INSTALLERS_DIR"; do
  [ -d "$d" ] || { echo "[-] FATAL: missing directory: $d" >&2; exit 1; }
done
[ -f "$DROP_FILE" ] || { echo "[-] FATAL: missing drop list: $DROP_FILE" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

#-----------------------------------------------------------------------------#
# 1. Extract the tool names the installers fetch.
#    Both scripts fetch exclusively via "${INSTALL_SRC}/<path>".
#    Baseutils subpaths (e.g. Baseutils/libarchive/bsdtar) resolve to their
#    leaf binary name, which the yaml index below maps to the right recipe.
#-----------------------------------------------------------------------------#
grep -ohE '\$\{INSTALL_SRC\}/[A-Za-z0-9._/+-]+' "$INSTALLERS_DIR"/install_*.sh \
  | sed 's|.*/||' \
  | sort -u > "$TMP/tools.all"

[ -s "$TMP/tools.all" ] || { echo "[-] FATAL: extracted 0 tools from installers" >&2; exit 1; }

#-----------------------------------------------------------------------------#
# 2. Build a binary -> recipe index from every recipe's declared bins: list.
#    A recipe named X frequently produces binaries named something else
#    (colorized-logs -> ansi2txt, gitlab-cli -> glab, zerotier -> zerotier-cli).
#    The yaml is the only authoritative mapping.
#-----------------------------------------------------------------------------#
awk '
  FNR==1 { recipe=FILENAME; sub(/.*\//,"",recipe); sub(/\.yaml$/,"",recipe); in_bins=0 }
  /^bins:/            { in_bins=1; next }
  in_bins && /^[[:space:]]+- / {
      bin=$0
      sub(/^[[:space:]]+-[[:space:]]*"?/,"",bin)
      sub(/"[[:space:]]*$/,"",bin)
      if (bin != "") print bin "\t" recipe
      next
  }
  in_bins && /^[^[:space:]]/ { in_bins=0 }
' "$BINS_DIR"/*.yaml | sort -u > "$TMP/bin2recipe.tsv"

# A recipe always also answers to its own name, even if its yaml omits it.
for f in "$BINS_DIR"/*.yaml; do
  r="$(basename "$f" .yaml)"
  printf '%s\t%s\n' "$r" "$r"
done | sort -u >> "$TMP/bin2recipe.tsv"
sort -u "$TMP/bin2recipe.tsv" -o "$TMP/bin2recipe.tsv"

#-----------------------------------------------------------------------------#
# 3. Resolve tools -> recipes, tracking anything unresolvable.
#-----------------------------------------------------------------------------#
: > "$TMP/recipes.raw"
: > "$TMP/unresolved"
# A tool name can be declared by several recipes. busybox alone declares 396
# applets, including names that dedicated recipes own (wget, dos2unix, tar).
# When a recipe's own name matches the tool, that recipe is authoritative and
# is the only one pulled in -- otherwise requesting `wget` would also drag in
# busybox and publish its 396 applets that nobody asked for.
while IFS= read -r tool; do
  if awk -F'\t' -v t="$tool" '$1==t && $2==t {f=1} END{exit !f}' "$TMP/bin2recipe.tsv"; then
    printf '%s\n' "$tool" >> "$TMP/recipes.raw"
    continue
  fi
  hits="$(awk -F'\t' -v t="$tool" '$1==t {print $2}' "$TMP/bin2recipe.tsv")"
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" >> "$TMP/recipes.raw"
  else
    printf '%s\n' "$tool" >> "$TMP/unresolved"
  fi
done < "$TMP/tools.all"

#-----------------------------------------------------------------------------#
# 4. Subtract the deliberate drop list (recipe names, one per line, # comments).
#-----------------------------------------------------------------------------#
sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$DROP_FILE" | sort -u > "$TMP/drop"
sort -u "$TMP/recipes.raw" | comm -23 - "$TMP/drop" > "$TMP/recipes.final"

#-----------------------------------------------------------------------------#
# 5. Integrity: every emitted recipe must have BOTH a .sh and a .yaml.
#-----------------------------------------------------------------------------#
rc=0
while IFS= read -r r; do
  [ -f "$BINS_DIR/$r.sh" ]   || { echo "[-] missing recipe script: bins/$r.sh" >&2; rc=1; }
  [ -f "$BINS_DIR/$r.yaml" ] || { echo "[-] missing recipe yaml:   bins/$r.yaml" >&2; rc=1; }
done < "$TMP/recipes.final"
[ "$rc" -eq 0 ] || { echo "[-] FATAL: allowlist references recipes that do not exist" >&2; exit 1; }

# Every dropped name must be a real recipe or a known orphan tool, so that a
# typo in DROPPED.txt cannot silently fail to drop anything.
while IFS= read -r d; do
  if [ ! -f "$BINS_DIR/$d.sh" ] && ! grep -qxF "$d" "$TMP/unresolved" 2>/dev/null; then
    echo "[-] FATAL: DROPPED.txt lists '$d', which is neither a recipe nor an unresolved tool" >&2
    exit 1
  fi
done < "$TMP/drop"

#-----------------------------------------------------------------------------#
# 6. Emit or check.
#-----------------------------------------------------------------------------#
n_tools=$(wc -l < "$TMP/tools.all")
n_unres=$(wc -l < "$TMP/unresolved" 2>/dev/null || echo 0)
n_recipes=$(wc -l < "$TMP/recipes.final")

if [ "$CHECK_MODE" -eq 1 ]; then
  if ! diff -q "$TMP/recipes.final" "$RECIPES_FILE" >/dev/null 2>&1; then
    echo "[-] FATAL: RECIPES.txt is out of date. Regenerate with: $0" >&2
    diff -u "$RECIPES_FILE" "$TMP/recipes.final" >&2 || true
    exit 1
  fi
  echo "[+] RECIPES.txt is current (${n_recipes} recipes from ${n_tools} installer tools)"
else
  cp "$TMP/recipes.final" "$RECIPES_FILE"
  echo "[+] wrote ${RECIPES_FILE}"
fi

echo "    installer tools : ${n_tools}"
echo "    unresolved      : ${n_unres}"
echo "    dropped         : $(wc -l < "$TMP/drop")"
echo "    recipes         : ${n_recipes}"

if [ "$n_unres" -gt 0 ]; then
  echo "    ---- unresolved tools (no recipe produces these) ----"
  sed 's/^/      /' "$TMP/unresolved"
fi
