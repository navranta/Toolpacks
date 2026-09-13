#!/usr/bin/env bash
set -x
#-------------------------------------------------------#
#Sanity Checks
if [ "${BUILD}" != "YES" ] || \
   [ -z "${BINDIR}" ] || \
   [ -z "${EGET_EXCLUDE}" ] || \
   [ -z "${EGET_TIMEOUT}" ] || \
   [ -z "${GIT_TERMINAL_PROMPT}" ] || \
   [ -z "${GIT_ASKPASS}" ] || \
   [ -z "${GITHUB_TOKEN}" ] || \
   [ -z "${SYSTMP}" ] || \
   [ -z "${TMPDIRS}" ]; then
 #exit
  echo -e "\n[+]Skipping Builds...\n"
  exit 1
fi
#-------------------------------------------------------#

#-------------------------------------------------------#
##Main
export SKIP_BUILD="NO" #YES, in case of deleted repos, broken builds etc
if [ "${SKIP_BUILD}" == "NO" ]; then
     #7z : Unarchiver
     export BIN="7z" #Name of final binary/pkg/cli, sometimes differs from $REPO
     export SOURCE_URL="https://www.7-zip.org" #github/gitlab/homepage/etc for $BIN
     echo -e "\n\n [+] (Building | Fetching) ${BIN} :: ${SOURCE_URL} [$(TZ='UTC' date +'%A, %Y-%m-%d (%I:%M:%S %p)') UTC]\n"
      #Build
      # download.html now links current releases off-site (absolute
      # https://github.com/ip7z/7zip/... hrefs) next to stale relative
      # ones, so only prefix $SOURCE_URL for relative hrefs.
       REL_URL="$(curl -qfsSL "$SOURCE_URL/download.html" | grep -o 'href="[^"]*"' | sed 's/^href="//;s/"$//' | grep 'linux-x64.tar.xz' | sort | tail -n 1)"
       case "$REL_URL" in http*) DL_URL="$REL_URL" ;; *) DL_URL="$SOURCE_URL/$REL_URL" ;; esac
       pushd "$($TMPDIRS)" >/dev/null 2>&1 && curl -qfsSLJO "$DL_URL"
       find . -type f -name '*.xz' -exec tar -xf {} \;
       find . -type f -name '7zzs' ! -name '*.xz' -exec cp {} "$BINDIR/7z" \;
       popd >/dev/null 2>&1
fi
#-------------------------------------------------------#

#-------------------------------------------------------#
##Cleanup
unset SKIP_BUILD ; export BUILT="YES"
#In case of zig polluted env
unset AR CC CFLAGS CXX CPPFLAGS CXXFLAGS DLLTOOL HOST_CC HOST_CXX LDFLAGS LIBS OBJCOPY RANLIB
#In case of go polluted env
unset GOARCH GOOS CGO_ENABLED CGO_CFLAGS
#PKG Config
unset PKG_CONFIG_PATH PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR PKG_CONFIG_SYSTEM_INCLUDE_PATH PKG_CONFIG_SYSTEM_LIBRARY_PATH
set +x
#-------------------------------------------------------#