#!/usr/bin/env bash
#
# Generate the end-user installers from the recipe allowlist.
#
# The old installers did one plain `curl` per tool against a flat CDN path.
# GHCR has no flat path: a blob needs an anonymous bearer token and the
# manifest must be read to find which layer holds the requested binary.
# That logic is written once here, not 141 times.
#
# The generated scripts parse JSON with sed, never jq -- they must work on a
# bare box where jq is one of the tools being installed. curl is the only
# assumed dependency, which is what the originals already required.
#
# Usage:
#   ./gen_installers.sh             # regenerate installers/
#   ./gen_installers.sh --check     # verify they are current (CI)

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BINS_DIR="${SCRIPT_DIR}/bins"
OUT_DIR="${SCRIPT_DIR}/installers"
RECIPES_FILE="${SCRIPT_DIR}/RECIPES.txt"
DROP_FILE="${SCRIPT_DIR}/DROPPED.txt"

CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# binary -> family, from each recipe's declared bins:
awk '
  FNR==1 { r=FILENAME; sub(/.*\//,"",r); sub(/\.yaml$/,"",r); inb=0 }
  /^bins:/ { inb=1; next }
  inb && /^[[:space:]]+- / { b=$0; sub(/^[[:space:]]+-[[:space:]]*"?/,"",b); sub(/"[[:space:]]*$/,"",b);
                             if (b!="") print b "\t" r; next }
  inb && /^[^[:space:]]/ { inb=0 }
' "$BINS_DIR"/*.yaml | sort -u > "${TMP}/bin2fam.tsv"

sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$DROP_FILE" | sort -u > "${TMP}/drop"

emit_header() {
cat <<'HDR'
#!/usr/bin/env bash

##Requires: coreutils + curl
##
## Binaries are served from GHCR. A blob needs an anonymous bearer token and
## a manifest lookup, so this is not a plain one-curl-per-file fetch.
##
## JSON here is parsed with sed on purpose: jq is one of the tools this
## script installs, so it cannot be a prerequisite for running it.

#-------------------------------------------------------------------------------#
 set +e
#Check curl
 if ! command -v curl &> /dev/null; then
     echo -e "\n[-] FATAL: curl is required\n"
   exit 1
 fi
#Check install dirs & sudo
 if [ -z "${INSTALL_DIR:-}" ]; then
     if command -v sudo &> /dev/null && sudo -n true 2>/dev/null; then
         export INSTALL_DIR="/usr/local/bin"
         sudo mkdir -p "${INSTALL_DIR}"
         export SUDO="sudo"
         echo -e "\n[+] Install Dir (ROOT) :: ${INSTALL_DIR}\n"
     else
         export INSTALL_DIR="$HOME/bin"
         mkdir -p "${INSTALL_DIR}"
         export SUDO=""
         echo -e "\n[+] Install Dir (USERSPACE) :: ${INSTALL_DIR}\n"
     fi
 else
     mkdir -p "${INSTALL_DIR}" 2>/dev/null || sudo mkdir -p "${INSTALL_DIR}"
     if command -v sudo &> /dev/null && sudo -n true 2>/dev/null; then export SUDO="sudo"; else export SUDO=""; fi
 fi
#Registry
 export GHCR_OWNER="${GHCR_OWNER:-@@OWNER@@}"
 export GHCR_NAMESPACE="${GHCR_NAMESPACE:-@@NAMESPACE@@}"
 export REGISTRY="${REGISTRY:-ghcr.io}"
 if [ -z "${GHCR_OWNER}" ] || [ "${GHCR_OWNER}" = "UNSET" ]; then
     echo -e "\n[-] FATAL: GHCR_OWNER is not set."
     echo -e "    This installer was generated without a registry owner baked in."
     echo -e "    Re-run with:  GHCR_OWNER=<github-user-or-org> bash $0"
     echo -e "    or regenerate it with GHCR_OWNER set.\n"
   exit 1
 fi
 echo -e "[+] Source :: ${REGISTRY}/${GHCR_OWNER}/${GHCR_NAMESPACE}\n"
#-------------------------------------------------------------------------------#

#-------------------------------------------------------------------------------#
##Registry plumbing
#Tokens are scoped per package, so cache one per family.
 TOKEN_CACHE="$(mktemp -d)"
 trap 'rm -rf "${TOKEN_CACHE}"' EXIT

 get_token()
 {
   local family="$1" cache="${TOKEN_CACHE}/${family}"
   if [ -s "${cache}" ]; then cat "${cache}"; return 0; fi
   curl -qfsSL "https://${REGISTRY}/token?scope=repository:${GHCR_OWNER}/${GHCR_NAMESPACE}/${family}:pull&service=${REGISTRY}" \
     | sed -n 's/.*"token":"\([^"]*\)".*/\1/p' > "${cache}" 2>/dev/null
   [ -s "${cache}" ] || return 1
   cat "${cache}"
 }

#Each layer of a manifest is one binary, titled with its name. Splitting the
#layer array on "},{" puts each layer on its own line, so the digest and the
#title that belong together stay together.
 get_digest()
 {
   local family="$1" tool="$2" token="$3"
   curl -qfsSL -H "Authorization: Bearer ${token}" \
        -H "Accept: application/vnd.oci.image.manifest.v1+json" \
        "https://${REGISTRY}/v2/${GHCR_OWNER}/${GHCR_NAMESPACE}/${family}/manifests/latest" \
     | sed 's/},{/}\n{/g' \
     | grep "\"org.opencontainers.image.title\":\"${tool}\"" \
     | sed -n 's/.*"digest":"\(sha256:[a-f0-9]*\)".*/\1/p' \
     | head -1
 }

 OK_N=0 ; FAIL_N=0 ; FAILED=""

 fetch_tool()
 {
   local tool="$1" family="$2" dest="${INSTALL_DIR}/$3"
   local token digest
   token="$(get_token "${family}")"
   if [ -z "${token}" ]; then
     echo "[-] ${tool}: could not get a registry token (is the package public?)"
     FAIL_N=$((FAIL_N+1)) ; FAILED="${FAILED} ${tool}" ; return 1
   fi
   digest="$(get_digest "${family}" "${tool}" "${token}")"
   if [ -z "${digest}" ]; then
     echo "[-] ${tool}: not found in package ${family}"
     FAIL_N=$((FAIL_N+1)) ; FAILED="${FAILED} ${tool}" ; return 1
   fi
   if ! curl -qfsSL -H "Authorization: Bearer ${token}" \
        "https://${REGISTRY}/v2/${GHCR_OWNER}/${GHCR_NAMESPACE}/${family}/blobs/${digest}" \
        -o "${dest}.tmp" 2>/dev/null; then
     echo "[-] ${tool}: download failed"
     rm -f "${dest}.tmp" 2>/dev/null
     FAIL_N=$((FAIL_N+1)) ; FAILED="${FAILED} ${tool}" ; return 1
   fi
   # Only replace an existing binary once the new one is fully downloaded.
   ${SUDO} mv -f "${dest}.tmp" "${dest}" 2>/dev/null || mv -f "${dest}.tmp" "${dest}"
   ${SUDO} chmod +x "${dest}" 2>/dev/null || chmod +x "${dest}"
   OK_N=$((OK_N+1))
   echo "[+] ${tool}"
 }
#-------------------------------------------------------------------------------#

#-------------------------------------------------------------------------------#
##Fetch
HDR
}

emit_footer() {
cat <<'FTR'
#-------------------------------------------------------------------------------#

#-------------------------------------------------------------------------------#
##Summary
 echo -e "\n[+] Installed :: ${OK_N}"
 if [ "${FAIL_N}" -gt 0 ]; then
    echo -e "[-] Failed    :: ${FAIL_N} -->${FAILED}\n"
 else
    echo -e "[-] Failed    :: 0\n"
 fi
 case ":${PATH}:" in
   *":${INSTALL_DIR}:"*) ;;
   *) echo -e "[!] ${INSTALL_DIR} is not on your \$PATH\n" ;;
 esac
 [ "${FAIL_N}" -eq 0 ]
#-------------------------------------------------------------------------------#
FTR
}

