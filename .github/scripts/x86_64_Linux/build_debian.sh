#!/usr/bin/env bash

#-------------------------------------------------------#
# This should be run on Debian (Debian Based) Distros with apt, coreutils, curl, dos2unix & passwordless sudo
# sudo apt-get update -y && sudo apt-get install coreutils curl dos2unix moreutils -y
# OR (without sudo): apt-get update -y && apt-get install coreutils curl dos2unix moreutils sudo -y
#
# Hardware : At least 2vCPU + 8GB RAM + 50GB SSD
# Once requirement is satisfied, simply:
# export GITHUB_TOKEN="NON_PRIVS_READ_ONLY_TOKEN"
# git clone --depth 1 <repo> && bash .github/scripts/x86_64_Linux/build_debian.sh
#-------------------------------------------------------#

##Repo root (from this script's own location, NOT $GITHUB_WORKSPACE,
## so the script stays usable outside CI)
 TOOLPACKS_REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
 export TOOLPACKS_REPO="$TOOLPACKS_REPO"
#-------------------------------------------------------#
#-------------------------------------------------------#
##ENV:$PATH
 export PATH="$HOME/bin:$HOME/.cargo/bin:$HOME/.cargo/env:$HOME/.go/bin:$HOME/go/bin:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$HOME/.local/bin:$HOME/miniconda3/bin:$HOME/miniconda3/condabin:/usr/local/zig:/usr/local/zig/lib:/usr/local/zig/lib/include:/usr/local/musl/bin:/usr/local/musl/lib:/usr/local/musl/include:$PATH"
#TMPDIRS
 # Honor a pre-set SYSTMP (CI exports RUNNER_TEMP so RESULT.jsonl lands
 # where the artifact upload reads it from); default keeps local behavior.
 SYSTMP="${SYSTMP:-$(dirname $(mktemp -u))}" && export SYSTMP="$SYSTMP"
 #For build-cache
 TMPDIRS="mktemp -d --tmpdir=$SYSTMP/toolpacks XXXXXXX_linux_x86_64" && export TMPDIRS="$TMPDIRS"
 rm -rf "$SYSTMP/toolpacks" 2>/dev/null ; mkdir -p "$SYSTMP/toolpacks"
 #For Bins
 BINDIR="$SYSTMP/toolpack_x86_64" && export BINDIR="$BINDIR"
 rm -rf "$BINDIR" 2>/dev/null ; rm -rf "$BINDIR.7z" 2>/dev/null ; mkdir -p "$BINDIR"
 #For Baseutils
 BASEUTILSDIR="$SYSTMP/baseutils_x86_64" && export BASEUTILSDIR="$BASEUTILSDIR"
 rm -rf "$BASEUTILSDIR" 2>/dev/null ; rm -rf "$BASEUTILSDIR.7z" 2>/dev/null ; mkdir -p "$BASEUTILSDIR"
##Sane Configs
#In case of removed/privated GH repos
 # https://git-scm.com/docs/git#Documentation/git.txt-codeGITTERMINALPROMPTcode
 export GIT_TERMINAL_PROMPT="0"
 #https://git-scm.com/docs/git#Documentation/git.txt-codeGITASKPASScode
 export GIT_ASKPASS="/bin/echo"
 #in case of eget prompts
 EGET_TIMEOUT="timeout -k 1m 2m" && export EGET_TIMEOUT="$EGET_TIMEOUT"
 EGET_EXCLUDE="--asset \"^386\" --asset \"^aarch64\" --asset \"^apple\" --asset \"^arm\" --asset \"^AppImage\" --asset \"^asc\" --asset \"^crt\" --asset \"^darwin\" --asset \"^deb\" --asset \"^exe\" --asset \"^freebsd\" --asset \"^i686\" --asset \"^mac\" --asset \"^mips\" --asset \"^rpm\" --asset \"^pem\" --asset \"^sbom\" --asset \"^sha\" --asset \"^solaris\" --asset \"^sig\" --asset \"^symbol\" --asset \"^windows\"" && export EGET_EXCLUDE="$EGET_EXCLUDE"
#User-Agent
 USER_AGENT="Toolpacks-Builder" && export USER_AGENT="$USER_AGENT"
#Go GC pressure (many recipes build Go binaries)
 export GOGC="20"
#-------------------------------------------------------#

