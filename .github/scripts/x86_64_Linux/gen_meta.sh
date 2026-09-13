#!/usr/bin/env bash
#
# Regenerate METADATA.json (and the checksum/size/file listings) from GHCR.
#
# GHCR is the source of truth. The files committed under x86_64-Linux/ are a
# cross-check, not an input -- so a build that silently published nothing
# cannot be masked by last run's committed data.
#
# Everything the old R2 round-trip needed a separate file for is carried by
# the manifest itself:
#
#   SHA256SUM.txt  -> layers[i].digest      (ORAS pushes raw blobs, so the
#                                            layer digest IS the file sha256)
#   BLAKE3SUM.txt  -> annotations[...b3sum]
#   FILE.txt       -> annotations[...file]
#   SIZE.txt       -> layers[i].size
#   ModTime        -> manifest ...image.created (real build time)
#
# Usage:
#   ./gen_meta.sh                 # regenerate into x86_64-Linux/
#   ./gen_meta.sh --dry-run       # build metadata, run gates, write nothing

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
BINS_DIR="${SCRIPT_DIR}/bins"
OUTDIR="${REPO_ROOT}/x86_64-Linux"
RECIPES_FILE="${SCRIPT_DIR}/RECIPES.txt"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

GHCR_OWNER="${GHCR_OWNER:-${GITHUB_REPOSITORY_OWNER:-}}"
[ -z "$GHCR_OWNER" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && GHCR_OWNER="${GITHUB_REPOSITORY%%/*}"
GHCR_OWNER="$(echo "$GHCR_OWNER" | tr '[:upper:]' '[:lower:]')"
GHCR_NAMESPACE="${GHCR_NAMESPACE:-toolpacks}"
OWNER_TYPE="${GHCR_OWNER_TYPE:-org}"

for c in jq oras curl; do
    command -v "$c" >/dev/null 2>&1 || { echo "[-] FATAL: ${c} not found" >&2; exit 1; }
done
[ -n "$GHCR_OWNER" ] || { echo "[-] FATAL: GHCR_OWNER unset" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
GH_API="https://api.github.com"
AUTH=(); [ -n "${GITHUB_TOKEN:-}" ] && AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

#-----------------------------------------------------------------------------#
# 1. List every published package, following Link: rel="next" to exhaustion.
#    Truncating at page 1 would silently drop most of the catalogue.
#-----------------------------------------------------------------------------#
echo "[*] listing packages for ${OWNER_TYPE}/${GHCR_OWNER}"
scope="orgs/${GHCR_OWNER}"; [ "$OWNER_TYPE" = "user" ] && scope="users/${GHCR_OWNER}"
url="${GH_API}/${scope}/packages?package_type=container&per_page=100"
: > "${TMP}/packages.txt"
pages=0
while [ -n "$url" ]; do
    pages=$((pages+1))
    curl -fsSL -D "${TMP}/h" "${AUTH[@]}" "$url" -o "${TMP}/p.json" 2>/dev/null || break
    jq -r '.[].name' "${TMP}/p.json" 2>/dev/null >> "${TMP}/packages.txt"
    url="$(grep -i '^link:' "${TMP}/h" | tr ',' '\n' | grep 'rel="next"' \
           | sed -E 's/.*<([^>]+)>.*/\1/' | head -1)"
done
# Only our namespace, and strip the namespace prefix to get the family name.
grep "^${GHCR_NAMESPACE}/" "${TMP}/packages.txt" 2>/dev/null \
  | sed "s|^${GHCR_NAMESPACE}/||" | sort -u > "${TMP}/families.txt" || true
N_PKG=$(wc -l < "${TMP}/families.txt")
echo "    ${N_PKG} package(s) across ${pages} page(s)"

if [ "$N_PKG" -eq 0 ]; then
    echo "[-] FATAL: no packages found. Either nothing has been published, or"
    echo "           the packages are private and this token cannot see them." >&2
    exit 1
fi

#-----------------------------------------------------------------------------#
# 2. Fetch each manifest (parallel) and flatten layers -> one row per binary.
#-----------------------------------------------------------------------------#
echo "[*] fetching manifests"
mkdir -p "${TMP}/manifests"
fetch_one() {
    local fam="$1"
    oras manifest fetch "ghcr.io/${GHCR_OWNER}/${GHCR_NAMESPACE}/${fam}:latest" \
      > "${TMP}/manifests/${fam}.json" 2>/dev/null || rm -f "${TMP}/manifests/${fam}.json"
}
export -f fetch_one; export TMP GHCR_OWNER GHCR_NAMESPACE
xargs -a "${TMP}/families.txt" -P 16 -I{} bash -c 'fetch_one "$@"' _ {} 2>/dev/null

N_MAN=$(find "${TMP}/manifests" -name '*.json' | wc -l)
echo "    ${N_MAN} manifest(s) fetched"

# Assert every listed package produced a manifest. A gap here usually means
# the package name was not URL-encoded somewhere, or it went private.
if [ "$N_MAN" -ne "$N_PKG" ]; then
    echo "[-] FATAL: listed ${N_PKG} packages but fetched ${N_MAN} manifests" >&2
    comm -23 "${TMP}/families.txt" \
      <(find "${TMP}/manifests" -name '*.json' -printf '%f\n' | sed 's/\.json$//' | sort) \
      | sed 's/^/      missing: /' >&2
    exit 1
fi

#-----------------------------------------------------------------------------#
# 3. Repo metadata, cached by repo_url. Many recipes share one upstream repo,
#    and the old script burned ~2800 API calls against a 5000/hr budget.
#-----------------------------------------------------------------------------#
mkdir -p "${TMP}/repo"
repo_meta() {
    local repo_url="$1" slug key out
    slug="$(echo "$repo_url" | sed -E 's|https?://github.com/||; s|/$||; s|\.git$||')"
    case "$slug" in */*) ;; *) echo '{}'; return;; esac
    key="$(echo "$slug" | tr '/' '_')"
    out="${TMP}/repo/${key}.json"
    if [ ! -f "$out" ]; then
        curl -fsSL "${AUTH[@]}" "${GH_API}/repos/${slug}" -o "$out" 2>/dev/null \
          || echo '{}' > "$out"
        # Back off on secondary rate limits rather than silently emitting {}.
        if jq -e '.message? // empty | test("rate limit|abuse")' "$out" >/dev/null 2>&1; then
            sleep 60
            curl -fsSL "${AUTH[@]}" "${GH_API}/repos/${slug}" -o "$out" 2>/dev/null || echo '{}' > "$out"
        fi
    fi
    cat "$out"
}

#-----------------------------------------------------------------------------#
# 4. Build METADATA.json: one entry per binary, keyed by family.
#-----------------------------------------------------------------------------#
echo "[*] building metadata"
: > "${TMP}/entries.jsonl"
while IFS= read -r fam; do
    man="${TMP}/manifests/${fam}.json"
    [ -s "$man" ] || continue

    # Handle both an image manifest and an index; an index has .layers == null
    # and would otherwise make the whole family vanish without an error.
    if [ "$(jq -r '.layers // "null"' "$man")" = "null" ]; then
        echo "[!] ${fam}: manifest is an index, not an image manifest; skipping" >&2
        continue
    fi

    created="$(jq -r '.annotations["org.opencontainers.image.created"] // ""' "$man")"
    yaml="${BINS_DIR}/${fam}.yaml"
    if [ -f "$yaml" ]; then
        description="$(yq -r '.description // ""' "$yaml" 2>/dev/null)"
        note="$(yq -r '.note // ""' "$yaml" 2>/dev/null)"
        repo_url="$(yq -r '.repo_url // ""' "$yaml" 2>/dev/null)"
        web_url="$(yq -r '.web_url // ""' "$yaml" 2>/dev/null)"
        all_bins="$(yq -r '.bins[]?' "$yaml" 2>/dev/null | paste -sd, -)"
    else
        description=""; note=""; repo_url=""; web_url=""; all_bins=""
    fi

    rj="$(repo_meta "$repo_url")"
    rel="$(echo "$rj" | jq -r '.pushed_at // ""')"

    jq -c \
      --arg fam "$fam" --arg created "$created" \
      --arg description "$description" --arg note "$note" \
      --arg repo_url "$repo_url" --arg web_url "$web_url" \
      --arg all_bins "$all_bins" \
      --arg owner "$GHCR_OWNER" --arg ns "$GHCR_NAMESPACE" \
      --arg repo "${GITHUB_REPOSITORY:-}" \
      --argjson rj "${rj:-{\}}" \
      '
      .layers[] | select(.annotations["org.opencontainers.image.title"] != null) |
      {
        name:          .annotations["org.opencontainers.image.title"],
        pkg_family:    $fam,
        description:   $description,
        note:          $note,
        download_url:  ("https://ghcr.io/v2/" + $owner + "/" + $ns + "/" + $fam + "/blobs/" + .digest),
        ghcr_pkg:      ("ghcr.io/" + $owner + "/" + $ns + "/" + $fam + ":latest"),
        ghcr_digest:   .digest,
        size_bytes:    .size,
        size:          (if .size >= 1073741824 then ((.size/1073741824*100|floor)/100|tostring) + " GB"
                        elif .size >= 1048576  then ((.size/1048576*100|floor)/100|tostring) + " MB"
                        elif .size >= 1024     then ((.size/1024*100|floor)/100|tostring) + " KB"
                        else (.size|tostring) + " B" end),
        b3sum:         (.annotations["dev.toolpacks.b3sum"] // ""),
        sha256:        (.digest | sub("^sha256:";"")),
        file:          (.annotations["dev.toolpacks.file"] // ""),
        build_date:    $created,
        repo_url:      $repo_url,
        repo_author:   ($rj.owner.login // ""),
        repo_info:     ($rj.description // ""),
        repo_updated:  ($rj.updated_at // ""),
        repo_released: ($rj.pushed_at // ""),
        repo_stars:    (($rj.stargazers_count // "") | tostring),
        repo_language: ($rj.language // ""),
        repo_license:  ($rj.license.name // ""),
        repo_topics:   (($rj.topics // []) | join(", ")),
        web_url:       $web_url,
        build_script:  ("https://github.com/" + $repo + "/tree/main/.github/scripts/x86_64_Linux/bins/" + $fam + ".sh"),
        build_log:     ("https://github.com/" + $repo + "/tree/main/x86_64-Linux/logs/" + $fam + ".log.txt"),
        extra_bins:    $all_bins
      }' "$man" >> "${TMP}/entries.jsonl" 2>/dev/null
done < "${TMP}/families.txt"

jq -s 'sort_by(.name)' "${TMP}/entries.jsonl" > "${TMP}/METADATA.json"
N_ENTRIES=$(jq 'length' "${TMP}/METADATA.json")
echo "    ${N_ENTRIES} binary entries"

#-----------------------------------------------------------------------------#
# 5. GATES. The count gate alone is what let empty checksums ship last time.
#-----------------------------------------------------------------------------#
echo "[*] gates"
rc=0

EMPTY=$(jq '[.[] | select(.b3sum=="" or .sha256=="" or .download_url=="" or .pkg_family=="" or .name=="")] | length' "${TMP}/METADATA.json")
if [ "$EMPTY" -ne 0 ]; then
    echo "[-] GATE FAILED: ${EMPTY} entries have an empty required field" >&2
    jq -r '.[] | select(.b3sum=="" or .sha256=="" or .download_url=="" or .pkg_family=="" or .name=="") | "      \(.pkg_family)/\(.name)"' "${TMP}/METADATA.json" | head -20 >&2
    rc=1
else
    echo "    [+] no empty required fields"
fi

if [ -s "$RECIPES_FILE" ]; then
    EXPECTED=$(wc -l < "$RECIPES_FILE")
    LOW=$(( EXPECTED * 80 / 100 ))
    if [ "$N_PKG" -lt "$LOW" ]; then
        echo "[-] GATE FAILED: only ${N_PKG} packages for ${EXPECTED} recipes (<80%)" >&2
        rc=1
    else
        echo "    [+] package count ${N_PKG} vs ${EXPECTED} recipes"
    fi
fi

DUPE=$(jq -r '[.[].name] | group_by(.) | map(select(length>1)) | length' "${TMP}/METADATA.json")
[ "$DUPE" -ne 0 ] && echo "    [!] ${DUPE} duplicate binary name(s) across families"

if [ "$rc" -ne 0 ]; then
    echo "[-] gates failed; not writing output" >&2
    exit 1
fi

#-----------------------------------------------------------------------------#
# 6. Emit. Cross-check against what is currently committed before overwriting.
#-----------------------------------------------------------------------------#
if [ -f "${OUTDIR}/METADATA.json" ]; then
    OLD=$(jq -r '.[] | if type=="array" then .[] else . end | .name' "${OUTDIR}/METADATA.json" 2>/dev/null | sort -u)
    NEW=$(jq -r '.[].name' "${TMP}/METADATA.json" | sort -u)
    GONE=$(comm -23 <(echo "$OLD") <(echo "$NEW") | wc -l)
    ADDED=$(comm -13 <(echo "$OLD") <(echo "$NEW") | wc -l)
    echo "    [i] vs committed: ${ADDED} new, ${GONE} no longer present"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "[+] dry run; wrote nothing. Metadata at ${TMP}/METADATA.json"
    cp "${TMP}/METADATA.json" "${SYSTMP:-/tmp}/METADATA.preview.json" 2>/dev/null || true
    exit 0
fi

mkdir -p "$OUTDIR"
cp "${TMP}/METADATA.json" "${OUTDIR}/METADATA.json"
jq -r '.[] | "\(.b3sum)  \(.name)"'                "${TMP}/METADATA.json" > "${OUTDIR}/BLAKE3SUM.txt"
jq -r '.[] | "\(.sha256)  \(.name)"'               "${TMP}/METADATA.json" > "${OUTDIR}/SHA256SUM.txt"
jq -r '.[] | "\(.name): \(.file)"'                 "${TMP}/METADATA.json" > "${OUTDIR}/FILE.txt"
jq -r '.[] | "\(.size)\t\(.name)"'                 "${TMP}/METADATA.json" > "${OUTDIR}/SIZE.txt"
jq -r '.[] | "\(.build_date) --> [\(.name)]"'      "${TMP}/METADATA.json" | sort > "${OUTDIR}/BUILD_DATES.txt"
command -v yq >/dev/null 2>&1 && jq . "${OUTDIR}/METADATA.json" | yq -p json -o yaml > "${OUTDIR}/METADATA.yaml" 2>/dev/null

echo "[+] wrote ${OUTDIR}/{METADATA.json,BLAKE3SUM.txt,SHA256SUM.txt,FILE.txt,SIZE.txt,BUILD_DATES.txt}"
