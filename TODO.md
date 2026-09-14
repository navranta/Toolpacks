# TODO — handoff for the next agent

Updated 2026-09-14 ~16:35Z. **Read `AGENTS.md` first** — hard rules (nothing
builds locally; test in CI; wait for runs yourself, never hand the turn back
to a human to wait).

State: `main` carries fixes #12–#16 below. Full build `34869139381` (started
16:3xZ on current `main`) is in flight — nobody has yet seen this pipeline go
green end to end, this run is the first that can.

---

## What was fixed, and how it was proven

| # | Fix | PR | Evidence it works |
|---|---|---|---|
| 1 | `oras --annotation` cannot scope to a layer; use `--annotation-file` | #6 | Live GHCR manifest for `7z` carries `dev.toolpacks.b3sum` under `layers[].annotations`; gate failures 161 → 10. |
| 2 | Reassert `chmod u+rwx "$BINDIR"` before every recipe | #7 | Fast-loop `fuse3 gau`: `gau` `partial` → `ok`; full build `34856163414` confirms (`gau`, `getJS` ok). |
| 3 | Report BINDIR mode *before* healing; flag unrepairable ownership | #8 | Diagnostic only. |
| 4 | Clear three shellcheck findings | #9 | `lint` green. |
| 5 | `husarnet` ouch fetch matched 4 assets (AppImage+tar.gz+sigstores) and prompted interactively → `./ouch` never materialized, `partial` rc=0 | #12 | Fast-loop: `partial` → `ok`, 2 files pushed. Mirrors `ouch.sh` (`tar.gz` + `$EGET_EXCLUDE`). |
| 6 | `getJS` could never publish: ORAS rejects uppercase repo (`invalid reference: .../toolpacks/getJS`); build said `ok` while push failed, so no manifest ever existed | #16 | Fast-loop pushes `toolpacks-test/getjs`; real-namespace run `34868524516` pushed `toolpacks/husarnet` (2 files) + `toolpacks/getjs` (1 file). Lowercases only the registry path (push ref, meta fetch + `download_url`/`ghcr_pkg`, installer family arg, anon-pull check); annotations/titles/binaries keep case. |
| 7 | `ghcr_make_public` PATCHed read-only `/users/<name>/...` (and `/user/...` has no PATCH route either — both 404, verified live); every push logged `[!] 404` while packages were public via repo inheritance | #13 | GET-gated: PATCH only when actually private. Fast-loop shows `[+] 7z: already public`. |
| 8 | `ghcr_push_recipe` hard-depended on `jq`, unguarded | #14 | Refuses to push without annotations. No CI behavior change (jq always installed); `bash -n`. |
| 9 | `smoke` died on one transient 504 fetching mold; same 504 class staled `aria2 cdncheck cent glow puredns` in build `34856163414` (empty PRODUCED, rc=0) | #15 | mold fetch retried 3x; fast-loop shows healthy init. Retry path only fires on a 504. |

### Bugs 1–3, for context

**Bug 1 — every metadata entry had an empty `b3sum`.** `ghcr_push.sh` pushed
per-file checksums with `oras push --annotation "${f}:dev.toolpacks.b3sum=..."`.
Not real syntax — oras only takes manifest-level `key=value` — so the whole
string became a literal manifest annotation key, leaving
`layers[].annotations` empty. `gen_meta.sh` reads per-layer with `// ""`, so
the gate failed for 100% of entries, every run, forever.

**Bug 2 — a recipe could lock every later recipe out of `$BINDIR`.**
`fuse3.sh` does `rsync -av --copy-links "./result-bin/bin/." "$BINDIR/"`. Nix
store outputs are read-only (555); rsync `-a` stamps source dir perms onto the
destination. `$BINDIR` went `700 → 555`; later recipes failed with "Permission
denied" while rc stayed 0 → `ok`/`partial` with nothing produced, never pushed.

**Bug 3 — `getJS` failed its push on every run and nobody noticed.** OCI
repository paths must be lowercase; `getJS` is the only uppercase family of
133. Push failure is non-fatal (`|| echo "[-] publish failed"`), STATUS stays
`ok`, so GHCR never held a manifest and `gen_meta` reported `unpublished:
getJS` forever. Same silent-rc=0 disease as bugs 1–2.

Resolved concerns, recorded so nobody re-litigates them:

