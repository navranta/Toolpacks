<div align="center">

# Toolpacks

**Statically linked x86_64 Linux binaries, built monthly and published to GHCR.**

</div>

---

## What this is

A build pipeline that fetches or compiles **132 tools** as static x86_64 Linux
binaries and publishes each one to the GitHub Container Registry, one package
per tool family.

Static means they run on any x86_64 Linux box — no glibc version to match, no
package manager, no dependencies. Drop the binary somewhere on `$PATH` and run it.

Scope is defined by the two installers under
[`.github/scripts/x86_64_Linux/installers/`](.github/scripts/x86_64_Linux/installers/):
a general development set and a security/recon set.

## Install

Set `GHCR_OWNER` to the account hosting the packages, then run either installer:

```bash
GHCR_OWNER=<owner> bash <(curl -qfsSL "https://raw.githubusercontent.com/<owner>/Toolpacks/main/.github/scripts/x86_64_Linux/installers/install_dev_tools.sh")
```

```bash
GHCR_OWNER=<owner> bash <(curl -qfsSL "https://raw.githubusercontent.com/<owner>/Toolpacks/main/.github/scripts/x86_64_Linux/installers/install_bb_tools.sh")
```

`curl` is the only requirement. The installers parse JSON with `sed`, never
`jq` — `jq` is one of the tools they install, so it cannot also be a
prerequisite.

Override the destination with `INSTALL_DIR` (defaults to `/usr/local/bin` when
passwordless sudo is available, otherwise `~/bin`).

### Fetching a single tool

Packages are OCI artifacts, so `oras` works directly:

```bash
oras pull ghcr.io/<owner>/toolpacks/ripgrep:latest
```

Or by hand, which is what the installers do. A registry blob needs an anonymous
bearer token and a manifest lookup, so it is three requests rather than one:

```bash
OWNER=<owner>; TOOL=rg; FAMILY=ripgrep

TOKEN=$(curl -qfsSL "https://ghcr.io/token?scope=repository:${OWNER}/toolpacks/${FAMILY}:pull&service=ghcr.io" \
        | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')

DIGEST=$(curl -qfsSL -H "Authorization: Bearer ${TOKEN}" \
              -H "Accept: application/vnd.oci.image.manifest.v1+json" \
              "https://ghcr.io/v2/${OWNER}/toolpacks/${FAMILY}/manifests/latest" \
         | sed 's/},{/}\n{/g' | grep "\"image.title\":\"${TOOL}\"" \
         | sed -n 's/.*"digest":"\(sha256:[a-f0-9]*\)".*/\1/p' | head -1)

curl -qfsSL -H "Authorization: Bearer ${TOKEN}" \
     "https://ghcr.io/v2/${OWNER}/toolpacks/${FAMILY}/blobs/${DIGEST}" -o "${TOOL}"
chmod +x "${TOOL}"
```

A tool's **family** is the recipe that produces it, which is often a different
name — `rg` comes from `ripgrep`, `glab` from `gitlab-cli`, `ansi2txt` from
`colorized-logs`. [`METADATA.json`](x86_64-Linux/METADATA.json) maps every
binary to its family, digest and checksums.

## Tags and pinning

Each package carries `:latest` and a `:YYYY.MM.DD` build tag. **Neither is a
version number.** Only two recipes record what upstream version they built, so
a version tag would be a guess.

**The digest is the pin.** `ghcr_digest` in `METADATA.json` is the file's real
sha256 — ORAS pushes raw blobs, so the layer digest *is* the content hash,
bound by the registry rather than by a checksum file anyone could get wrong.

```bash
oras pull ghcr.io/<owner>/toolpacks/ripgrep@sha256:<digest>
```

## Building

```bash
git clone --depth 1 https://github.com/<owner>/Toolpacks
bash Toolpacks/.github/scripts/x86_64_Linux/build_debian.sh
```

Debian/Ubuntu with `apt`, `curl`, `coreutils` and passwordless sudo. At least
2 vCPU, 8 GB RAM, 50 GB disk. A full run is roughly 1.2 hours plus setup.

The build is self-contained: recipes, the init script and the bootstrap
binaries all come from the checkout. Nothing is fetched from a binary cache,
which is enforced by a CI job that blackholes every such host and runs the
build anyway.

Set `GHCR_PUSH=NO` to build without publishing.

## Layout

```
.github/scripts/x86_64_Linux/
├── bins/                    recipes: <tool>.sh builds it, <tool>.yaml declares
│                            which binaries it produces
├── installers/
│   ├── upstream/            verbatim upstream installers -- the authoritative
│   │                        list of which tools are offered
│   └── install_*.sh         GENERATED; fetch those tools from GHCR
├── prebuilts/               vendored bootstrap binaries + provenance manifest
├── RECIPES.txt              GENERATED allowlist of what gets built
├── DROPPED.txt              deliberate exclusions, with reasons
├── build_debian.sh          the build
├── ghcr_push.sh             publish
├── gen_recipes.sh           upstream installers -> RECIPES.txt
├── gen_installers.sh        RECIPES.txt -> installers
└── gen_meta.sh              GHCR -> METADATA.json
```

Data flows one way:

```
installers/upstream/  ->  RECIPES.txt  ->  installers/install_*.sh
                               |
                               v
                        build -> GHCR -> METADATA.json
```

Everything marked GENERATED is checked in CI, so it cannot drift from its source.

### Changing what gets built

Add or remove a tool in `installers/upstream/`, or add a reason to
`DROPPED.txt`, then regenerate:

```bash
cd .github/scripts/x86_64_Linux
./gen_recipes.sh && GHCR_OWNER=<github-user-or-org> ./gen_installers.sh
```

Never edit `RECIPES.txt` or `installers/install_*.sh` by hand.

## Notes

- **x86_64 Linux only.** aarch64, Android and Windows support was removed.
- **No UPX.** Packed binaries are unnecessary at these sizes and break some tools.
- **Bootstrap binaries are committed** under `prebuilts/` (~35 MB): `eget`,
  `jq`, `b3sum`, `yq`, `oras`. Each comes from its own upstream release, with
  source URL and sha256 recorded in `prebuilts/MANIFEST.txt` and verified in
  CI. They are never produced by this build — that circularity is what broke
  the previous pipeline.
- **`~1.7 GB/month`** of published artifacts, ~20 GB/year before retention.

## License

See [LICENSE](LICENSE). Each published binary remains under the license of its
own upstream project; this repository only builds and redistributes them.
