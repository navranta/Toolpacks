# Revive Toolpacks: x86_64-only, GHCR/ORAS + `direct` branch

## Context

`Azathothas/Toolpacks` is an archived static-binary cache (`archived=true`, last push 2025-06-03). It built ~1,460 x86_64 binaries weekly and published them to Cloudflare R2 at `bin.ajam.dev`.

It previously committed binaries straight into git — that era was force-pushed away on 2024-07-11 in a commit named **"Purge (Re:Init)"**, because the payload is 14.85 GB and 16 files exceed git's 100 MiB blob limit.

**Goal:** revive it, x86_64 Linux only, binaries in **GHCR via ORAS** on `main`, plus a **`direct` branch** re-adopting the commit-to-repo method under a size cap. R2 leaves entirely. Monthly cadence, sharded GitHub-hosted runners.

### Decisions locked
| | |
|---|---|
| Target | x86_64 Linux only |
| Storage | GHCR, one package per tool |
| Cadence | monthly, `30 18 1 * *` |
| Runners | GitHub-hosted, sharded, hard 6h/job cap |
| UPX | **dropped**, README updated to match |
| Baseutils | recipes stay in repo, **excluded from this build** — deferred |
| `direct` branch | **deferred** — handled separately, later |
| Pruned | 13 distro/flatimage recipes, 2 C2 recipes |

### Scope
```
  start                              925 recipes
  - distro DockerC + flatimage        13   (26 binaries, 2.12 GB)
  - C2: sliver, redguard               2   (3 binaries, 216 MB)
  - Baseutils (excluded, not deleted) 83
  = phase-1 build list                827 recipes
```
`flatimage.sh` alone produces the 9 `*-flatimage.no_strip` binaries — including `cachyos-flatimage` and `artix-flatimage`, which have **no recipes of their own**. Deleting `flatimage.{sh,yaml}` covers them.

**Open call:** `aws-cli` (118 MB) is the same `Portable Ephemeral … Docker Image (DockerC)` family as the 13 distro images but is a tool, not a rootfs. Currently **kept**.

---

## Corrections to the original premises

Measured from the committed build logs — these change the design.

### Version tags are not derivable
Only `mitmproxy.sh` and `openssh.sh` capture a version at build time. The other 923 recipes scrape a URL and copy the artifact without recording what they got. `repo_version` in METADATA.json is computed *later* by `gen_meta.sh:109-113` from the GitHub API — it means "upstream's latest tag right now", not "what was built". Tagging GHCR with it is false whenever upstream releases between build and metadata.

**Therefore:** push `:latest` + `:YYYY.MM.DD` (both true statements). The **digest is the real pin**. Finalize may retroactively `oras tag` with the API version, annotated `dev.pkgforge.version.source=github-api-advisory`. Add `export PKG_VERSION=` to recipes incrementally in later phases; do not block on it.

### Shard count and setup overhead
From `x86_64-Linux/BUILD.BIN.log.txt` (2024-12-16 run):

| metric | value |
|---|---|
| serial wall time, 924 recipes | **14.8 h** |
| mean / median | 58 s / **11 s** |
| p90 / p99 / max | 160 s / 656 s / **3567 s** (`zcip`) |

`init_debian.sh` took **19 min** on the old self-hosted runner; budget **30–45 min** on a 2-vCPU hosted one (it installs Docker, Nix, Rust, Go, Zig, Crystal, Node, plus Nuitka/Pex/PyInstaller from git at `init_debian.sh:183-187`).

At 20 shards that's ~12 job-hours of setup for ~45 job-hours of work — **21% waste, every month**. And 20 is exactly the GitHub Free concurrency ceiling, so nothing else in the repo runs for 4 hours.

**Therefore:** build `ghcr.io/OWNER/toolpacks-builder:<date>` once and run shards with `container:`. Setup collapses to an image pull. Then **12–16 shards**. (This is a small, purpose-built image — not a revival of the deleted `build_gh_runner_images.yaml`.)

### `|| true` does not catch a sourced `exit`
`build_debian.sh:163` is `source "$BUILDSCRIPT" || true`. Every recipe's sanity block ends in `exit 1` (`bins/7z.sh:16`). **`exit` inside a sourced script exits the calling shell** — `||` tests a return value, and `exit` never returns.

