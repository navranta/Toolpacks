# Toolpacks — agent working agreement

Kept byte-identical with `CLAUDE.md`. Change one, change the other.

## 1. Never build, compile, or test on this machine

This repo builds 133 statically linked binaries. **None of that runs locally — ever.**
Not "just this once to check", not a throwaway container, not a two-file repro.

Forbidden on the local machine:

- `build_debian.sh`, `init_debian.sh`, any `bins/*.sh` recipe
- `docker run` / `docker build` / `docker pull` — including throwaway registries, `alpine-builder`, etc.
- `nix-build`, `go build`, `cargo build`, `make`, or any compiler/toolchain invocation
- installing anything: `apt-get install`, `pip install`, `npm i`, downloading binaries to run
- executing a built artifact to "see if it works"

Allowed locally: reading files, `git`, `gh`, static checks that execute nothing
(`bash -n`, `jq`/`yq` over text, grepping logs you fetched with `gh`).

If you think you need to run something to verify a hypothesis: **dispatch it to CI instead**
(section 2). A CI round trip costs ~10 minutes; it is always the right trade.

## 2. Test in CI, cheapest entry point first

| What it covers | How to dispatch | Wall time |
|---|---|---|
| One or a few recipes, real build + real ORAS push | `gh workflow run test_recipes.yaml --ref <branch> -f recipes="7z gau" -f push_test=false` | ~10 min |
| Full catalogue, metadata gates, publish | `gh workflow run build_x86_64_Linux.yaml --ref main` | ~1.5–2 h |
| Installers + per-binary smoke test | `gh workflow run test-installers.yaml --repo navranta/toolpacks-install-test` | ~30–90 min |

Notes:

- `push_test=true` publishes to the real `toolpacks` GHCR namespace; `false` (default) uses
  `toolpacks-test`. Use `true` only when you specifically need to verify published metadata.
- Init is the ~7.5 min floor on any recipe run, so 1 recipe and 4 recipes cost about the same.
- Reproduce with the **smallest recipe set that triggers the bug**, not a full build. Ordering
  bugs need the pair (e.g. `fuse3 gau` for a `$BINDIR` permission leak); most bugs need one.
- To verify published metadata without a build, fetch the manifest over plain HTTPS and run the
  real `gen_meta.sh` gate against it — no local build required.

## 3. Run unattended — never hand the turn back to a human to wait

Assume whoever started you is AFK and expects to come back to finished work.

**Never end a turn waiting on CI.** Do not close with "I've dispatched the run, ping me when
it finishes", "let me know how it goes", or "tell me when you want me to continue". A run
takes 10 minutes to 2 hours; parking the work on a human for that window is the whole failure
this file exists to prevent.

Wait for the run *yourself*, then carry on. Use an `until` loop:

```bash
until s=$(gh run view <RUN_ID> --json status,conclusion \
            -q '.status + " " + (.conclusion // "null")' 2>&1); [[ "$s" == completed* ]]; do
  sleep 300   # 60 for the fast loop, 300 for a full build
done
echo "FINAL: $s"
```

Foreground or background does not matter — pick whatever keeps *you* running in your harness
(in Claude Code, `run_in_background: true` returns a notification that wakes you; elsewhere a
blocking loop that holds the turn open is equally correct). The only hard requirement is that
**you** are what resumes when the run finishes, not the user.

### The loop

1. Dispatch the cheapest workflow that can show the bug.
2. Wait for it with the `until` loop above.
3. Green → step 6. Red → `gh run view <ID> --log-failed`, find the **root cause**, not the symptom.
4. Fix, commit, push.
5. Re-dispatch; go to 2.
6. Done — now report.

Do not ask permission to continue mid-loop. Re-dispatching after a fix is the obvious next
step, not a decision needing sign-off. Do not stop while a known failure is outstanding, and
do not report success off a partial signal (a green `build` job says nothing about `finalize`).

### When you may stop and come back to the human

- CI is genuinely green.
- You are blocked on something only they can do: a secret or credential, an account permission,
  an irreversible or outward-facing action, or a product decision with no defensible default.
- The same failure has survived roughly three distinct, well-reasoned fix attempts and further
  attempts would be guessing.

In every case, say what you tried, what the evidence was, and what you need. "Still waiting on
CI" is never a reason to stop.

### Reading a run

```bash
gh run view <ID> --json jobs -q '.jobs[]|{name,status,conclusion}'   # job-level status
gh run view <ID> --log-failed                                        # only failing steps
gh api /repos/navranta/Toolpacks/actions/jobs/<JOB_ID>/logs \
  --allow-escape-sequences                                           # a job of a RUNNING run
```

### Separate real failures from noise

Before chasing a red check, confirm it is actually yours:

- `lint` (ActionLint) and `generated` (pinned builder image) are **already red on `main`** —
  pre-existing, unrelated to most changes. Verify against `main` before blaming your diff.
- Release-CDN `504`s and similar network errors in `init_debian.sh` are flakes — re-run the job.
- `smoke` only depends on `prepare`; it does **not** gate `build` or `finalize`, but it does
  turn the whole run red. Read job conclusions individually, not just the run conclusion.

## 4. Fixes land as small, root-caused commits

This pipeline's failure mode is silent corruption that still exits 0, so:

- Fix the cause, not the gate. If a gate fires, the gate is usually right.
- One logical fix per commit, with the evidence (run ID, log line) in the message.
- Prefer one systemic fix in the shared loop over N copies patched into `bins/*.sh`.
