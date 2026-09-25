<div align="tight" dir="rtl">

# خلاصه تست‌های ساندباکس

`omniroute-manager.sh` چگونه در این ساندباکس Linux راستی‌آزمایی شد:
Debian 12، کاربر غیر-root، **بدون** daemon Docker، **بدون** ویندوز،
**بدون** WSL. چون ساندباکس نمی‌تواند محیط واقعی را اجرا کند، هارنس تست
(`tests/run-tests.sh`) آن بخش‌هایی که به دسترسی root یا
سمت ویندوز نیاز دارند را شبیه‌سازی می‌کند و **اسکریپت واقعی را
بدون هیچ تغییری** در برابر آن‌ها اجرا می‌کند.

آخرین اجرای کامل: **۷۷ از ۷۷ assertion موفق، خروجی 0** (هر ۱۲
گروه تست T1 تا T12).

```bash
cd tests
bash run-tests.sh            # اجرای هر ۱۲ تست
bash run-tests.sh T2 T8      # اجرای یک زیرمجموعه
```

## چه چیزی واقعی است و چه چیزی شبیه‌سازی

| جزء | واقعی یا شبیه‌سازی | توضیح |
|---|---|---|
| خود `omniroute-manager.sh` | **واقعی** | بدون تغییر اجرا می‌شود؛ فقط محیط فیک است. |
| سرور HTTP OmniRoute | **مسیر واقعی کد** | `tests/mock-omniroute/server.mjs` یک سرور HTTP با Node است که قرارداد واقعی نسخه 3.8.51 را حرف می‌زند: `/healthz`، `/v1/models` (کاتالوگ ۱۲ مدل)، `/v1/chat/completions` (پاسخ echo با احراز هویت کلید اصلی)، ورود داشبورد + `POST /api/providers/bulk` برای ثبت provider. روی پورت واقعی 20128 گوش می‌دهد. |
| `curl` | **واقعی** | `tests/mock-bin/curl` فقط URLها را در `curl-urls.log` ثبت کرده و به curl واقعی forward می‌کند؛ assertionها با آن ثابت می‌کنند اسکریپت هرگز `get.docker.com` / `registry-1.docker.io` را نمی‌خواند. |
| `jq`، bash، git (clone در مسیر build)، openssl، node | **واقعی** | |
| CLI و daemon `docker` | **شبیه‌سازی** | `tests/mock-bin/docker`: state را در فایل‌های `$MOCK_STATE` نگه می‌دارد؛ تحریم registry را شبیه‌سازی می‌کند (pull از `docker.io/*` و `diegosouzapw/*` -> 403 Forbidden در لاگ)، `run` سرور mock را روی 20128 بالا می‌آورد، `build` موفقیت (یا OOM در صورت flag `force_build_oom`) را شبیه‌سازی می‌کند. |
| `apt-get install docker.io`، `service`/`systemctl` | **شبیه‌سازی** | `tests/mock-bin/service` state daemon را جابه‌جا می‌کند. ثابت می‌کند اسکریپت از `apt-get` استفاده می‌کند (هرگز `get.docker.com`) و فول‌بک به `service` دارد. |
| `powershell.exe`، `wslpath` | **شبیه‌سازی** | مقدار `C:\Users\Sepehr system` / درخت فیک `/mnt/c` برمی‌گردانند تا مسیر ویندوز (با فاصله در نام کاربر) تمرین شود. |
| `npm` / `pm2` | **شبیه‌سازی** | `tests/mock-bin-node/*` برای حالت Node بدون Docker: نصب global فیک، pm2 با pidfile و وضعیت `jlist`. |
| 403 registryها (تحریم) | **شبیه‌سازی** | docker mock برای هر reference از Docker Hub مقدار 403 برمی‌گرداند؛ T8 حتی override محیطی GHCR را هم به یک ref از `docker.io/*` می‌زند تا **تمام** pullها 403 بزنند و مسیر build مجبور به اجرا شود. |
| تشخیص WSL2 | چک واقعی، هاست Linux | اسکریپت هشدار می‌زند و ادامه می‌دهد (به‌صورت طراحی‌شده). |

