#!/usr/bin/env bash
#
# Publish built binaries to GHCR via ORAS. Sourced by build_debian.sh.
#
# One package per recipe family: ghcr.io/<owner>/toolpacks/<family>
#
# Why this replaces the old R2 + checksum-file round-trip entirely:
#
#   old source                 new source
#   -------------------------  --------------------------------------------
#   rclone lsjson .Path        layers[i].annotations["...image.title"]
#   rclone lsjson .Size        layers[i].size
#   rclone lsjson .ModTime     manifest "...image.created" (real build time,
#                              not an object mtime)
#   SHA256SUM.txt              layers[i].digest -- ORAS pushes raw blobs, so
#                              the layer digest IS the file's sha256, bound
#                              by the registry's content addressing. No
#                              annotation, and nothing to trust.
#   BLAKE3SUM.txt              layers[i].annotations["dev.toolpacks.b3sum"]
#   FILE.txt                   layers[i].annotations["dev.toolpacks.file"]
#
# And the union problem dissolves: GHCR holds exactly
#   (this run's successes) UNION (everything previously published),
# because push is additive per package and untouched packages keep :latest.
# There is no merge step to get wrong, and the published set is never
# reconstructed from $BINDIR.

#-------------------------------------------------------#
# Owner comes from the Actions context so nothing is hardcoded to one fork.
if [ -z "${GHCR_OWNER:-}" ]; then
    GHCR_OWNER="${GITHUB_REPOSITORY_OWNER:-}"
    if [ -z "${GHCR_OWNER}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
        GHCR_OWNER="${GITHUB_REPOSITORY%%/*}"
    fi
fi
# GHCR requires a lowercase namespace.
GHCR_OWNER="$(echo "${GHCR_OWNER}" | tr '[:upper:]' '[:lower:]')"
export GHCR_OWNER
export GHCR_NAMESPACE="${GHCR_NAMESPACE:-toolpacks}"
export GHCR_DATE_TAG="${GHCR_DATE_TAG:-$(date -u +%Y.%m.%d)}"

# Version tags are deliberately NOT upstream version strings. Only 2 of the
# in-scope recipes record what they built; repo_version in METADATA.json is
# computed later from the GitHub API and means "upstream's latest tag right
# now", which is false whenever upstream releases between build and metadata.
# :latest + :YYYY.MM.DD are both true statements, and the digest is the pin.

ghcr_available() {
    [ "${GHCR_PUSH:-YES}" = "YES" ] || return 1
    command -v oras >/dev/null 2>&1 || { echo "[-] oras not found; skipping push"; return 1; }
    [ -n "${GHCR_OWNER}" ] || { echo "[-] GHCR_OWNER unset; skipping push"; return 1; }
    return 0
}
export -f ghcr_available

ghcr_login() {
    ghcr_available || return 1
    if [ -z "${GITHUB_TOKEN:-}" ]; then
        echo "[-] GITHUB_TOKEN unset; cannot log in to GHCR"
        return 1
    fi
    echo "${GITHUB_TOKEN}" \
      | oras login ghcr.io --username "${GHCR_OWNER}" --password-stdin 2>/dev/null \
      && echo "[+] logged in to ghcr.io as ${GHCR_OWNER}"
}
export -f ghcr_login

#-------------------------------------------------------#
# ghcr_push_recipe <family> <file> [file...]
#   Files are names relative to $BINDIR (that is what the diff produces).
#   ALL of a package's files go in ONE push: the manifest is written last,
#   so a partial manifest can never exist.
ghcr_push_recipe() {
    local family="$1"; shift
    local files=("$@")
    [ "${#files[@]}" -gt 0 ] || { echo "[i] ${family}: nothing produced, not pushing"; return 0; }
    ghcr_available || return 0

    local pkg="ghcr.io/${GHCR_OWNER}/${GHCR_NAMESPACE}/${family}"
    local created; created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    local args=()
    args+=(--annotation "org.opencontainers.image.created=${created}")
    args+=(--annotation "org.opencontainers.image.source=https://github.com/${GITHUB_REPOSITORY:-unknown}")
    args+=(--annotation "dev.toolpacks.pkg_family=${family}")
    args+=(--annotation "dev.toolpacks.build_run=${GITHUB_RUN_ID:-local}")

    local f b3 ftype refs=()
    for f in "${files[@]}"; do
        [ -f "${BINDIR}/${f}" ] || continue
        b3="$(cd "$BINDIR" && b3sum "$f" 2>/dev/null | awk '{print $1}')"
        ftype="$(cd "$BINDIR" && file -b "$f" 2>/dev/null | tr -d '\n' | sed 's/"/'"'"'/g')"
        # A missing b3sum annotation reproduces the original metadata
        # corruption exactly: gen_meta.sh's `// ""` turns it into an empty
        # string and the build still goes green. Refuse to push instead.
        if [ -z "$b3" ]; then
            echo "[-] ${family}: could not compute b3sum for ${f}; refusing to push"
            return 1
        fi
        args+=(--annotation "${f}:dev.toolpacks.b3sum=${b3}")
        args+=(--annotation "${f}:dev.toolpacks.file=${ftype}")
        refs+=("${f}:application/octet-stream")
    done

    [ "${#refs[@]}" -gt 0 ] || { echo "[i] ${family}: no files on disk, not pushing"; return 0; }

    echo "[+] pushing ${pkg}:latest,${GHCR_DATE_TAG} (${#refs[@]} file(s))"
    ( cd "$BINDIR" && oras push "${pkg}:latest,${GHCR_DATE_TAG}" "${args[@]}" "${refs[@]}" ) \
      || { echo "[-] ${family}: oras push FAILED"; return 1; }

    # A workflow-token push creates the package PRIVATE, regardless of repo
    # visibility. That yields a green build and a cache anonymous users 404
    # on -- the same silent class as empty checksums, one layer down.
    # The package name contains "/", so it MUST be URL-encoded or the PATCH
    # 404s and the package quietly stays private.
    ghcr_make_public "${family}"
}
export -f ghcr_push_recipe

#-------------------------------------------------------#
ghcr_make_public() {
    local family="$1"
    [ -n "${GITHUB_TOKEN:-}" ] || return 0
    local encoded="${GHCR_NAMESPACE}%2F${family}"
    local scope="orgs/${GHCR_OWNER}"
    [ "${GHCR_OWNER_TYPE:-org}" = "user" ] && scope="users/${GHCR_OWNER}"

    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' -X PATCH \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/${scope}/packages/container/${encoded}" \
      -d '{"visibility":"public"}' 2>/dev/null)"

    case "$code" in
        200|204) echo "    [+] ${family}: visibility public" ;;
        404)     echo "    [!] ${family}: visibility PATCH 404 (wrong owner type or not yet indexed)" ;;
        *)       echo "    [!] ${family}: visibility PATCH returned ${code}" ;;
    esac
}
export -f ghcr_make_public
