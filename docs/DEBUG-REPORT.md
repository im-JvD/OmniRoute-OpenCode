# Debug Report

Working log of the failures that actually occurred while bringing
`omniroute-manager.sh` + the sandbox test harness to green, each with
the root cause and the fix. Also includes the RAM/CPU budget used for
the 8 GB / 4-core WSL2 target.

## Real vs. simulated (short version)

The manager script, the mock OmniRoute HTTP server (real `node` on the
real port 20128), `jq`, `git`, `openssl`, and `bash` are **real**.
`docker`, the Docker daemon, `apt-get`/`service`/`systemctl`,
`powershell.exe`, `wslpath`, `npm`, and `pm2` are **mocks** under
`tests/mock-bin*` because the sandbox is non-root Linux with none of
those. Registry sanctions (403 from Docker Hub / `get.docker.com`) are
simulated inside the mock `docker`. Full table in `TEST-SUMMARY.md`.

## Errors -> fixes

1. **`curl get.docker.com` returned 403 from Iran.**
   Fix: never call it. Docker is installed via `apt-get install
   docker.io` (Debian/Ubuntu ships the engine in the distro repo, which
   is reachable). Assertions in T2 prove the URL is never contacted.

2. **`set -euo pipefail` + `ERR` trap killed the script on any expected
   failure** (e.g. `systemctl restart docker` -> "Unit not found" in a
   systemd-less context). A plain failing statement aborts the whole
   script.
   Fix: every fallible command is wrapped - `if cmd; then ... fi`,
   `cmd || fallback`, or a bounded `set +e ... set -e` block. The
   systemd/service decision is made once at start (`systemd_active()`).

3. **Sudo quirk in this sandbox:** sudo escalates to uid 0, but root
   could not write user-owned files (`tee` -> Permission denied).
   Fix: files are written as the user, then `sudo mv`/`sudo install`
   into privileged locations. The script's privilege helper is only
   used for genuinely root paths (daemon.json, swap, apt).

4. **Bash return-code bug:** `if cmd; then ...; fi; rc=$?` captures the
   status of the `if` compound (0 on the false branch), *not* the
   command's rc. This silently turned a mock 403 into "success".
   Fix: capture with `cmd || rc=$?` (reproduced in isolation to confirm).

5. **`run_quiet` swallowed stdout in pipes.** `run_quiet` redirects
   stdout to the log file, so `run_quiet DC ps | grep` and
   `$(run_quiet ...)` captured nothing, which made the "container up"
   and image checks fail.
   Fix: use `DC ... 2>/dev/null` directly wherever output is piped or
   substituted; keep `run_quiet` only for fire-and-forget steps.

6. **Docker image marker mismatch.** The mock keys images by
   `img-$(echo "$ref" | tr '/:' '__')`. The tag `omniroute-image:latest`
   has no slash, so it maps to a **single** underscore
   (`img-omniroute-image_latest`); the test assertions were written
   with a double underscore and never matched.
   Fix: corrected the assertions to the single-underscore form (verified
   against direct `tr` output).

7. **`free_disk_mb` failed on a fresh clone target.** `df` on a
   directory that does not exist yet returns nothing -> "0 MB free" ->
   `die`.
   Fix: walk up to the nearest existing ancestor directory before `df`.

8. **Build command chosen after it was used** (ordering bug) and the
   BuildKit line was not logged.
   Fix: detect `buildx` first (`buildx build` vs classic `build` with
   `DOCKER_BUILDKIT=1`), then log the exact builder + resource caps.

9. **Build failure was a hard `die`**, so the required "build OOM ->
   Node fallback" path was unreachable.
   Fix: `build_image_docker` now `return 1` (with an OOM hint if the
   log shows one) and `acquire_runtime` falls back to Node mode. T10
   verifies the install still exits 0.

10. **`jq` pitfalls (twice):** (a) hyphenated keys like
    `registry-mirrors` need quoting; (b) after `| {...}` the input `.` is
    the *new* object, so earlier fields (`.id`) are lost - must bind
    `.id as $id` before transforming.
    Fix: quoted keys and value-binding in the daemon.json and model
    jq programs.