## ۱۲ گروه تست

| # | تست | پوشش |
|---|---|---|
| T1 | Syntax | تمیز بودن `bash -n`؛ اسکریپت صرفاً ASCII است (نیاز سخت‌افزاری). |
| T2 | نصب کامل E2E | شبیه‌سازی تحریم (403 برای Hub)، image ازساخته از GHCR pull می‌شود، ۳ از ۵ کلید، `daemon.json` با ۳ آینه ایرانی + buildkit، کلید اصلی `sk-omni-...`، `opencode.json` در مسیر ویندوزِ دارای فاصله، ۱۲ مدل هرکدام با `limit.context`/`limit.output`، ثبت bulk برای ۳ provider، هر ۶ تست راستی‌آزماییِ داخل اسکریپت PASS، صفر تماس با `get.docker.com`/`registry-1.docker.io`. |
| T3 | اجرای تکراری idempotent | اجرا دوباره با خروجی 0 تمام می‌شود، کلید اصلی دست‌نخورده، کان‌تینر روشن می‌ماند (تطابق env-hash)، کلیدهای ذخیره‌شده باز استفاده می‌شوند، پیکربندی دست‌نخورده. |
| T4 | چرخش کلید اصلی | حذف فایل کلید، تولید کلید جدید، بازآفرینی کان‌تینر (تغییر env-hash)، انتقال کلید جدید به opencode.json. |
| T5 | uninstall کامل (non-TTY با `--yes`) | کان‌تینر + image حذف، سورس/دیتا/کلیدها/کلید اصلی/opencode.json پاک، پروسه سرور mock متوقف، همه‌چیز لاگ شده. |
| T6 | بدون کلید API | قبل از دست زدن به Docker با پیام روشن abort (خروجی غیرصفر). |
| T7 | non-TTY بدون flag | usage چاپ می‌شود، خروجی 2، **hang نمی‌شود** (با timeout محدودشده). |
| T8 | 403 برای همه pullها -> build | هر دو GHCR و Hub 403 -> `git clone --depth 1` -> build با BuildKit و سقف حافظه -> image تگ می‌شود -> 6/6 راستی‌آزمایی PASS. |
| T9 | حالت Node E2E (بدون Docker) | `OMNIRoute_NO_DOCKER_BUILD=1`: نصب global با npm، start با pm2، وضعیت online، 6/6 راستی‌آزمایی، uninstall پروسه pm2 **و** لانسر را حذف می‌کند. |
| T10 | OOM در build -> فول‌بک Node | build mock شکست می‌خورد (flag OOM) -> نصب باز هم با مسیر فول‌بک Node و خروجی 0 تمام می‌شود. |
| T11 | اجرای تعاملی TTY | pty واقعی با `script(1)`: منو -> گزینه ۱ -> ۵ پرامپت کلید (۳ تا پر می‌شود، ۲ تا رد) -> نصب کامل -> بنر موفقیت. |
| T12 | حفظ opencode.jsonِ موجود | پیکربندی‌ای که provider دیگر (`anthropic`) و کلیدهای سطح‌بالای نامرتبط دارد، پس از install سالم می‌ماند: provider دیگر دست‌نخورده، provider `omniroute` افزوده، `model`ِ سطح‌بالای موجود حفظ می‌شود. |

## محدودیت شناخته‌شده و صادقانه

در T12، تستِ chat-completionِ داخلِ ۶ راستی‌آزمایی برای مدل
پیش‌فرضِ **کاربر** که از OmniRoute نیست (`anthropic/claude-x` از
OmniRoute عبور نمی‌کند) FAIL گزارش می‌شود. این رفتار درست است:
نصب‌گر فقط مدل‌هایی که **خودش** پیکربندی کرده را راستی‌آزمایی می‌کند؛
خود install باز هم با خروجی 0 تمام می‌شود. هارنس بر قرارداد install
assertion دارد، نه بر اینکه providerهای بیگانه کار کنند.

</div>