- BINDIR ownership is **not** affected, only mode (`runner:runner 555` case;
  `sudo rsync` leaves `runner:runner 755`). Single-user nix ⇒ unprivileged
  `chmod` suffices.
- Package publicity comes from **repo inheritance**, not the visibility PATCH
  (no PATCH route exists for user-scoped container packages). The finalize
  anonymous-pull gate is the real check; per-push PATCH is best-effort only.
- `getJS` needed no recipe change — its `partial` in run `34813094370` was
  Bug 2 (BINDIR 555, `cp: Permission denied`); its `unpublished` was Bug 3.

---

## Open items, highest value first

### 1. Confirm the full build goes green — run `34869139381` is the candidate

```bash
gh run view 34869139381 --json jobs -q '.jobs[]|{name,conclusion}'
gh run view 34869139381 --log-failed
```

Prior run `34856163414` (fixes 1+2 only): `build` green, finalize gate at
**2 empties** (`husarnet` x2, old code) + `unpublished: getJS`. Since then both
families re-pushed for real (run `34868524516`). A curl+jq replication of the
empty-field gate against production **now shows 162 entries, 0 empty** — so
the gate should pass on this run. If it does not, the remaining entries are
families that did not re-push in *this* run (check `PRODUCED` + `build_run`).

When the gate passes, three `finalize` steps run for the first time:

- **"Verify packages are pullable ANONYMOUSLY"** — samples 3 families. Should
  pass (spot-checked: real + test namespaces publicly pullable).
- **"Commit metadata and logs"** — `git push` to `main` from CI. Never
  exercised; could conflict with concurrent merges (merge #12–#16 first —
  done — and avoid pushing while it runs).
- **Staleness gate** — fails if >15 tools in `BUILD_DATES.txt` older than 45
  days. Fresh metadata ⇒ ~0 stale ⇒ should pass.

### 2. Transient 504s still stale whole families with rc=0

`aria2 cdncheck cent glow puredns` produced nothing in `34856163414` on
`download error: 504` (eget, GitHub release CDN). Their manifests are still
good (pushed with b3sum in an earlier run), so the gate does not care — but
they will silently lag upstream until some run gets lucky. #15 retries only
init's mold fetch. If 504s keep staling recipes run after run, the systemic
fix is retry around the recipe-level eget calls (shared-loop form, not 100+
recipe edits) — sized, not started.

### 3. `generated` check needs a human decision

Requires `azathothas/alpine-builder` pinned to a dated tag; **117 recipes**
use `:latest` with `--pull=always`. Pinning changes what every container
recipe builds against. Not a drive-by fix.

### 4. `smoke` only gates noise, but watch it

It depends on `prepare` only; never gates `build`/`finalize`. Re-run it if a
fresh 504 reddens the run:
```bash
gh run rerun <RUN_ID> --job <SMOKE_JOB_ID>  # only once the run is completed
```

---

## How to read this pipeline's failures

The recurring disease is **silent corruption that still exits 0**: empty
checksums shipping green, stale manifests unnoticed, recipes `ok` while
producing nothing, pushes failing without changing STATUS. So:

- A recipe's `rc=0` / `ok` means nothing by itself. Check `PRODUCED`, check
  for `pushing ghcr.io/...` + absence of `oras push FAILED`, and check the
  family's manifest `build_run` annotation matches your run:
  ```bash
  T=$(curl -qfsSL "https://ghcr.io/token?scope=repository:navranta/toolpacks/<FAM>:pull&service=ghcr.io" \
      | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
  curl -qfsSL -H "Authorization: Bearer $T" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json" \
    "https://ghcr.io/v2/navranta/toolpacks/<FAM>/manifests/latest" | jq .
  ```
  (Use the lowercased family in the URL. A `build_run` from an older run
  means that family silently did not re-push.)
- If a gate fires, the gate is usually right. Fix the cause, never the gate.
- `build_debian.sh` logs `BINDIR pre <owner> <mode>` before healing, plus
  `healed to ...` / `NOT writable and chmod failed ...`. Grep those when
  recipes mysteriously produce nothing.
- To replicate the empty-field gate without a build: fetch all manifests as
  above (lowercased refs), then count layers with a title but empty
  `dev.toolpacks.b3sum` — that is exactly what the gate counts.
- Pre-existing reds to not waste time on: `generated` (item 3).