Today this is masked because the env is always populated. Once sharding changes env plumbing, one recipe with a missing `$EGET_EXCLUDE` terminates the whole shard at recipe 3 of 46 — and the job still exits 0 because of `continue-on-error: true` at `build_x86_64_Linux.yaml:246`.

**Fix:** `( source "$BUILDSCRIPT" ) ; RC=$?`. The subshell also stops env leaking between recipes — `bins/7z.sh:38` unsets `SKIP_BUILD` but not `BIN` or `SOURCE_URL`.

---

## Phase 0 — Strip to x86_64 (~0.5 day)

### Delete
```
aarch64-Linux/                                   164 MB, 20 files
.github/scripts/aarch64_Linux/                   8.2 MB, 1831 files
.github/workflows/build_aarch64_Linux.yaml
.github/workflows/ubuntu_runner_android.yaml
.github/workflows/build_gh_runner_images.yaml
.github/workflows/archived/                      13 files
.github/scripts/archives/                        208 files
.github/runners/                                 entire dir
archived/                                        22 files
```

### Delete recipes (`.sh` + `.yaml`)
```
almalinux alpine amazonlinux archlinux clearlinux debian fedora
flatimage gentoo kalilinux rockylinux ubuntu void      (13, distro/flatimage)
sliver redguard                                        (2, C2)
```
`sliver` → `sliver-server` 169 MB + `sliver-client` 36.5 MB. `redguard` → 10.2 MB, upstream-described as evading "Blue Teams, AVs, EDRs".

### Edit — hard breaks
| File | Line | Fix |
|---|---|---|
| `healthchecks_housekeeping.yaml` | **711** | `needs: [enrich-arm64-Linux, …]` → **workflow won't parse** once that job goes |
| `healthchecks_housekeeping.yaml` | 502-606 | delete job `enrich-arm64-Linux` |
| `healthchecks_housekeeping.yaml` | **142** | `cd .github/scripts/aarch64_Linux/bins` — path gone |
| `healthchecks_housekeeping.yaml` | **220** | writes into the deleted aarch64 tree |
| `healthchecks_housekeeping.yaml` | 224-244, 278-321, 802-816, 832-850 | delete aarch64 steps |
| `healthchecks_housekeeping.yaml` | 373-376, 427-436, 451-475, 759-771 | strip `host == "aarch64-Linux"` from merge/count jq |
| `toolchain_fetcher_updater.yml` | 19-301 | delete `fetch-aarch64-toolchains` (nothing needs it) |
| `toolchain_fetcher_updater.yml` | 634-723, 786-812 | remove aarch64/windows zig sub-blocks (step also holds x86_64 blocks) |
| `build_x86_64_Linux.yaml` | 55-57, 149-151 | drop `mkdir` of aarch64/Android/Windows dirs |
| `build_x86_64_Linux.yaml` | 14 | remove `RCLONE_CF_R2_PUB`; delete the secret |
| `build_x86_64_Linux.yaml` | 23-24, 117-118 | add `packages: write` |
| `build_x86_64_Linux.yaml` | 16 | `UPX_PACK: "YES"` → delete |
| `build_debian.sh` | 352-390 | delete the UPX block (100% rclone, no I/O path after migration) |
| `README.md` | — | remove the UPX section and its `docs.pkgforge.dev/…/faq#upx` link |
| `init_debian.sh` | 146-148 | drop arm cross-toolchain install |

### Write `EXCLUDE.txt`
`.github/scripts/x86_64_Linux/EXCLUDE.txt` — an **explicit committed denylist** with a reason per block. Do not infer via `grep -l BASEUTILSDIR`: some of those 83 also write `$BINDIR`, and a future recipe touching `$BASEUTILSDIR` would be silently excluded without anyone deciding.

CI check: every name in EXCLUDE.txt must resolve to an existing `bins/<name>.sh`, or a typo silently excludes nothing.

**Keep:** `EGET_EXCLUDE` (`env.sh:21`, `build_debian.sh:36`) — those `--asset "^aarch64"` entries are exclusion filters that make the x86_64 build *correct*.

**Regenerate, don't hand-edit:** root `METADATA.{json,yaml}` are merged 2-element arrays keyed by `host` (`jq '[.[1]]'` splits them; properly fixed at `healthchecks_housekeeping.yaml:771`). `Docs/*_TARGETS.*`, `.github/SIZE.*`, README badge are all auto-regenerated.

