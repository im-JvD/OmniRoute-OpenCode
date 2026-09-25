<div align="tight" dir="rtl">

# OmniRoute-OpenCode

یک اسکریپت مدیریتی Bash در سطح تولید و **idempotent** که
[OmniRoute](https://github.com/diegosouzapw/OmniRoute) را به‌صورت
کان‌تینر Docker (با فول‌بک به Node در صورت ناکامی) روی
**WSL2 (Ubuntu 22.04+)** در Windows 10/11 نصب و حذف می‌کند و آن را
به **OpenCode** در سمت ویندوز متصل می‌سازد - متناسب با کاربران
**ایران** که در آنجا Docker Hub و `get.docker.com` مسدود است.

## فایل تکی

```bash
bash OmniRoute.sh            # منوی تعاملی (TTY)
bash OmniRoute.sh --install  # اجرای بدون نظارت (کلیدها از طریق متغیرهای محیطی)
bash OmniRoute.sh --uninstall
```

* منو دقیقاً دو گزینه دارد: **1) Full Install** و **2) Full Uninstall**.
* `set -euo pipefail` + trap برای پاکسازی؛ تمام مراحل با timestamp در
  `~/omniroute-install.log` ثبت می‌شوند.
* ایمن در ترمینال‌های غیر TTY (`read` محدود با timeout، فول‌بک به
  متغیر محیطی یا مقدار پیش‌فرض، هیچ‌گاه hang نمی‌شود).
* خروجی اسکریپت کاملاً انگلیسی و ASCII-only است (نیاز ثابت ترمینال).

## اجرای مستقیم از GitHub (بدون دانلود دستی)

```bash
# یک دستور، منوی تعاملی - پرامپت‌ها را از ترمینال می‌خواند:
curl -fsSL https://raw.githubusercontent.com/im-JvD/OmniRoute-OpenCode/main/OmniRoute.sh | bash

# روش امن‌تر: اول دانلود، بعد اجرا:
curl -fsSL https://raw.githubusercontent.com/im-JvD/OmniRoute-OpenCode/main/OmniRoute.sh -o OmniRoute.sh && bash OmniRoute.sh

# بدون نظارت (کلیدها از متغیرهای محیطی):
OMNIRoute_GEMINI_KEY=AIza... bash <(curl -fsSL https://raw.githubusercontent.com/im-JvD/OmniRoute-OpenCode/main/OmniRoute.sh) --install
```

> نکته: در حالت `curl ... | bash`، ورودی stdin جریان بایت‌های خودِ
> اسکریپت است؛ اسکریپت پرامپت‌های تعاملی را از ترمینال کنترل‌کننده
> (`/dev/tty`) می‌خواند، نه از stdin، بنابراین منو و پرامپت‌های کلید
> در ترمینال شما ظاهر می‌شوند.

اگر `raw.githubusercontent.com` در شبکه شما مسدود باشد (اما خود GitHub
باز):

```bash
git clone --depth 1 https://github.com/im-JvD/OmniRoute-OpenCode && bash OmniRoute.sh-OpenCode/OmniRoute.sh
```

## «Full Install» چه کارهایی انجام می‌دهد

1. **۵ کلید API اختیاری** (Groq، OpenRouter، Google AI، Cerebras،
   Mistral) - با ENTER یک provider رد می‌شود؛ **حداقل یکی** الزامی است،
   در غیر این صورت نصب با پیام روشن لغو (abort) می‌شود. کلیدها در
   `~/omniroute-keys.env` (حالت 600) ذخیره می‌شوند تا اجراهای تکراری
   بدون نظارت باشد.
2. **Docker** با `apt-get install docker.io` نصب می‌شود (هرگز از
   `get.docker.com` استفاده نمی‌شود). فایل
   `/etc/docker/daemon.json` با آینه‌های ایرانی
   (`docker.arvancloud.ir`، `docker.hub.iran.liara.run`،
   `docker.iranserver.com`) + قابلیت BuildKit نوشته می‌شود؛ daemon با
   `service` یا `systemctl` (هرکدام که در محیط کار کند) ریستارت و
   اجرای آن راستی‌آزمایی می‌شود.
3. **دریافت image** به این ترتیب: اول image ازساخته
   `ghcr.io/diegosouzapw/omniroute`، سپس
   `diegosouzapw/omniroute` از Docker Hub؛ اگر هر دو شکست بخورند
   (مثلاً تحریم/403) با `git clone --depth 1` سورس کپی می‌گیرد و
   محلی با BuildKit و سقف حافظه‌ای متناسب با هاست 8 GB / 4 هسته build
   می‌کند. هر pull یک **probe سریعِ درستی شبکه** (کمتر از 10 ثانیه
   برای GHCR، چون آینه‌های daemon فقط Docker Hub را پوشش می‌دهند)،
   **timeout سخت** (پیش‌فرض 15 دقیقه، با `OMNIRoute_PULL_TIMEOUT`
   قابل تغییر) و **heartbeat** هر 30 ثانیه («still in progress
   (Ns)») دارد تا هیچ‌وقت مثل یک هنگ به نظر نرسد. اگر build به OOM
   برخورد کند، فول‌بک به **حالت Node** (`npm i -g omniroute` + اجرای
   `omniroute serve` زیر pm2) انجام می‌شود.
4. فایل `~/omniroute-data/.env` (حالت 600) با کلیدهای providerها و
   یک **کلید اصلی** تصادفی
   `OMNIROUTE_API_KEY=sk-omni-<16 hex>` تولید می‌شود.
