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
 export GHCR_OWNER="${GHCR_OWNER:-navranta}"
 export GHCR_NAMESPACE="${GHCR_NAMESPACE:-toolpacks}"
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
 fetch_tool "7z" "7z" "7z"
 fetch_tool "actionlint" "actionlint" "actionlint"
 fetch_tool "anew" "anew" "anew"
 fetch_tool "anew-rs" "anew-rs" "anew-rs"
 fetch_tool "ansi2html" "colorized-logs" "ansi2html"
 fetch_tool "ansi2txt" "colorized-logs" "ansi2txt"
 fetch_tool "aria2c" "aria2" "aria2c"
 fetch_tool "b3sum" "b3sum" "b3sum"
 fetch_tool "bsdtar" "libarchive" "bsdtar"
 fetch_tool "btop" "btop" "btop"
 fetch_tool "chafa" "chafa" "chafa"
 fetch_tool "cloudflared" "cloudflared" "cloudflared"
 fetch_tool "croc" "croc" "croc"
 fetch_tool "csvtk" "csvtk" "csvtk"
 fetch_tool "cutlines" "cutlines" "cutlines"
 fetch_tool "dasel" "dasel" "dasel"
 fetch_tool "dbin" "dbin" "dbin"
 fetch_tool "delta" "delta" "delta"
 fetch_tool "dos2unix" "dos2unix" "dos2unix"
 fetch_tool "ds" "dirstat-rs" "ds"
 fetch_tool "duf" "duf" "duf"
 fetch_tool "dust" "dust" "dust"
 fetch_tool "dwarfs-tools" "dwarfs" "dwarfs-tools"
 fetch_tool "dysk" "dysk" "dysk"
 fetch_tool "eget" "eget" "eget"
 fetch_tool "epoch" "epoch" "epoch"
 fetch_tool "fastfetch" "fastfetch" "fastfetch"
 fetch_tool "freeze" "freeze" "freeze"
 fetch_tool "fusermount3" "fuse3" "fusermount3"
 fetch_tool "gdu" "gdu" "gdu"
 fetch_tool "gh" "gh" "gh"
 fetch_tool "git-sizer" "git-sizer" "git-sizer"
 fetch_tool "gitleaks" "gitleaks" "gitleaks"
 fetch_tool "glab" "gitlab-cli" "glab"
 fetch_tool "glow" "glow" "glow"
 fetch_tool "httpx" "httpx" "httpx"
 fetch_tool "husarnet" "husarnet" "husarnet"
 fetch_tool "husarnet-daemon" "husarnet" "husarnet-daemon"
 fetch_tool "imgcat" "imgcat" "imgcat"
 fetch_tool "jc" "jc" "jc"
 fetch_tool "jq" "jq" "jq"
 fetch_tool "logdy" "logdy" "logdy"
 fetch_tool "mdcat" "mdcat" "mdcat"
 fetch_tool "micro" "micro" "micro"
 fetch_tool "miniserve" "miniserve" "miniserve"
 fetch_tool "ncdu" "ncdu" "ncdu"
 fetch_tool "notify" "notify" "notify"
 fetch_tool "oras" "oras" "oras"
 fetch_tool "ouch" "ouch" "ouch"
 fetch_tool "pipetty" "colorized-logs" "pipetty"
 fetch_tool "pixterm" "pixterm" "pixterm"
 fetch_tool "qsv" "qsv" "qsv"
 fetch_tool "rclone" "rclone" "rclone"
 fetch_tool "rga" "rga" "rga"
 fetch_tool "ripgrep" "ripgrep" "ripgrep"
 fetch_tool "rsync" "rsync" "rsync"
 fetch_tool "speedtest-go" "speedtest-go" "speedtest-go"
 fetch_tool "sttr" "sttr" "sttr"
 fetch_tool "tailscale" "tailscale" "tailscale"
 fetch_tool "tailscaled" "tailscale" "tailscaled"
 fetch_tool "taplo" "taplo" "taplo"
 fetch_tool "tealdeer" "tealdeer" "tealdeer"
 fetch_tool "tmux" "tmux" "tmux"
 fetch_tool "tok" "tok" "tok"
 fetch_tool "trufflehog" "trufflehog" "trufflehog"
 fetch_tool "trurl" "curl" "trurl"
 fetch_tool "unfurl" "unfurl" "unfurl"
 fetch_tool "upx" "upx" "upx"
 fetch_tool "validtoml" "validtoml" "validtoml"
 fetch_tool "wget" "wget" "wget"
 fetch_tool "wormhole-rs" "wormhole-rs" "wormhole-rs"
 fetch_tool "xq" "xq" "xq"
 fetch_tool "yj" "yj" "yj"
 fetch_tool "yq" "yq" "yq"
 fetch_tool "zapper" "zapper" "zapper"
 fetch_tool "zapper-stealth" "zapper" "zapper-stealth"
 fetch_tool "zstd" "zstd" "zstd"
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