*Verify:* `grep -rn 'rclone\|r2:\|RCLONE' .github/workflows .github/scripts/x86_64_Linux/*.sh` → empty. `actionlint` + `shellcheck` clean (already wired at `healthchecks_housekeeping.yaml:119,128`).

---

## Phase 1 — De-circularize the bootstrap (~1 day, BLOCKING)

The build downloads itself from R2. Nothing runs until this is cut.

```
workflow:100     rclone sync repo → r2:/pub/repos/...
workflow:184     curl r2 .../build_debian.sh
build_debian:52  curl r2 .../init_debian.sh → source
build_debian:128 curl r2 .../bins/metadata.json
build_debian:160 curl r2 .../bins/<pkg>.sh     (827 recipes, every run)
```

### Step 0 — repair already-dead dependencies

**Verified live status (checked during planning):**

| endpoint | status |
|---|---|
| `bin.ajam.dev/x86_64_Linux/*` binaries | **206 — still up** |
| `bin.pkgforge.dev/x86_64-Linux/*` binaries | **206 — still up** |
| `pub.ajam.dev/repos/Azathothas/Arsenal/…/install_dev_tools.sh` | **404 — ALREADY DEAD** |
| `pub.ajam.dev/utils/devscripts/jq/to_human_bytes.jq` | **404 — ALREADY DEAD** |
| `raw.githubusercontent.com/Azathothas/Arsenal/main/…` (all 4 scripts) | **200 — works** |

**The build is already broken today**, before any migration: `init_debian.sh:189` fetches `install_dev_tools.sh` from a 404. That's the script installing rclone, eget, b3sum, dust, yq, jq, trufflehog. Nothing runs until this is fixed.

- **Repoint the Arsenal deps** (`Azathothas/Arsenal` is archived but alive, default branch `main`; all four paths verified 200):
  `init_debian.sh:94,95,189,305` and `build_x86_64_Linux.yaml:38,132,195` → `raw.githubusercontent.com/Azathothas/Arsenal/main/...`
- **`to_human_bytes.jq` cannot be vendored — its source is 404.** Rewrite it; it's a small bytes→human-readable jq function. Used by `workflow:103`, `healthchecks:425,449`, and 73 recipes (the recipe copies sit inside excluded baseutils blocks, so only the two workflow sites are urgent).
- Delete `USER_AGENT` fetch (`build_debian.sh:38`, `env.sh:22`, `workflow:67,161`) — also a `pub.ajam.dev` path.

### Step 1 — break builder↔cache circularity ⏰ **TIME-CRITICAL**
These pull tools *from the cache this builder produces*:

| line | tool | replacement |
|---|---|---|
| `init_debian.sh:193` | `mkappimage` | `eget probonopd/go-appimage --asset mkappimage --asset x86_64` |
| `init_debian.sh:194-197` | `mksquashfs`, `sqfscat`, `sqfstar`, `unsquashfs` | **vendor prebuilt** |
| `init_debian.sh:252` | `dockerc` | `eget NilsIrl/dockerc --asset x86_64` |

For the squashfs four: `apt-get install squashfs-tools` looks easier but Ubuntu's version varies by runner image and `sqfstar`/`sqfscat` only exist in ≥4.5 — a runner image bump would silently remove two tools with no error at init time. **Vendor them:** pull once from `bin.ajam.dev` (**verified still serving, 206**), commit under `.github/scripts/x86_64_Linux/prebuilts/` (~8 MB total).

⏰ **The binary CDN is still up but the script paths on the same bucket are already 404.** The vendoring window is open now and there is no guarantee it stays open. Pull these five files first, before anything else in this phase:
```bash
for f in mksquashfs sqfscat sqfstar unsquashfs; do
  curl -fsSL "https://bin.ajam.dev/x86_64_Linux/Baseutils/squashfstools/$f" \
    -o ".github/scripts/x86_64_Linux/prebuilts/$f"
done
curl -fsSL "https://bin.ajam.dev/x86_64_Linux/dockerc" \
  -o ".github/scripts/x86_64_Linux/prebuilts/dockerc"
```

