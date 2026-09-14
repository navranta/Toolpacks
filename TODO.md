# TODO — handoff for the next agent

Written 2026-09-14 mid-session. **Read `AGENTS.md` first** — it has the hard rules (nothing
builds locally; test in CI; wait for runs yourself and keep iterating instead of handing the
turn back to a human).

State at handoff: `main` is at the three fixes below. A full build was still in flight and
nobody has yet seen this pipeline go green end to end.

---

## What was fixed, and how it was proven

| # | Fix | Commit | Evidence it works |
|---|---|---|---|
| 1 | `oras --annotation` cannot scope to a layer; use `--annotation-file` | `285d52a` (#6) | Live GHCR manifest for `7z` carries `dev.toolpacks.b3sum` under `layers[].annotations`; the real `gen_meta.sh` passed its gate against production. Gate failures dropped 161 → 10. |
| 2 | Reassert `chmod u+rwx "$BINDIR"` before every recipe | `9118f45` (#7) | Fast-loop `fuse3 gau`: BINDIR stayed 755, `gau` went `partial` → `ok`. |
| 3 | Report BINDIR mode *before* healing; flag unrepairable ownership | `eabf578` (#8) | — (diagnostic only) |
| 4 | Clear three shellcheck findings | `#9` | `lint` check went green. |

### The two original bugs, for context

**Bug 1 — every metadata entry had an empty `b3sum`.** `ghcr_push.sh` pushed per-file
checksums with `oras push --annotation "${f}:dev.toolpacks.b3sum=..."`, intending to scope the
annotation to one layer. That syntax is not real: oras only ever takes manifest-level
`key=value`, so the whole string became a literal manifest annotation key
(`"7z:dev.toolpacks.b3sum"`), leaving `layers[].annotations` empty. `gen_meta.sh` reads it
per-layer with a `// ""` fallback, so the gate failed for 100% of entries, every run, forever.

**Bug 2 — a recipe could lock every later recipe out of `$BINDIR`.** `fuse3.sh` does
`rsync -av --copy-links "./result-bin/bin/." "$BINDIR/"`. Nix store outputs are read-only
(555), and rsync's `-a` (implies `-p`) stamps the *source* directory's permission bits onto the
*destination* directory. `$BINDIR` went `700 → 555`, and every recipe after it failed with
"Permission denied" while still reporting rc=0 → status `ok`/`partial` with nothing produced,
so `ghcr_push_recipe` was never called and GHCR kept serving the old broken manifest.

Resolved concern, recorded so nobody re-litigates it: ownership is **not** affected, only mode.
The failing production case was `runner:runner 555`, and a CI test (`zstd` → `7z`, run
`34858509153`) confirmed a `sudo rsync` recipe leaves `$BINDIR` as `runner:runner 755`. Nix
here is single-user, so an unprivileged `chmod` is always sufficient.

---

## Open items, highest value first

### 1. Confirm the full build actually goes green — nobody has seen this yet

Run `34856163414` (started 14:31Z on `main`) was still in `build` at handoff. It carries fixes
1 and 2 but **not** 3 or 4.

```bash
gh run view 34856163414 --json jobs -q '.jobs[]|{name,conclusion}'
gh run view 34856163414 --log-failed
```

Expect `finalize`'s empty-field gate to reach **0** (was 161, then 10). If it is not 0, the
remaining entries are families that still did not re-push — diagnose per item 2/3 below. If the
run is too old or was superseded, just dispatch a fresh one:

```bash
gh workflow run build_x86_64_Linux.yaml --ref main
```

### 2. `husarnet` / `husarnet-daemon` — stale for a reason we never identified

Both were among the 10 stale entries in run `34813094370`, but **`husarnet` was not in the
`fuse3` lockout window** (that window was recipes 49–58, `gau` → `gitlab-cli`; `husarnet` sorts
well after `gitlab-subdomains`, by which point the mode was back to 700). Its manifest is
stamped `build_run: 34759781797`, i.e. a run from the day before.

So fix 2 probably does **not** explain husarnet, and it may still be stale after the current
build. Check whether it re-pushed; if not, read its recipe log for why `PRODUCED` came back
empty:

```bash
gh run view <RUN_ID> --log | grep -A40 "Building : husarnet"
gh workflow run test_recipes.yaml --ref main -f recipes="husarnet" -f push_test=false
```

### 3. `getJS` has never published at all

`gen_meta.sh` reports `unpublished: getJS` — no manifest on GHCR whatsoever, which is a
different failure from the stale ones. It is the single reason the manifest count is 132/133.
Worth one fast-loop run to see what its recipe actually does.

### 4. Two `finalize` steps have never executed — expect new failures there

`gen_meta.sh` has failed on every run so far, so everything after it in `finalize` is unproven.
When the gate finally passes, these run for the first time:

- **"Verify packages are pullable ANONYMOUSLY"** — samples 3 random families and fails if any
  is not anonymously pullable. **Suspect this one.** Build logs show
  `[!] zerotier: visibility PATCH 404 (wrong owner type or not yet indexed)`. `ghcr_make_public`
  PATCHes `https://api.github.com/users/${OWNER}/packages/container/${pkg}`, but for
  user-owned packages GitHub's mutating endpoint is `/user/packages/container/{name}` (the
  authenticated-user form), not `/users/{username}/...` which is read-only. If that is the bug,
  packages stay private and this step fails. Note `7z` *is* anonymously pullable today, so it is
  not universal — verify before changing anything.
- **"Commit metadata and logs"** — does a `git push` to `main` from CI. Never exercised;
  could conflict with concurrent merges.
- **Staleness gate** — fails if >15 tools in `BUILD_DATES.txt` are older than 45 days. Since
  metadata has never been written, this may well trip on its first real run.

### 5. `generated` check is still red — needs a human decision

It requires `azathothas/alpine-builder` to be pinned to a dated tag, but **117 recipes** use
`:latest` with `--pull=always`. Pinning changes what every container recipe builds against, so
somebody has to choose the tag deliberately. Not a drive-by fix. Everything else in CI is green
after `#9`.

### 6. `smoke` is flaky on transient CDN failures

Run `34856163414`'s `smoke` failed purely on
`download error: 504 ... mold-2.42.1-x86_64-linux.tar.gz` inside `init_debian.sh`. One CDN
hiccup fails the whole job (and reddens the whole run, though `smoke` gates neither `build` nor
`finalize`). Re-run it after the run completes:

```bash
gh run rerun <RUN_ID> --job <SMOKE_JOB_ID>   # only works once the run is no longer in progress
```

Consider adding a retry around the prebuilt downloads in `init_debian.sh` so a single 504 does
not cost a 90-minute job.

### 7. Minor: `ghcr_push_recipe` now hard-depends on `jq`, unguarded

The `--annotation-file` fix builds JSON with `jq`. If `jq` were ever missing, `jq -n` writes an
empty file and `oras push` fails → the family keeps its old manifest. `jq` is installed by
`init_debian.sh` (both via apt and the vendored prebuilts), so this is safe today. But the
function guards `b3sum` explicitly two lines away and does not guard this — worth matching.

---

## How to read this pipeline's failures

The recurring disease here is **silent corruption that still exits 0**: empty checksums shipping
green, ~250 tools going stale unnoticed, recipes reporting `ok` while producing nothing. So:

- A recipe's `rc=0` means nothing. Check `PRODUCED`, and check whether the family's manifest
  `build_run` annotation matches the run you just did:
  ```bash
  T=$(curl -qfsSL "https://ghcr.io/token?scope=repository:navranta/toolpacks/<FAM>:pull&service=ghcr.io" \
      | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
  curl -qfsSL -H "Authorization: Bearer $T" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json" \
    "https://ghcr.io/v2/navranta/toolpacks/<FAM>/manifests/latest" | jq .
  ```
  A `build_run` from an older run means that family silently did not re-push.
- If a gate fires, the gate is usually right. Fix the cause, never the gate.
- `build_debian.sh` now logs `BINDIR pre <owner> <mode>` **before** any healing, plus
  `BINDIR was not writable; healed to ...` or `BINDIR NOT writable and chmod failed ...`.
  Grep those when recipes mysteriously produce nothing.
- Pre-existing reds to not waste time on: `generated` (item 5). `lint` is green as of `#9`.
