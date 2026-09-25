# Test harness for `omniroute-manager.sh`

Runs the **real** script against a simulated WSL2/Iran environment
(mock docker/daemon, sanctions 403s, mock PowerShell/WSL path, mock
npm/pm2) plus a real Node OmniRoute mock server on port 20128.

```bash
bash run-tests.sh              # all 12 tests (T1-T12)
bash run-tests.sh T2 T8 T11    # a subset
```

Exit code 0 = all assertions passed; 1 = at least one failure (the
failing descriptions are printed at the end).

Requirements: `bash`, `jq`, `node` (>= 18), `curl`, `git`,
`util-linux` (`script(1)` for the TTY test). No root, no Docker, no
Windows needed.

## Layout

| Path | Purpose |
|---|---|
| `run-tests.sh` | 12 test groups (T1-T12), assertion helpers, per-test state reset. |
| `mock-bin/docker` | Mock Docker CLI + "daemon". State in `$MOCK_STATE`. Simulates 403 for `docker.io/*` / `diegosouzapw/*` pulls, starts the mock server on `run`, simulates build success or OOM (`force_build_oom` flag). |
| `mock-bin/service`, `mock-bin/powershell.exe`, `mock-bin/wslpath` | Mock privileged/Windows-side commands (daemon start/stop, `C:\Users\Sepehr system`, `/mnt/c`). |
| `mock-bin/curl` | Forwards to real curl but records every URL to `curl-urls.log` (proves `get.docker.com` is never called). |
| `mock-bin-node/npm`, `mock-bin-node/pm2` | Node-mode mocks (global install, pm2 start/jlist/delete). |
| `mock-bin-build/git` | Shallow "clone" from the local `MOCK_CLONE_SRC` checkout. |
| `mock-omniroute/server.mjs`, `catalog.json` | Real HTTP server speaking the OmniRoute v3.8.51 contract (`/healthz`, `/v1/models`, `/v1/chat/completions`, dashboard login + `/api/providers/bulk`). |

## Environment knobs used by the harness

All are test overrides of the script's own `OMNIRoute_*` knobs - they
also document the script's configurability:

`OMNIRoute_MNT_ROOT`, `OMNIRoute_DAEMON_JSON`, `OMNIRoute_LOG`,
`OMNIRoute_SRC_DIR`, `OMNIRoute_DATA_DIR`, `OMNIRoute_MASTER_KEY_FILE`,
`OMNIRoute_KEYS_FILE`, `OMNIRoute_SKIP_SWAP`,
`OMNIRoute_IMAGE_GHCR` / `OMNIRoute_IMAGE_HUB` (pointed at `docker.io/*`
refs in T8 to force 403 on *every* pull), `OMNIRoute_NO_DOCKER_BUILD`,
`OMNIRoute_GROQ_KEY` / `_OPENROUTER_KEY` / `_GEMINI_KEY` /
`_CEREBRAS_KEY` / `_MISTRAL_KEY`.

Each test starts from a wiped `TESTROOT` (`/tmp/omniroute-mgr-tests`)
with a fake `HOME`, a fake `/mnt/c/Users/Sepehr system` (note the
space), and a fresh mock state directory.