### Step 2 — break the script-fetch chain
- `build_debian.sh:51-53` → `source "${TOOLPACKS_REPO}/.github/scripts/x86_64_Linux/init_debian.sh"`, with `TOOLPACKS_REPO` derived from `${BASH_SOURCE[0]}` (not `GITHUB_WORKSPACE` — keeps the script usable outside CI)
- `workflow:184-185` → invoke from the checkout
- **Delete the rclone gates** — `build_debian.sh:84-109` and `gen_meta.sh:49-59` are `exit 1`s, not warnings
- Update header comments that document the install one-liner (`build_debian.sh:11`, `init_debian.sh:17`, `gen_meta.sh:4-5`, `gen_yaml.sh:3`, `env.sh:3`) — it becomes `git clone --depth 1 && bash .github/scripts/x86_64_Linux/build_debian.sh`

### Step 3 — verify adversarially (highest-value test in the plan)
A `smoke` job that:
1. checks out the repo
2. `echo "127.0.0.1 pub.ajam.dev bin.ajam.dev" | sudo tee -a /etc/hosts`
3. runs full `init_debian.sh` + one fast recipe (`7z.sh`, ~10 s) + one `oras push`

A `grep` cannot see URLs constructed at runtime, and there are several in recipe bodies. **Keep this job in CI permanently** so a future recipe can't reintroduce the dependency.

### Step 4 — delete `presetup` (`workflow:20-109`)
Its only surviving purpose was mirroring the repo to R2 so the builder could curl it back. Replace with a tiny `prepare` job. `bins/metadata.json` becomes dead — remove it and its consumers (`build_debian.sh:128`, `gen_meta.sh:13`, `gen_yaml.sh:13`).

*Verify:* the blackhole smoke job passes. **Record `init_debian.sh` wall time on a hosted runner** — it sets the shard count.

---

## Phase 2 — GHCR publish path (~1–2 days)

### Push with annotations — this replaces the checksum round-trip entirely
```bash
oras push ghcr.io/OWNER/toolpacks/<family>:latest,<YYYY.MM.DD> \
  --annotation "org.opencontainers.image.created=<RFC3339 build time>" \
  --annotation "dev.pkgforge.pkg_family=<family>" \
  --annotation "dev.pkgforge.build_run=${GITHUB_RUN_ID}" \
  --annotation "<file>:dev.pkgforge.b3sum=<blake3>" \
  --annotation "<file>:dev.pkgforge.file=<file(1) output>" \
  <file>:application/octet-stream ...
```

**Why this is strictly better than what R2 did:**

| old source | new source |
|---|---|
| `rclone lsjson .Path` | `layers[i].annotations["…image.title"]` |
| `rclone lsjson .Size` | `layers[i].size` |
| `rclone lsjson .ModTime` (object mtime) | manifest `…image.created` — the **real build time** |
| `SHA256SUM.txt` | `layers[i].digest` — ORAS pushes raw blobs, so the layer digest **is** the file's sha256 |
| `BLAKE3SUM.txt` | `layers[i].annotations["dev.pkgforge.b3sum"]` |
| `FILE.txt` | `layers[i].annotations["dev.pkgforge.file"]` |

`sha256` now needs no annotation and no trust — it's cryptographically bound to the registry's content addressing.