generate() {
    local src="$1" out="$2"
    # Tools this installer asks for, in its original order.
    grep -ohE '\$\{INSTALL_SRC\}/[A-Za-z0-9._/+-]+' "$src" | sed 's|.*/||' > "${TMP}/tools.raw"

    emit_header \
      | sed -e "s|@@OWNER@@|${GHCR_OWNER:-UNSET}|g" \
            -e "s|@@NAMESPACE@@|${GHCR_NAMESPACE:-toolpacks}|g" > "$out"
    local n=0 skipped=0
    while IFS= read -r tool; do
        [ -n "$tool" ] || continue
        local fam
        # A tool name can be declared by several families -- busybox alone
        # declares 396 applets, including real tools like wget and dos2unix,
        # and sorts first alphabetically. Always prefer the family whose own
        # name matches the tool, or users get the busybox applet instead of
        # the real binary.
        if grep -qxF "$tool" "$RECIPES_FILE" 2>/dev/null \
           && awk -F'\t' -v t="$tool" '$1==t && $2==t{f=1} END{exit !f}' "${TMP}/bin2fam.tsv"; then
            fam="$tool"
        else
            fam="$(awk -F'\t' -v t="$tool" '$1==t{print $2; exit}' "${TMP}/bin2fam.tsv")"
        fi
        # Unresolvable, or deliberately dropped -> omit, so a user never
        # curls a 404.
        if [ -z "$fam" ] || grep -qxF "$fam" "${TMP}/drop"; then
            skipped=$((skipped+1)); continue
        fi
        grep -qxF "$fam" "$RECIPES_FILE" || { skipped=$((skipped+1)); continue; }
        printf ' fetch_tool "%s" "%s" "%s"\n' "$tool" "$fam" "$tool" >> "$out"
        n=$((n+1))
    done < <(sort -u "${TMP}/tools.raw")
    emit_footer >> "$out"
    chmod +x "$out"
    echo "    $(basename "$out"): ${n} tools (${skipped} omitted)"
}

mkdir -p "${TMP}/out"
for pair in "install_dev_tools" "install_bb_tools"; do
    src="${OUT_DIR}/upstream/${pair}.sh"
    generate "$src" "${TMP}/out/${pair}.sh"
done

if [ "$CHECK" -eq 1 ]; then
    rc=0
    for p in install_dev_tools install_bb_tools; do
        if ! diff -q "${TMP}/out/${p}.sh" "${OUT_DIR}/${p}.sh" >/dev/null 2>&1; then
            echo "[-] ${p}.sh is out of date. Regenerate with: $0" >&2
            rc=1
        fi
    done
    [ "$rc" -eq 0 ] && echo "[+] installers are current"
    exit "$rc"
fi

cp "${TMP}/out/install_dev_tools.sh" "${OUT_DIR}/install_dev_tools.sh"
cp "${TMP}/out/install_bb_tools.sh"  "${OUT_DIR}/install_bb_tools.sh"
echo "[+] wrote ${OUT_DIR}/install_{dev,bb}_tools.sh"