#-------------------------------------------------------#
##Init
 #Get
 INITSCRIPT="${TOOLPACKS_REPO}/.github/scripts/x86_64_Linux/init_debian.sh"
 if [ ! -f "$INITSCRIPT" ]; then
    echo -e "\n[-] FATAL: init script not found: ${INITSCRIPT}\n" ; exit 1
 fi
 export INITSCRIPT ; source "$INITSCRIPT"
 #Check
 if [ "$CONTINUE" != "YES" ]; then
      echo -e "\n[+] Failed To Initialize\n"
      exit 1
 fi
##Ulimits
#(-n) Open File Descriptors
 echo -e "[+] ulimit -n (open file descriptors) :: [Soft --> $(ulimit -n -S)] [Hard --> $(ulimit -n -H)] [Total --> $(cat '/proc/sys/fs/file-max')]"
 ulimit -n "$(ulimit -n -H)"
#Stack Size
 ulimit -s unlimited
#-------------------------------------------------------#

#-------------------------------------------------------#
##Sanity Checks
if [[ -n "$GITHUB_TOKEN" ]]; then
   echo -e "\n[+] GITHUB_TOKEN is Exported"
  ##gh-cli (uses $GITHUB_TOKEN env var)
   #echo "$GITHUB_TOKEN" | gh auth login --with-token
   gh auth status
  ##eget
   # 5000 req/minute (80 req/minute)
   eget --rate
else
   # 60 req/hr
   echo -e "\n[-] GITHUB_TOKEN is NOT Exported"
   echo -e "Export it to avoid ratelimits\n"
   eget --rate
   exit 1
fi
#-------------------------------------------------------#


#-------------------------------------------------------#
##ENV (In Case of ENV Resets)
#TMPDIRS
 #For build-cache
 TMPDIRS="mktemp -d --tmpdir=$SYSTMP/toolpacks XXXXXXX_linux_x86_64" && export TMPDIRS="$TMPDIRS"
 rm -rf "$SYSTMP/toolpacks" 2>/dev/null ; mkdir -p "$SYSTMP/toolpacks"
 #For Bins
 BINDIR="$SYSTMP/toolpack_x86_64" && export BINDIR="$BINDIR"
 rm -rf "$BINDIR" 2>/dev/null ; rm -rf "$BINDIR.7z" 2>/dev/null ; mkdir -p "$BINDIR"
#-------------------------------------------------------#
#Publish backend (GHCR via ORAS)
 source "${TOOLPACKS_REPO}/.github/scripts/x86_64_Linux/ghcr_push.sh"
 ghcr_login || echo -e "\n[!] GHCR login failed; builds will run but not publish\n"