**The union problem dissolves.** R2 needed `rclone_main_dw` (`build_debian.sh:230-235`) because it was a dumb blob store and `$BINDIR` ≠ published set. GHCR holds exactly (this run's successes) ∪ (everything previously published), because push is additive per-package and untouched packages keep their `:latest`. **There is no merge step to get wrong** — you never build the file list from `$BINDIR` again.

Push **per-recipe, not per-shard**: a shard dying at hour 5 has already published hours 0–4.
Push **all of a package's files in one `oras push`** — the manifest is written last, so a partial manifest can never exist.

### Read side (finalize)
1. `GET /orgs/{org}/packages?package_type=container&per_page=100` — **follow `Link: rel="next"` to exhaustion**
2. `oras manifest fetch` each (~925, parallel 16-way, ~1–2 min)
3. Regenerate `BLAKE3SUM.txt`/`SHA256SUM.txt`/`FILE.txt`/`SIZE.txt` from that, commit to `x86_64-Linux/`

The committed files from the last good run become a **cross-check, not the source of truth**. Diff GHCR-derived vs git-committed and report: in-git-not-GHCR (package deleted, went private, or push failed silently) / in-GHCR-not-git (new tools) / same-name-changed-b3sum-but-not-rebuilt (something is very wrong). Fail on bucket 1 over a small threshold.

### ⚠️ GHCR packages are PRIVATE by default
A workflow-token `oras push` creates a **private** package. Anonymous pull 404s. You get a green build and a cache nobody can read — the same class of silent failure as empty checksums, one layer down.

Needs explicit visibility per *new* package: `PATCH /orgs/{org}/packages/container/{pkg}` with the name URL-encoded (`toolpacks%2F7z` — package names contain `/`; un-encoded gives 404 and the package silently vanishes from the union).

### Retention
15 GB/month retained forever ≈ **180 GB/year**. Policy now, not later: keep the last N date tags per package, delete untagged versions in finalize.

### Named failure modes
1. **Pagination truncation** — 100 of 925 packages. `gen_meta.sh:217`'s <1000 gate catches it, but add an explicit "package count ≥ previous − 5" assert for a clear message.
2. **URL encoding** — see above. Assert `packages_listed == manifests_fetched`.
3. **Private by default** — unauthenticated pull smoke test of 3 random packages in finalize.
4. **Index vs manifest** — if anything pushes an OCI index, `.layers` is null and that tool vanishes silently. Handle both `mediaType` cases.
5. **Missing `b3sum` annotation** reproduces the original corruption exactly: `gen_meta.sh:194/197`'s `// ""` → empty string → green build. **Mandatory gate:** assert `[.[] | select(.b3sum=="" or .sha256=="" or .download_url=="" or .pkg_family=="")] | length == 0`. The <1000 count gate does **not** catch this.
6. **Rate limits** — `gen_meta.sh:93,94,109,110` already makes ~2800 calls against a 5000/hr budget. Adding ~1850 goes over. Cache repo metadata by `repo_url` (many recipes share one); retry on 429.

### Builder image
Build `ghcr.io/OWNER/toolpacks-builder:<date>` from `init_debian.sh` once; shards run with `container:`. Pays for itself on the first run.

*Verify:* every annotation present in `oras manifest fetch`. **Unauthenticated** pull from a clean container. `@sha256:` digest pull. Layer digest == local `sha256sum`. Second push of an unchanged file dedupes.

---

## Phase 3 — Sharding + accounting (~1–2 days)

### `prepare` job
Builds `RECIPES.txt` (all minus EXCLUDE.txt), emits `matrix={"shard":[0..N-1]}` via `fromJSON`, uploads `RECIPES.txt` as an artifact so **every shard slices the same list** (don't let each shard re-`find` — a tree change mid-run desyncs the partition).

**Asserts** `Σ|shard_i| == |RECIPES.txt|` and that the sorted-unique concatenation equals the input. A stride bug that drops or duplicates recipes is otherwise invisible.

### Slice
```bash
for ((i=SHARD_INDEX; i<${#RECIPES[@]}; i+=SHARD_TOTAL)); do
```
Stride, not contiguous blocks — alphabetically-adjacent `coreutils-*` clusters would otherwise land in one shard. `SHARD_TOTAL` is a `workflow_dispatch` input with a default, so it retunes without a code change.

### Deadline handling
- `timeout-minutes: 350` (below the 360 cap)
- inside the loop: if elapsed > 320 min, stop voluntarily and mark remaining recipes `deadline`. Being *killed* at 360 loses RESULT.jsonl and the step summary.
- per recipe: `timeout -k 60 30m` (p99 is 656 s; 30 min catches the `zcip` class and real hangs)

### Per-recipe accounting
```bash
LOG="${LOGDIR}/${FAMILY}.log.txt"
BEFORE="$(find "$BINDIR" -maxdepth 1 -type f -printf '%f\n' | sort)"
( timeout -k 60 30m bash -c 'source "$BUILDSCRIPT"' ) 2>&1 | tee "$LOG"
RC="${PIPESTATUS[0]}"
AFTER="$(find "$BINDIR" -maxdepth 1 -type f -printf '%f\n' | sort)"
PRODUCED="$(comm -13 <(echo "$BEFORE") <(echo "$AFTER"))"
```
Status: `ok` (RC=0 and PRODUCED ⊇ the `bins:` list in the yaml) / **`partial`** (RC=0 but declared bins missing — *the old pipeline could never see this, and it's common*) / `fail` / `timeout` (RC=124) / `deadline`.

One JSON line per recipe → `RESULT.${SHARD_INDEX}.jsonl`, uploaded as an artifact. Also gives the duration series needed to retune shard count.

**Bonus:** `tee "$LOG"` produces per-family logs directly, which kills the entire `gen_meta.sh:142-159` scheme of grepping a 49 MB monolith for line ranges — and with it the `pub.ajam.dev` string coupling between `build_debian.sh:158` and `gen_meta.sh:143`. **Delete that mechanism rather than porting it to a new URL.**

### Failure surfacing
Shards do **not** fail on individual recipe failure (you'd throw away 45 good builds for 1 bad). Enforcement lives in `finalize` (`if: always()`, `needs: [build]`):
- concatenate all `RESULT.*.jsonl`, write a status table to `$GITHUB_STEP_SUMMARY`
- **fail the workflow** if: any shard produced no RESULT file (died before writing), OR `fail+timeout+deadline > 10%` of attempted, OR `fail > previous + 25` (tracked in the existing `x86_64-Linux/BUILD_ERROR.log.md`)

Drop `continue-on-error: true` from finalize's gating steps; keep it on the Telegram notifications (`workflow:268`).

*Verify:* partition assertion fires when you deliberately off-by-one the stride. Break one recipe → appears as `fail`. Delete a declared `bins:` output → appears as `partial`.

---

## Phase 4 — Metadata regeneration (~2 days)

`download_url` is currently minted at `healthchecks_housekeeping.yaml:430` and merely enriched by `gen_meta.sh` — two workflows 12 hours apart co-owning one field. **Collapse it: finalize generates the whole METADATA.json.** `healthchecks_housekeeping.yaml` reverts to health checks and README generation.

### Schema (additive — existing consumers keep working)
```json
{
  "download_url": "https://ghcr.io/v2/OWNER/toolpacks/<family>/blobs/sha256:<digest>",
  "ghcr_pkg":    "ghcr.io/OWNER/toolpacks/<family>:2026.09.01",
  "ghcr_digest": "sha256:<digest>",
  "sha256":      "<same as ghcr_digest minus prefix>"
}
```

### ⚠️ Known gap while `direct` is deferred: no plain-curl path

GHCR blobs need a bearer token from `ghcr.io/token?scope=repository:OWNER/toolpacks/<tool>:pull` — **three requests and a JSON parse**, not one curl:

```bash
TOKEN=$(curl -fsSL "https://ghcr.io/token?scope=repository:OWNER/toolpacks/ripgrep:pull&service=ghcr.io" | jq -r .token)
DIGEST=$(curl -fsSL -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.oci.image.manifest.v1+json" \
  "https://ghcr.io/v2/OWNER/toolpacks/ripgrep/manifests/latest" | jq -r '.layers[0].digest')
curl -fsSL -H "Authorization: Bearer $TOKEN" \
  "https://ghcr.io/v2/OWNER/toolpacks/ripgrep/blobs/$DIGEST" -o ripgrep
```

It also needs `jq`, which breaks the bootstrap case (*"I have a bare box, get me `jq`"* — you can't require `jq` to install `jq`).

**This is the thing `direct` was going to fix.** At ≤20 MB it would have covered 1,261 of 1,460 files (86%) with a plain CDN-backed `raw.githubusercontent.com` URL and no token. Until it lands, every consumer needs `oras` or the three-request dance.

Options while deferred — pick one before Phase 4 ships:
1. **Accept it.** Document the token requirement. `soar` can speak the registry protocol natively, so the main consumer is unaffected; only raw-curl users feel it.
2. **Pull `direct` forward** into this sequence after all.
3. **Interim redirector.** A tiny Worker/Pages function mapping `/<tool>` → a signed blob URL. Restores the one-liner without the git-size problem, but adds a service to run.

The zero-empty-field gate below must treat `download_url` as the GHCR blob URL, not a raw URL, until this is settled.

### `build_log` derivation must die
`gen_meta.sh:152-153` derives it as `download_url + ".log.txt"` — coupling a metadata field to branch layout by string surgery. Set it explicitly to `…/main/x86_64-Linux/logs/<family>.log.txt` and have finalize commit the per-family logs (the 49 MB monolith splits into ~925 files averaging 50 KB; commit only changed ones). Drop the hardcoded fallbacks at `gen_meta.sh:155,159`.

### `pkg_family`
`gen_meta.sh:76` derives it via `sed 's|.*/bins/\(.*\)\.yaml$|\1|'` — needs a literal `/bins/<name>.yaml` segment or it's silently empty. Reading from the checkout makes it `basename "$f" .yaml` and the fragility evaporates. **Assert non-empty** regardless.

*Verify:* keep the <1000 gate (`gen_meta.sh:217`). Add the zero-empty-field gate. Entry count within ±5% of the committed 1,109. Field-by-field compare 20 sampled tools against the committed METADATA.json. Resolve `ghcr_digest` for 20 random entries and confirm the blob fetches.

---

## Phase 5 — Cadence + first full run (~1 day, mostly waiting)

```yaml
# build_x86_64_Linux.yaml:9
- cron: "30 18 1 * *"    # monthly, replacing "30 18 * * 1"
```

Add a staleness gate — `BUILD_DATES.txt` shows ~250 tools went stale 1–5 months while the build reported success:
```bash
STALE=$(awk -v c="$(date -d '45 days ago' +%Y-%m-%d)" '$1 < c' BUILD_DATES.txt | wc -l)
[ "$STALE" -gt 50 ] && { echo "::error::$STALE stale tools"; exit 1; }
```

*Verify:* every shard under 6 h with margin; published packages ≈ 827; all phase-4 gates green; a fresh machine can `curl` from `download_url` and `oras pull` by digest.

---

## Deferred work (not in this sequence)

### `direct` branch — ~1 day when picked up
Design notes so they aren't re-derived later:
- **Shards never push.** Each applies the cap at upload time — `find "$BINDIR" -maxdepth 1 -type f -size -20971520c` (**explicit bytes**; `-size -20M` uses 1 MiB blocks and rounds *up*) — and uploads `direct-shard-${N}`. One `publish-direct` job merges and pushes once. Twenty jobs contending on a branch is unsolvable with retries at this size.
- **5.46 GB will not push in one commit** — GitHub rejects pushes over ~2 GB. Use an orphan `direct-staging` branch, ~12 commits of ~450 MB each pushed incrementally, then `push --force direct-staging:direct`. The staging indirection means `direct` is never half-populated.
- **gc debt:** orphan+force-push every run leaves unreachable objects gc'd on GitHub's schedule, not yours — ~65 GB/yr backing 5.5 GB live. A separate `Toolpacks-direct` repo isolates this; a branch in the main repo means `actions/checkout` must keep `filter: blob:none` forever (already set at `workflow:31,125`).
- Landing it closes the plain-curl gap in Phase 4 (86% coverage at ≤20 MB).

### Baseutils — ~3–4 days
83 recipes, 73 with embedded rclone publish blocks (`bins/cryptsetup.sh:38-81` is representative). They publish *directory trees* with per-directory `INFO.json`/`BLAKE3SUM.txt`, consumed at `healthchecks_housekeeping.yaml:452-465` — a different shape from the flat `$BINDIR`. Each family maps naturally to one GHCR package with the tree as layers, but the publish logic must be **factored into a shared function, not edited 73 times**.

---

## Sequence

```
Phase 0  strip to x86_64          0.5d   mechanical
Phase 1  de-circularize           1d     BLOCKING; squashfs vendoring is time-critical
Phase 2  GHCR publish path        1-2d   annotations replace the round-trip
Phase 3  sharding + accounting    1-2d
Phase 4  metadata regeneration    2d
Phase 5  cadence + first run      1d
                                  ~7d total
deferred: direct (1d), baseutils (3-4d)
```

## Severity-ranked risks

| Problem | Impact |
|---|---|
| GHCR private by default | **Silent:** green build, unreadable cache |
| Missing `b3sum` annotation → `// ""` | **Silent:** the <1000 gate does not catch it |
| `exit` in sourced recipe kills the shard | **Silent:** partial shard, exit 0 |
| No plain-curl path while `direct` is deferred | User-visible: `oras` or 3 requests + `jq` |
| Version tags not derivable (923/925) | Blocks the original tagging scheme |
| Arsenal deps + `to_human_bytes.jq` **already 404** | Build is broken today; `init_debian.sh:189` fails before any recipe runs |
| Shard mis-sizing / concurrency wall | 21% waste, blocks other CI |
| Unbounded GHCR retention | ~180 GB/yr |
