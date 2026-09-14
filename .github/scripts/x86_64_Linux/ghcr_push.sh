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

    # Per-file annotations (b3sum, file) MUST land on the layer, not the
    # manifest: gen_meta.sh reads them off layers[].annotations. oras'
    # --annotation flag only ever takes "key=value" for the MANIFEST --
    # "file:key=value" is not a recognized scoping form, it silently becomes
    # a literal manifest annotation key containing a colon (verified against
    # oras 1.3.4). That reproduced the exact original bug: every b3sum/file
    # annotation ends up empty from gen_meta.sh's point of view and the
    # "empty required field" gate fails for 100% of entries. The only way to
    # target a specific layer is --annotation-file with a JSON map keyed by
    # filename (and "$manifest" for the manifest-level keys).
    local annf; annf="$(mktemp)"
    jq -n \
      --arg created "$created" \
      --arg source "https://github.com/${GITHUB_REPOSITORY:-unknown}" \
      --arg family "$family" \
      --arg run "${GITHUB_RUN_ID:-local}" \
      '{"$manifest": {
          "org.opencontainers.image.created": $created,
          "org.opencontainers.image.source": $source,
          "dev.toolpacks.pkg_family": $family,
          "dev.toolpacks.build_run": $run
        }}' > "$annf"

    local f b3 ftype refs=()
    for f in "${files[@]}"; do
        [ -f "${BINDIR}/${f}" ] || continue
        b3="$(cd "$BINDIR" && b3sum "$f" 2>/dev/null | awk '{print $1}')"
        ftype="$(cd "$BINDIR" && file -b "$f" 2>/dev/null | tr -d '\n')"
        # A missing b3sum annotation reproduces the original metadata
        # corruption exactly: gen_meta.sh's `// ""` turns it into an empty
        # string and the build still goes green. Refuse to push instead.
        if [ -z "$b3" ]; then
            echo "[-] ${family}: could not compute b3sum for ${f}; refusing to push"
            rm -f "$annf"
            return 1
        fi
        jq --arg f "$f" --arg b3 "$b3" --arg ftype "$ftype" \
          '.[$f] = {"dev.toolpacks.b3sum": $b3, "dev.toolpacks.file": $ftype}' \
          "$annf" > "${annf}.tmp" && mv "${annf}.tmp" "$annf"
        refs+=("${f}:application/octet-stream")
    done

    [ "${#refs[@]}" -gt 0 ] || { rm -f "$annf"; echo "[i] ${family}: no files on disk, not pushing"; return 0; }

    echo "[+] pushing ${pkg}:latest,${GHCR_DATE_TAG} (${#refs[@]} file(s))"
    ( cd "$BINDIR" && oras push "${pkg}:latest,${GHCR_DATE_TAG}" --annotation-file "$annf" "${refs[@]}" ) \
      || { echo "[-] ${family}: oras push FAILED"; rm -f "$annf"; return 1; }
    rm -f "$annf"

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
    # Publicity normally comes from repo inheritance (public repo -> public
    # package), so check first via the read-only GET and only attempt a
    # PATCH when the package is actually private. Reasons: GitHub exposes
    # no PATCH for user-scoped container packages (PATCH on /users/<name>/
    # ... is GET-only and 404s; /user/... has no PATCH route either --
    # verified live, both 404), so an unconditional PATCH cries wolf on
    # every push while a real private package would slip by unnoticed.
    local vis=""
    if command -v jq >/dev/null 2>&1; then
        vis="$(curl -s -H "Authorization: Bearer ${GITHUB_TOKEN}" \
          -H "Accept: application/vnd.github+json" \
          "https://api.github.com/users/${GHCR_OWNER}/packages/container/${encoded}" \
          2>/dev/null | jq -r '.visibility // empty' 2>/dev/null)"
    fi

    case "$vis" in
        public) echo "    [+] ${family}: already public"; return 0 ;;
        private) ;;
        *) echo "    [i] ${family}: visibility unknown (not yet indexed?); attempting PATCH best-effort" ;;
    esac

    # Best-effort: orgs use their scoped route, user namespaces use the
    # authenticated-user route. Either may 404; that is reported below.
    local scope="orgs/${GHCR_OWNER}"
    [ "${GHCR_OWNER_TYPE:-org}" = "user" ] && scope="user"

    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' -X PATCH \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/${scope}/packages/container/${encoded}" \
      -d '{"visibility":"public"}' 2>/dev/null)"

    case "$code" in
        200|204) echo "    [+] ${family}: visibility public" ;;
        *)       echo "    [!] ${family}: STILL ${vis:-unknown} visibility (PATCH returned ${code}); make it public in the web UI or the anonymous-pull gate will fail" ;;
    esac
}
export -f ghcr_make_public