5. کان‌تینر `omniroute-app` روی `127.0.0.1:20128` با سیاست
   `--restart unless-stopped` اجرا می‌شود، سپس کلیدهای providerها
   به‌صورت headless در داشبورد ثبت می‌شوند (ورود +
   `POST /api/providers/bulk`).
6. **مسیر ویندوز** با PowerShell پیدا می‌شود (درگیر فاصله در نام
   کاربر نمی‌شود)؛ پیکربندی OpenCode در
   `C:\Users\<you>\.config\opencode\opencode.json` با schema تاییدشده
   از upstream نوشته می‌شود (provider `omniroute`،
   `npm: @ai-sdk/openai-compatible`،
   `baseURL http://127.0.0.1:20128/v1` و `limit.context` /
   `limit.output` برای هر مدل). فهرست مدل‌ها به‌صورت زنده از
   `/v1/models` خوانده می‌شود (فهرست ۷ مدل رایگان فقط فول‌بک است).
7. **۶ تست خودکار پس‌نصب** (docker info، بالا بودن کان‌تینر،
   `/healthz` با ۱۰ بار تلاش و ۳ ثانیه، `/v1/models` با Bearer، یک
   chat completion واقعی، JSON سالم بودن opencode.json) - هرکدام
   PASS/FAIL.
8. **آغازکار خودکار با بوت**: در حالت Docker، سرویس docker با
   `systemctl enable` فعال می‌شود (کان‌تینر با سیاست
   `--restart unless-stopped` با بوت WSL بالا می‌آید)؛ در حالت Node،
   یونیت systemd کاربر `omniroute` با `Restart=always` ساخته و
   enable می‌شود (+ `loginctl enable-linger`).
9. **دستور مدیریت سریع `omni`** در `/usr/local/bin/omni` (یا
   `~/.local/bin/omni`) ساخته می‌شود: `omni up | down | restart |
   status | logs | uninstall`.
10. بنر موفقیت پایانی: URL، **کلید اصلی (API Key) و پسورد پنل
   داشبورد**، مسیر پیکربندی، مسیر لاگ، تعداد مدل‌ها، وضعیت
   providerها، گام‌های بعدی و دستورات مفید.

## دستورات مدیریت سریع (omni)

بعد از نصب، یک دستور `omni` در PATH ساخته می‌شود:

```bash
omni status     # وضعیت کان‌تینر/پروسه + سلامت (healthz)
omni up         # شروع سرویس
omni down       # توقف سرویس (image/پیکربندی دست‌نخورده)
omni restart    # ریستارت سرویس
omni logs       # ۵۰ خط آخر لاگ (omni logs f = پیگیری زنده)
omni install    # اجرای دوباره‌ی نصب (idempotent)
omni uninstall  # حذف کامل
```

همان عملیات‌ها را می‌شود مستقیم با خود اسکریپت هم زد:
`bash OmniRoute.sh --up | --down | --restart | --status | --logs [N|f]`

## «Full Uninstall» چه کارهایی انجام می‌دهد

کان‌تینر و image را متوقف و حذف می‌کند، دایرکتوری `~/omniroute`،
دایرکتوری دیتا، فایل‌های کلیدها و لانسر حالت Node را پاک می‌کند،
یونیت systemd و دستور `omni` را هم حذف می‌کند و (با تأیید کاربر)
پیکربندی OpenCode و خود Docker را هم حذف می‌کند.
همه‌چیز در لاگ ثبت می‌شود.

## idempotent بودن

اجرای تکراری install، کلیدهای ذخیره‌شده، کلید اصلی و کان‌تینر در
حال کار (با برچسب env-hash مقایسه می‌شود) را باز استفاده می‌کند؛
کان‌تینر فقط در صورتی که ورودی‌ها (کلیدها، کلید اصلی) واقعاً تغییر
کرده باشد بازآفرینی می‌شود.

## تنظیمات پیشرفته (متغیرهای محیطی)

overrideهای `OMNIRoute_*` برای تست و کاربردهای پیشرفته:
`_GROQ_KEY`، `_OPENROUTER_KEY`، `_GEMINI_KEY`، `_CEREBRAS_KEY`،
`_MISTRAL_KEY`، `_NO_DOCKER_BUILD`، `_NPM_REGISTRY`، `_IMAGE`،
`_IMAGE_TAG`، `_IMAGE_GHCR`، `_IMAGE_HUB`، `_PORT`، `_BIND_HOST`،
`_DAEMON_JSON`، `_MNT_ROOT`، `_SRC_DIR`، `_DATA_DIR`، `_LOG`،
`_MASTER_KEY_FILE`، `_KEYS_FILE`، `_OPENCODE_DIR`، `_CONTAINER`،
`_ASSUME_DEPS`، `_SKIP_SWAP`.

## تست‌ها

دایرکتوری `tests/` اسکریپت واقعی را در برابر یک محیط
شبیه‌سازی‌شده ایران/WSL2 اجرا می‌کند (daemon Docker با 403 تحریمی،
مسیر PowerShell/WSL شبیه‌سازی‌شده و یک mock server با Node واقعی روی
پورت 20128).

```bash
bash tests/run-tests.sh        # T1 تا T14 - در حال حاضر 106/106 سبز
```

جدول «واقعی در برابر شبیه‌سازی» را در
[`docs/TEST-SUMMARY.md`](docs/TEST-SUMMARY.md) و گزارش خطاها/رفع‌ها
و بودجه RAM/CPU را در
[`docs/DEBUG-REPORT.md`](docs/DEBUG-REPORT.md) ببینید.

</div>
