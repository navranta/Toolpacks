#!/usr/bin/env bash
#
# Fetch the bootstrap binaries this build needs before it can build anything.
#
# Every binary comes from its own upstream project's GitHub release. Nothing
# is pulled from a binary cache -- least of all this project's own output,
# which is what made the original bootstrap circular.
#
# This script is NOT run by the build. It is run by a human, deliberately,
# when a prebuilt needs updating, and the result is committed. Re-running it
# rewrites MANIFEST.txt so provenance always matches the bytes.
#
# Usage:
#   ./fetch.sh            # download + write MANIFEST.txt
#   ./fetch.sh --verify   # check committed binaries against MANIFEST.txt (CI)

set -euo pipefail
export LC_ALL=C

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${DIR}/MANIFEST.txt"
VERIFY=0
[ "${1:-}" = "--verify" ] && VERIFY=1

command -v curl >/dev/null || { echo "[-] FATAL: curl required" >&2; exit 1; }

# Checksums use sha256sum from coreutils, always. Deliberately NOT the
# vendored b3sum: the algorithm must not depend on whether a prebuilt happens
# to exist yet, or fetch and --verify silently disagree. It also means this
# script never executes a binary it just downloaded.
SUMCMD="sha256sum"; SUMNAME="sha256"

GH_API="https://api.github.com"
AUTH=()
[ -n "${GITHUB_TOKEN:-}" ] && AUTH=(-H "Authorization: Bearer ${GITHUB_TOKEN}")

# Resolve the asset download URL for the latest release of <repo> matching <regex>.
asset_url() {
    local repo="$1" pattern="$2"
    curl -fsSL "${AUTH[@]}" "${GH_API}/repos/${repo}/releases/latest" \
      | grep -oE '"browser_download_url": *"[^"]+"' \
      | sed 's/.*"browser_download_url": *"//; s/"$//' \
      | grep -iE "$pattern" | head -1
}

# name  repo  asset-regex  extract-path-inside-archive (empty = raw binary)
TOOLS=(
  "eget|zyedidia/eget|linux_amd64\.tar\.gz$|*/eget"
  "jq|jqlang/jq|jq-linux-amd64$|"
  "b3sum|BLAKE3-team/BLAKE3|b3sum_linux_x64_bin$|"
  "yq|mikefarah/yq|yq_linux_amd64$|"
  "oras|oras-project/oras|_linux_amd64\.tar\.gz$|oras"
)

if [ "$VERIFY" -eq 1 ]; then
    [ -f "$MANIFEST" ] || { echo "[-] FATAL: no MANIFEST.txt" >&2; exit 1; }
    rc=0
    while IFS='|' read -r name sum url date; do
        [ -z "${name:-}" ] && continue
        case "$name" in \#*) continue;; esac
        f="${DIR}/${name}"
        [ -f "$f" ] || { echo "[-] MISSING: $name"; rc=1; continue; }
        got="$($SUMCMD "$f" | awk '{print $1}')"
        if [ "$got" != "$sum" ]; then
            echo "[-] CHECKSUM MISMATCH: $name"
            echo "      manifest: $sum"
            echo "      actual:   $got"
            rc=1
        else
            echo "[+] ok: $name"
        fi
    done < "$MANIFEST"
    exit "$rc"
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
: > "${MANIFEST}.new"
{
  echo "# Bootstrap binaries, vendored from upstream project releases."
  echo "# Regenerate with ./fetch.sh ; verify with ./fetch.sh --verify"
  echo "# format: name|${SUMNAME}|source_url|retrieved"
} >> "${MANIFEST}.new"

for entry in "${TOOLS[@]}"; do
    IFS='|' read -r name repo pattern inner <<< "$entry"
    echo "[*] ${name} <- ${repo}"
    url="$(asset_url "$repo" "$pattern")"
    [ -n "$url" ] || { echo "[-] FATAL: no asset for ${repo} matching ${pattern}" >&2; exit 1; }

    out="${TMP}/${name}.dl"
    curl -fsSL "$url" -o "$out"

    if [ -z "$inner" ]; then
        cp "$out" "${DIR}/${name}"
    else
        ex="${TMP}/ex_${name}"; mkdir -p "$ex"
        tar -xzf "$out" -C "$ex"
        # shellcheck disable=SC2086
        src="$(find "$ex" -type f -path "*${inner##*/}" | head -1)"
        [ -n "$src" ] || { echo "[-] FATAL: ${inner} not found in ${name} archive" >&2; exit 1; }
        cp "$src" "${DIR}/${name}"
    fi
    chmod +x "${DIR}/${name}"

    # Validate by INSPECTION, never by execution. This script must be safe to
    # run on a workstation, and running a freshly downloaded binary to ask its
    # version is exactly the thing a supply-chain check should not do.
    # A dynamically linked bootstrap binary defeats the point and would break
    # on a different runner image, so that is a hard failure.
    if command -v file >/dev/null 2>&1; then
        desc="$(file -b "${DIR}/${name}")"
        case "$desc" in
            *ELF\ 64-bit*x86-64*) ;;
            *) echo "[-] FATAL: ${name} is not an x86-64 ELF: ${desc}" >&2; exit 1;;
        esac
        case "$desc" in
            *statically\ linked*|*static-pie\ linked*) ;;
            *) echo "[-] FATAL: ${name} is not statically linked: ${desc}" >&2; exit 1;;
        esac
    fi

    sum="$($SUMCMD "${DIR}/${name}" | awk '{print $1}')"
    printf '%s|%s|%s|%s\n' "$name" "$sum" "$url" "$(date -u +%Y-%m-%d)" >> "${MANIFEST}.new"
    printf '    %s  %s\n' "$(du -h "${DIR}/${name}" | cut -f1)" "$url"
done

mv "${MANIFEST}.new" "$MANIFEST"
echo
echo "[+] wrote ${MANIFEST}"
du -ch "${DIR}"/* 2>/dev/null | tail -1
