<div align="tight" dir="rtl">

# هارنس تست برای اسکریپت `OmniRoute`

اسکریپت **واقعی** را در برابر یک محیط شبیه‌سازی‌شده WSL2/ایران
اجرا می‌کند: CLI و daemon docker با 403 تحریمی شبیه‌سازی می‌شوند،
مسیر PowerShell/WSL و npm/pm2 هم mock هستند + یک mock server از
OmniRoute با Node واقعی روی پورت 20128.

```bash
bash run-tests.sh              # هر ۱۳ تست (T1 تا T13)
bash run-tests.sh T2 T8 T11    # یک زیرمجموعه
```

خروجی 0 = همه‌ی assertionها سبز؛ 1 = حداقل یک شکست (شرح شکست‌ها در
پایان چاپ می‌شود).

نیازها: `bash`، `jq`، `node` (18 به بالا)، `curl`، `git` و
`util-linux` (دستور `script(1)` برای تست‌های TTY و اجرای piped). به root، Docker یا
ویندوز نیاز نیست.

## چیدمان

| مسیر | کاربرد |
|---|---|
| `run-tests.sh` | ۱۳ گروه تست (T1 تا T13)، helperهای assertion و پاکسازی state قبل از هر تست. |
| `mock-bin/docker` | mock از CLI و daemon Docker. state در `$MOCK_STATE`. 403 را برای pullهای `docker.io/*` و `diegosouzapw/*` شبیه‌سازی می‌کند، در `run` سرور mock را روی 20128 بالا می‌آورد و build را با موفقیت یا OOM (در صورت flag `force_build_oom`) شبیه‌سازی می‌کند. |
| `mock-bin/service`، `mock-bin/powershell.exe`، `mock-bin/wslpath` | mock دستورات privileged / سمت ویندوز (start/stop daemon، `C:\Users\Sepehr system`، `/mnt/c`). |
| `mock-bin/curl` | به curl واقعی forward می‌شود ولی هر URL را در `curl-urls.log` ثبت می‌کند (ثابت می‌کند `get.docker.com` هرگز خوانده نمی‌شود). |
| `mock-bin-node/npm`، `mock-bin-node/pm2` | mockهای حالت Node (نصب global، pm2 start/jlist/delete). |
| `mock-bin-build/git` | «clone» shallow از یک checkout محلی `MOCK_CLONE_SRC`. |
| `mock-omniroute/server.mjs`، `catalog.json` | سرور HTTP واقعی که قرارداد OmniRoute نسخه 3.8.51 را حرف می‌زند (`/healthz`، `/v1/models`، `/v1/chat/completions`، ورود داشبورد + `/api/providers/bulk`). |

## متغیرهای محیطی که هارنس از آن‌ها استفاده می‌کند

همه‌ی آن‌ها overrideهای تستیِ خودِ کلیدهای `OMNIRoute_*` اسکریپت
هستند - و در عین حال قابلیت پیکربندی اسکریپت را هم مستند می‌کنند:

`OMNIRoute_MNT_ROOT`، `OMNIRoute_DAEMON_JSON`، `OMNIRoute_LOG`،
`OMNIRoute_SRC_DIR`، `OMNIRoute_DATA_DIR`،
`OMNIRoute_MASTER_KEY_FILE`، `OMNIRoute_KEYS_FILE`،
`OMNIRoute_SKIP_SWAP`، `OMNIRoute_IMAGE_GHCR` /
`OMNIRoute_IMAGE_HUB` (در T8 به refهای `docker.io/*` نشانه رفته‌اند تا
**همه** pullها 403 بزنند)، `OMNIRoute_NO_DOCKER_BUILD`،
`OMNIRoute_GROQ_KEY` / `_OPENROUTER_KEY` / `_GEMINI_KEY` /
`_CEREBRAS_KEY` / `_MISTRAL_KEY`.

هر تست از یک `TESTROOT` پاک‌شده شروع می‌شود
(`/tmp/omniroute-mgr-tests`) با یک `HOME` فیک، یک
`/mnt/c/Users/Sepehr system` فیک (دقت کنید: دارای فاصله) و یک
دایرکتوری state mock تازه.

</div>