#-------------------------------------------------------#
##Build
set +x
 BUILD="YES" && export BUILD="$BUILD"
 #Recipes and their scripts come from the checkout. Nothing is fetched.
 RECIPES_FILE="${TOOLPACKS_REPO}/.github/scripts/x86_64_Linux/RECIPES.txt"
 BINS_DIR="${TOOLPACKS_REPO}/.github/scripts/x86_64_Linux/bins"
 LOGDIR="${TOOLPACKS_REPO}/x86_64-Linux/logs" && export LOGDIR="$LOGDIR"
 RESULT_FILE="${SYSTMP}/RESULT.jsonl" && export RESULT_FILE="$RESULT_FILE"
 export RECIPES_FILE BINS_DIR
 mkdir -p "$LOGDIR" ; : > "$RESULT_FILE"
 if [ ! -s "$RECIPES_FILE" ]; then
    echo -e "\n[-] FATAL: allowlist not found: ${RECIPES_FILE}\n"
    exit 1
 fi
 #Run
  echo -e "\n\n [+] Started Building at :: $(TZ='UTC' date +'%A, %Y-%m-%d (%I:%M:%S %p)') UTC\n\n"
  readarray -t RECIPES < "$RECIPES_FILE"
  # Fast loop: ONLY_RECIPES="foo bar" restricts the run to a subset
  # (used by the test-recipes workflow). Unknown names fail fast.
  if [ -n "${ONLY_RECIPES:-}" ]; then
     readarray -t _WANT <<< "$(printf '%s\n' ${ONLY_RECIPES})"
     for _w in "${_WANT[@]}"; do
        [ -n "$_w" ] || continue
        printf '%s\n' "${RECIPES[@]}" | grep -qxF "$_w" || \
          { echo -e "\n[-] FATAL: unknown recipe in ONLY_RECIPES: ${_w}\n"; exit 1; }
     done
     readarray -t RECIPES <<< "$(printf '%s\n' "${_WANT[@]}")"
     unset _WANT _w
  fi
  unset TOTAL_RECIPES
  TOTAL_RECIPES="${#RECIPES[@]}" && export TOTAL_RECIPES="${TOTAL_RECIPES}"
  echo -e "\n[+] Total RECIPES :: ${TOTAL_RECIPES}\n"
    for ((i=0; i<${#RECIPES[@]}; i++)); do
      #Init
        START_TIME="$(date +%s)" && export START_TIME="$START_TIME"
        RECIPE="${RECIPES[i]}"
        CURRENT_RECIPE=$((i+1))
        BUILDSCRIPT="${BINS_DIR}/${RECIPE}.sh" && export BUILDSCRIPT="$BUILDSCRIPT"
        LOG="${LOGDIR}/${RECIPE}.log.txt"
        echo -e "\n[+] Building : ${RECIPE} (${CURRENT_RECIPE}/${TOTAL_RECIPES})\n"
        if [ ! -f "$BUILDSCRIPT" ]; then
           echo -e "\n[-] MISSING RECIPE :: ${BUILDSCRIPT}\n"
           printf '{"recipe":"%s","status":"missing","rc":127,"seconds":0,"produced":[]}\n' \
             "$RECIPE" >> "$RESULT_FILE"
           continue
        fi
      #Snapshot $BINDIR so we can tell what this recipe actually produced
        BEFORE="$(find "$BINDIR" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort)"
      #Run in a SUBSHELL.
      # A recipe's sanity block ends in `exit 1`, and `exit` inside a sourced
      # script exits the CALLING shell -- `|| true` cannot catch it, because
      # `||` tests a return value and `exit` never returns. Sourced directly,
      # one bad recipe would end the whole run while the job still exited 0.
      # The subshell also stops env leaking between recipes.
        ( timeout -k 60 20m bash -c 'source "$BUILDSCRIPT"' ) 2>&1 | tee "$LOG"
        RC="${PIPESTATUS[0]}"
      #Diff to get produced binaries
        AFTER="$(find "$BINDIR" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort)"
        PRODUCED="$(comm -13 <(echo "$BEFORE") <(echo "$AFTER") | grep -v '^$' || true)"
      #Declared bins from the recipe's yaml
        DECLARED="$(yq -r '.bins[]?' "${BINS_DIR}/${RECIPE}.yaml" 2>/dev/null | sort -u | grep -v '^$' || true)"
      #Classify. "partial" (rc=0 but declared bins missing) is invisible to a
      #plain exit-code check, and is the common real-world failure here.
        if [ "$RC" -eq 124 ] || [ "$RC" -eq 137 ]; then
           STATUS="timeout"
        elif [ "$RC" -ne 0 ]; then
           STATUS="fail"
        elif [ -n "$DECLARED" ] && [ -n "$(comm -23 <(echo "$DECLARED") <(echo "$PRODUCED" | sort -u))" ]; then
           STATUS="partial"
        else
           STATUS="ok"
        fi
      #Clean & Purge
        sudo rm -rf "$SYSTMP/toolpacks" 2>/dev/null
        mkdir -p "$SYSTMP/toolpacks"
      #Finish
        END_TIME="$(date +%s)" && export END_TIME="$END_TIME"
        SECONDS_TAKEN="$((END_TIME - START_TIME))"
        ELAPSED_TIME="$(date -u -d@"${SECONDS_TAKEN}" "+%H(Hr):%M(Min):%S(Sec)")"
        printf '{"recipe":"%s","status":"%s","rc":%s,"seconds":%s,"produced":[%s]}\n' \
          "$RECIPE" "$STATUS" "$RC" "$SECONDS_TAKEN" \
          "$(echo "$PRODUCED" | sed 's/.*/"&"/' | paste -sd, -)" >> "$RESULT_FILE"
      #Strip + publish THIS recipe's output now, not at the end
        if [ "$STATUS" = "ok" ] || [ "$STATUS" = "partial" ]; then
           if [ -n "$PRODUCED" ]; then
              while IFS= read -r _pf; do
                  [ -n "$_pf" ] || continue
                  chmod +xwr "${BINDIR}/${_pf}" 2>/dev/null
                  case "$_pf" in
                      *.no_strip) ;;
                      *) strip --strip-debug --strip-dwo --strip-unneeded \
                           --preserve-dates "${BINDIR}/${_pf}" 2>/dev/null ;;
                  esac
              done <<< "$PRODUCED"
              unset _pf
              mapfile -t _PFILES <<< "$PRODUCED"
              ghcr_push_recipe "$RECIPE" "${_PFILES[@]}" || \
                echo -e "\n[-] ${RECIPE}: publish failed\n"
              unset _PFILES
           fi
        fi
        echo -e "\n[+] Completed ${RECIPE} :: ${STATUS} (rc=${RC}) :: ${ELAPSED_TIME}\n"
      #Reset per-recipe env so the next recipe cannot inherit it
        unset BIN SOURCE_URL SKIP_BUILD DESCRIPTION BUILD_URL
    done
  echo -e "\n\n [+] Finished Building at :: $(TZ='UTC' date +'%A, %Y-%m-%d (%I:%M:%S %p)') UTC\n\n"
  echo -e "\n[+] Status Summary\n"
  awk -F'"status":"' '{split($2,a,"\""); print a[1]}' "$RESULT_FILE" | sort | uniq -c | sort -rn
 #Check
 BINDIR_SIZE="$(du -sh "$BINDIR" 2>/dev/null | awk '{print $1}' 2>/dev/null)" && export "BINDIR_SIZE=$BINDIR_SIZE"
 if [ ! -d "$BINDIR" ] || [ -z "$(ls -A "$BINDIR")" ] || [ -z "$BINDIR_SIZE" ] || [[ "${BINDIR_SIZE}" == *K* ]]; then
      echo -e "\n[+] Broken/Empty Built "$BINDIR" Found\n"
      exit 1
 else
      echo -e "\n[+] Built "$BINDIR" :: $BINDIR_SIZE\n"
 fi
#-------------------------------------------------------#


#-------------------------------------------------------#
#Strip || Cleanup [$BINDIR]
 #Chmod +xwr
 find "$BINDIR" -maxdepth 1 -type f -exec chmod +xwr {} \; 2>/dev/null
 #Strip
 find "$BINDIR" -maxdepth 1 -type f ! -name "*.no_strip" -exec strip --strip-debug --strip-dwo --strip-unneeded --preserve-dates "{}" \; 2>/dev/null
 #Rename anything with *_amd*
 find "$BINDIR" -type f -name '*_Linux' -exec sh -c 'newname=$(echo "$1" | sed "s/_amd_x86_64_Linux//"); mv "$1" "$newname"' sh {} \;
#Strip || Cleanup [$BASEUTILSDIR]
 #Chmod +xwr
 find "$BASEUTILSDIR" -maxdepth 1 -type f -exec chmod +xwr {} \; 2>/dev/null
 #Strip
 find "$BASEUTILSDIR" -maxdepth 1 -type f ! -name "*.no_strip" -exec strip --strip-debug --strip-dwo --strip-unneeded --preserve-dates "{}" \; 2>/dev/null
 #Rename anything with *_amd*
 find "$BASEUTILSDIR" -type f -name '*_Linux' -exec sh -c 'newname=$(echo "$1" | sed "s/_amd_x86_64_Linux//"); mv "$1" "$newname"' sh {} \;
#-------------------------------------------------------#
#Publish
# Binaries are pushed to GHCR per-recipe, inside the build loop above, so a
# run that dies part-way has already published everything built before it.
# There is deliberately no upload step here: rebuilding the published set
# from $BINDIR at the end is exactly the union bug that R2 required and GHCR
# makes unnecessary.
#-------------------------------------------------------#
#META
 echo -e "\n\n[+] Size $BINDIR --> $(du -sh "$BINDIR" 2>/dev/null | awk '{print $1}')"
 echo -e "[+] Binaries --> $(find "$BINDIR" -maxdepth 1 -type f 2>/dev/null | wc -l)\n\n"
 if [ -s "$RESULT_FILE" ]; then
    echo -e "[+] Per-recipe results --> ${RESULT_FILE}\n"
 fi
#-------------------------------------------------------#
#-------------------------------------------------------# 
#GH Runner
 if [ "$USER" = "runner" ] || [ "$(whoami)" = "runner" ]; then
   #Preserve Files for Artifacts
     echo -e "\n[+] Detected GH Actions... Preserving Logs & Output\n"
 else
   #Purge Files
     echo -e "\n[+] PURGING Logs & Output in 180 Seconds... (Hit Ctrl + C)\n" ; sleep 180
   #Cleanup (x86_64_Linux) Bins
     rm -rf "$BINDIR" 2>/dev/null
     rm -rf "$BINDIR.7z" 2>/dev/null
     rm -rf "$BASEUTILSDIR" 2>/dev/null
     rm -rf "$BASEUTILSDIR.7z" 2>/dev/null     
 fi
#-------------------------------------------------------# 
#-------------------------------------------------------#
##END
unset GIT_ASKPASS GIT_TERMINAL_PROMPT
#In case of zig polluted env 
unset AR CC CXX DLLTOOL HOST_CC HOST_CXX OBJCOPY RANLIB
#EOF
#-------------------------------------------------------#