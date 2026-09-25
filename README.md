# OmniRoute-OpenCode

A production-grade, **idempotent** Bash manager that installs and
uninstalls [OmniRoute](https://github.com/diegosouzapw/OmniRoute) as a
Docker container (or Node fallback) on **WSL2 (Ubuntu 22.04+)** on
Windows 10/11, and wires it into **OpenCode** on the Windows side -
designed for users in **Iran** where Docker Hub and `get.docker.com`
are blocked.

## The one file

```bash
bash omniroute-manager.sh            # interactive menu (TTY)
bash omniroute-manager.sh --install  # unattended (needs env-var keys)
bash omniroute-manager.sh --uninstall
```

* Menu has exactly two options: **1) Full Install**, **2) Full Uninstall**.
* `set -euo pipefail` + trap cleanup; every step logged with timestamps
  to `~/omniroute-install.log`.
* Safe in non-TTY terminals (bounded `read`, env-var or default
  fallbacks, never hangs).
* All output is English, ASCII-only.

## What Full Install does

1. **5 optional API keys** (Groq, OpenRouter, Google AI, Cerebras,
   Mistral) - ENTER skips a provider; **at least one** is required or
   the install aborts with a clear message. Saved to
   `~/omniroute-keys.env` (mode 600) so re-runs are unattended.
2. **Docker** via `apt-get install docker.io` (never
   `get.docker.com`). Writes `/etc/docker/daemon.json` with Iranian
   registry mirrors (`docker.arvancloud.ir`, `docker.hub.iran.liara.run`,
   `docker.iranserver.com`) + the BuildKit feature; restarts the daemon
   with `service` or `systemctl` whichever the host supports; verifies
   it is running.
3. **Image acquisition** in order: pre-built
   `ghcr.io/diegosouzapw/omniroute` first, then Docker Hub
   `diegosouzapw/omniroute`; if both fail (e.g. sanctions) it
   `git clone --depth 1` and builds locally with BuildKit and memory
   caps tuned for 8 GB / 4-core hosts. If the build OOMs it falls back
   to **Node mode** (`npm i -g omniroute`, served under pm2).
4. Generates `~/omniroute-data/.env` (mode 600) with the provider keys
   plus a random **master key** `OMNIROUTE_API_KEY=sk-omni-<16 hex>`.
5. Runs the container `omniroute-app` on `127.0.0.1:20128` with
   `--restart unless-stopped`, then registers the provider keys with
   the dashboard headlessly (login + `POST /api/providers/bulk`).
6. **Windows path** via PowerShell (spaces in usernames handled);
   writes OpenCode config to
   `C:\Users\<you>\.config\opencode\opencode.json` using the
   upstream-verified schema (provider `omniroute`,
   `npm: @ai-sdk/openai-compatible`, `baseURL http://127.0.0.1:20128/v1`,
   per-model `limit.context` / `limit.output`). The model list is read
   live from `/v1/models` (7 free models as fallback only).
7. **6 automated post-install checks** (docker info, container up,
   `/healthz` 10x3s, `/v1/models` with Bearer, a real chat completion,
   opencode.json valid JSON) - PASS/FAIL each.
8. Final success banner: URL, master key, config path, log path, model
   count, provider status line, next steps, useful commands.

## What Full Uninstall does

Stops/removes the container and image, deletes `~/omniroute`, the data
dir, key stores, the Node-mode launcher, and (with confirmation)
OpenCode config and Docker itself. Everything is logged.

## Idempotency

Re-running install reuses saved keys, the master key, and the running
container (matched by an env-hash label); it only recreates the
container when inputs (keys, master key) actually change.

## Config knobs (env)

`OMNIRoute_*` overrides for testing/advanced use: `_GROQ_KEY`,
`_OPENROUTER_KEY`, `_GEMINI_KEY`, `_CEREBRAS_KEY`, `_MISTRAL_KEY`,
`_NO_DOCKER_BUILD`, `_NPM_REGISTRY`, `_IMAGE`, `_IMAGE_TAG`,
`_IMAGE_GHCR`, `_IMAGE_HUB`, `_PORT`, `_BIND_HOST`, `_DAEMON_JSON`,
`_MNT_ROOT`, `_SRC_DIR`, `_DATA_DIR`, `_LOG`, `_MASTER_KEY_FILE`,
`_KEYS_FILE`, `_OPENCODE_DIR`, `_CONTAINER`, `_ASSUME_DEPS`,
`_SKIP_SWAP`.

## Tests

`tests/` runs the real script against a simulated Iran/WSL2
environment (mock Docker daemon with 403 sanctions, mock
PowerShell/WSL path, a real Node mock server on port 20128).

```bash
bash tests/run-tests.sh        # T1-T12, currently 77/77 passing
```

See [`docs/TEST-SUMMARY.md`](docs/TEST-SUMMARY.md) for what is real vs
simulated, and [`docs/DEBUG-REPORT.md`](docs/DEBUG-REPORT.md) for the
errors/fixes log and the RAM/CPU budget.
