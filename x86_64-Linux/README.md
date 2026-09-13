# x86_64-Linux

Build output. **Everything here is generated** by the `finalize` job of
[`build_x86_64_Linux.yaml`](../.github/workflows/build_x86_64_Linux.yaml) and
committed automatically. Do not edit by hand.

| file | source |
|---|---|
| `METADATA.json` / `.yaml` | GHCR manifests, via `gen_meta.sh` |
| `BLAKE3SUM.txt` | `dev.toolpacks.b3sum` annotations |
| `SHA256SUM.txt` | OCI layer digests (the digest *is* the sha256) |
| `FILE.txt` | `dev.toolpacks.file` annotations |
| `SIZE.txt` | OCI layer sizes |
| `BUILD_DATES.txt` | manifest `org.opencontainers.image.created` |
| `RESULT.jsonl` | one line per recipe: status, rc, duration, binaries produced |
| `logs/<family>.log.txt` | per-recipe build log |

This directory is empty until the first run of the rebuilt pipeline.

The previous contents were removed deliberately: they described 1,109 binaries
served from a Cloudflare R2 bucket that is no longer used, with 2,213
`download_url` values pointing at a host this project no longer depends on.
Shipping them would have been worse than shipping nothing. Two monolithic
build logs (153 MB combined) went with them — the build now writes one log per
recipe, which is what made the old line-range log-scraping scheme unnecessary.

For reference, the last full run under the old pipeline (2024-12-16) built 924
recipes in 14.8h serial. The current 133-recipe scope measures ~1.2h.