11. **`service <svc> <cmd>` argument order.** The first mock had the
    service name and the verb swapped and silently exit 0'd.
    Fix: mock takes `$1`=service, `$2`=command, mirroring the real CLI.

12. **Node-mode pm2 status showed "stopped".** The mock `pm2 jlist`
    derived the liveness path from the wrong pidfile basename (kept the
    `pm2-` prefix).
    Fix: strip the `pm2-` prefix; status is now `online`. T9 green.

13. **Uninstall left the Node launcher behind.** `do_uninstall` removed
    the pidfile but never `~/omniroute-run.sh`. (The earlier "pass" was
    the harness crashing *before* that assertion ran.)
    Fix: uninstall now removes the launcher and logs it.

14. **Harness `set -u` crashes from unbound positional params.**
    `assert_grep ... <<<"$out"` passed the here-string as a *redirection*
    (so `$3` was unset) and a description string contained a literal
    `$2`. Both aborted the run.
    Fix: pass output via `<(printf ...)` and fix the description to the
    real variable.

15. **Env-var leakage across tests in one harness run.** T9 exported
    `OMNIRoute_NO_DOCKER_BUILD=1` and key vars that leaked into T10/T11.
    Fix: `common_env()` unsets the per-test knobs (and provider keys)
    at the top of every test.

16. **Interactive `read` would hang a non-TTY session.**
    Fix: `prompt_line`/`prompt_yes_no` read from a bounded
    `read -t 180`, fall back to the env var, then to the default, and
    never block forever. T7 proves no hang (timeout-bounded) and T11
    proves the interactive path works under a real pty.

17. **Windows path with a space in the username** (`Sepehr system`)
    broke unquoted expansions and a naive `cmd.exe` path lookup.
    Fix: PowerShell `[Environment]::GetFolderPath('UserProfile')`
    (never `cmd.exe`), quoted everywhere, and `wslpath` for the
    `/mnt/c/...` conversion. T2/T11 exercise the spaced path.

## RAM / CPU budget (8 GB RAM, 4-core target)

The upstream OmniRoute Dockerfile (v3.8.51) exposes build args
`OMNIROUTE_BUILD_MEMORY_MB`, `OMNIROUTE_BUILD_WORKERS`, and
`OMNIROUTE_USE_TURBOPACK`. CI builds on 16 GB runners with a 12288 MB
heap; that is far too much once the Docker daemon and the host are
subtracted from an 8 GB box. The script therefore budgets:

| Host RAM | `--memory` | `--memory-swap` | build heap (`OMNIROUTE_BUILD_MEMORY_MB`) | workers (`OMNIROUTE_BUILD_WORKERS`) |
|---|---|---|---|---|
| >= 16 GB | 8g | 12g | 6144 | 4 |
| else (the 8 GB case) | **6g** | **8g** | **4096** | **2** |

- **6 g hard container cap** leaves ~2 GB for the host + Docker daemon
  on an 8 GB WSL2 box.
- **4096 MB JS heap** (via `OMNIROUTE_BUILD_MEMORY_MB`, which the
  Dockerfile forwards to `NODE_OPTIONS --max-old-space-size`) keeps the
  Next.js build inside the cap with headroom for native tools.
- **2 build workers** (the Dockerfile default) halve peak memory vs 4.
- **Webpack, not Turbopack** (`OMNIROUTE_USE_TURBOPACK=0`) - the
  Dockerfile default and the safer choice under memory pressure.
- A **swapfile is provisioned first** (WSL2 has none by default) when
  swap is 0 and RAM < 12 GB, as the last line of defense.
- If the build still OOMs, the script **falls back to Node mode**
  (`npm i -g omniroute` + `omniroute serve` under pm2/nohup) instead of
  failing the install (T10).
- The **runtime** container runs with the image's own
  `OMNIROUTE_MEMORY_MB=1024` (1 GB) - small on purpose; the heavy work
  is provider calls, not local compute.

CPU: the 4-core box gets `workers=2` during build (deliberate
under-subscription to keep the OOM budget honest); the runtime service
is CPU-unconstrained (I/O bound).

Disk: `build_image_docker` refuses to start unless ~12 GB is free
(`free_disk_mb` walks to an existing ancestor so a fresh clone target
is measured correctly).
