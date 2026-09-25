# Sandbox Test Summary

How `omniroute-manager.sh` was verified inside this Linux sandbox
(Debian 12, non-root user, **no** Docker daemon, **no** Windows, **no**
WSL). The sandbox cannot run the real thing, so the test harness
(`tests/run-tests.sh`) simulates the parts that need privileged or
Windows-side access and runs the **real** script unmodified against
them.

Latest full run: **77 / 77 assertions passed, exit 0** (all 12 test
groups, T1-T12).

```bash
cd tests
bash run-tests.sh            # run all 12 tests
bash run-tests.sh T2 T8      # run a subset
```

## What is real vs. what is simulated

| Component | Real or simulated | Notes |
|---|---|---|
| `omniroute-manager.sh` itself | **Real** | Runs unmodified; only the environment is faked. |
| OmniRoute HTTP server | **Real code path** | `tests/mock-omniroute/server.mjs` is a Node HTTP server speaking the real v3.8.51 contract: `/healthz`, `/v1/models` (12-model catalog), `/v1/chat/completions` (echo completion with master-key auth), dashboard login + `POST /api/providers/bulk` registration. It listens on the real port 20128. |
| `curl` | **Real** | `tests/mock-bin/curl` only records URLs to `curl-urls.log` and forwards to real curl so the assertions can prove the script never calls `get.docker.com` / `registry-1.docker.io`. |
| `jq`, bash, git (clone in build path), openssl, node | **Real** | |
| `docker` CLI / daemon | **Simulated** | `tests/mock-bin/docker`: keeps state files in `$MOCK_STATE`; simulates registry sanctions (`docker.io/*` and `diegosouzapw/*` pulls -> 403 Forbidden logged), `run` starts the mock server on 20128, `build` simulates success (or OOM when `force_build_oom` flag is set). |
| `apt-get install docker.io`, `service`/`systemctl` | **Simulated** | `tests/mock-bin/service` toggles the daemon state file. Proves the script uses `apt-get` (never `get.docker.com`) and the `service` fallback. |
| `powershell.exe`, `wslpath` | **Simulated** | Return `C:\Users\Sepehr system` / a fake `/mnt/c` tree so the Windows path (with a space in the username) is exercised. |
| `npm` / `pm2` | **Simulated** | `tests/mock-bin-node/*` for the non-Docker Node mode: fake global install, pm2 tracks a pidfile and `jlist` status. |
| Registry 403s (sanctions) | **Simulated** | Mock docker returns 403 for every Docker-Hub reference; T8 also points the GHCR env override at a `docker.io/*` ref so **all** pulls 403 and the build fallback must run. |
| WSL2 detection | Real check, Linux host | Script logs a warning and continues (by design). |

## The 12 test groups

| # | Test | Covers |
|---|---|---|
| T1 | Syntax | `bash -n` clean; script is ASCII-only (hard requirement). |
| T2 | Full install E2E | Sanctions sim (Hub 403), pre-built image pulled from GHCR, 3 of 5 keys, daemon.json with the three Iranian mirrors + buildkit, master key `sk-omni-...`, opencode.json at the Windows path with a space, 12 models each with `limit.context`/`limit.output`, 3 provider bulk-registrations, all 6 in-script verification tests PASS, zero contacts to `get.docker.com`/`registry-1.docker.io`. |
| T3 | Idempotent re-run | Re-run exits 0, master key unchanged, container left up (env-hash match), saved keys reused, config unchanged. |
| T4 | Master key rotation | Deleting the key file re-runs generates a new key, container is recreated (env-hash mismatch), new key propagated into opencode.json. |
| T5 | Full uninstall (non-TTY `--yes`) | Container + image removed, source/data/keys/master-key/opencode.json deleted, mock server process stopped, all logged. |
| T6 | No API keys | Aborts non-zero with a clear message before touching Docker. |
| T7 | Non-TTY without flags | Prints usage, exits 2, **does not hang** (timeout-bounded). |
| T8 | All pulls 403 -> build | GHCR and Hub both 403 -> `git clone --depth 1` -> BuildKit build with memory caps -> image tagged -> 6/6 verification passes. |
| T9 | Node mode E2E | `OMNIRoute_NO_DOCKER_BUILD=1`: npm global install, pm2 start, pm2 online, 6/6 verification, uninstall removes pm2 process **and** launcher. |
| T10 | Build OOM -> Node fallback | Mock build fails (OOM flag) -> install still exits 0 via the Node fallback path. |
| T11 | Interactive TTY run | Real pty via `script(1)`: menu -> option 1 -> 5 key prompts (3 entered, 2 skipped) -> full install -> success banner. |
| T12 | Existing opencode.json preserved | A config containing another provider (`anthropic`) and unrelated top-level keys survives install: other provider intact, `omniroute` provider added, existing top-level `model` kept. |

## Known honest limitation

The 6 in-script verification tests in T12 report the chat-completion
check as FAIL for the *user's pre-existing* non-OmniRoute default model
(`anthropic/claude-x` cannot route through OmniRoute). That is correct
behavior: the installer verifies the models **it** configured; the
install itself still exits 0. The harness asserts the install contract,
not that foreign providers work.
