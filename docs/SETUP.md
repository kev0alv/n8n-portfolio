# Setup guide (Windows)

Everything runs under **kev.alvareze@gmail.com** and costs **USD 0**.
Keys and tokens go only in `.env` and `secrets/` on your machine: never in a
chat, a screenshot or a commit.

| # | Step | Status |
|---|---|---|
| 1 | Install WSL2, Docker Desktop and Git | ☐ |
| 2 | Clone the repo and create `.env` | ☐ |
| 3 | Google Cloud project `stride-soul`, **no billing** (BigQuery sandbox) | ✅ |
| 4 | Service account `n8n-bigquery` | ✅ created · ☐ roles checked · ☐ key |
| 5 | Create the BigQuery dataset (run `bigquery/01`–`02`) | ☐ |
| 6 | DeepSeek and Groq API keys | ☐ |
| 7 | Telegram bot **Sole** and your on-call chat id | ☐ |
| 8 | ngrok: free static domain so Telegram can reach n8n | ☐ |
| 9 | Start the stack and run the database tests | ☐ |
| 10 | Optional: free n8n Community license | ☐ |

---

## 1. Install (once)

1. PowerShell **as administrator**: `wsl --install`, then restart.
2. Docker Desktop from docker.com. During setup keep **Use WSL 2** checked.
3. Git for Windows from git-scm.com.
4. Limit Docker's memory: create `C:\Users\<you>\.wslconfig` with
   ```ini
   [wsl2]
   memory=8GB
   ```
   then run `wsl --shutdown` and reopen Docker Desktop.

## 2. Clone and configure

```powershell
git clone https://github.com/kev0alv/n8n-portfolio.git
cd n8n-portfolio
copy .env.example .env
notepad .env
```

Fill every empty value as you complete the steps below. For passwords,
`N8N_ENCRYPTION_KEY` and `USER_HASH_SALT`, generate random strings in
PowerShell:

```powershell
-join ((48..57)+(97..102) | Get-Random -Count 64 | % {[char]$_})
```

## 3. Google Cloud project ✅

Project ID **`stride-soul`**, no billing account. BigQuery shows the
**Sandbox** badge. Do not click **Upgrade**: that is the paid path.

`.env`: `GCP_PROJECT_ID=stride-soul`

## 4. Service account `n8n-bigquery`

Created ✅. Check its roles and download the key:

1. **IAM & Admin → IAM** (console.cloud.google.com/iam-admin/iam?project=stride-soul).
   The row for `n8n-bigquery@stride-soul.iam.gserviceaccount.com` must show
   **BigQuery Data Editor** and **BigQuery Job User**. If not, edit the row
   (pencil icon) and add them.
2. **IAM & Admin → Service Accounts** → `n8n-bigquery` → **Keys → Add key →
   Create new key → JSON**.
3. Move the downloaded file into the repo's `secrets/` folder and rename it
   **`bq-service-account.json`**. Delete any other copy (Downloads).

## 5. Create the dataset

Open **BigQuery Studio** (console.cloud.google.com/bigquery?project=stride-soul),
then paste and run each file in order. Both are safe to re-run.

| File | What it does |
|---|---|
| `bigquery/01_dataset_and_tables.sql` | Dataset `stride_soul` (US) and the tables the nightly load fills |
| `bigquery/02_views.sql` | Analytics views for Looker Studio and the analyst agent |

The sandbox deletes tables after 60 days. That is expected: the nightly n8n
load recreates them from Postgres.

## 6. LLM keys

| Provider | Where | `.env` variable |
|---|---|---|
| DeepSeek | platform.deepseek.com → API keys → create one only for this project | `DEEPSEEK_API_KEY` |
| Groq | console.groq.com with your personal account → API Keys | `GROQ_API_KEY` |

## 7. Telegram

1. In Telegram, open **@BotFather** → `/newbot` → name `Sole · Stride & Soul`
   → a username ending in `bot`. Copy the token into `TELEGRAM_BOT_TOKEN`.
2. Your numeric chat id for error alerts: send any message to
   **@userinfobot** and copy the `Id` into `TELEGRAM_ONCALL_CHAT_ID`.

## 8. ngrok (public HTTPS for Telegram)

Telegram only delivers messages to public **HTTPS** addresses; n8n on your
laptop is `http://localhost`. ngrok gives it a fixed public address for free.

1. Sign up at ngrok.com with kev.alvareze@gmail.com.
2. **Your Authtoken** → copy into `NGROK_AUTHTOKEN`.
3. **Domains** → claim your free static domain (looks like
   `something-random.ngrok-free.app`).
4. In `.env`:
   ```ini
   NGROK_DOMAIN=something-random.ngrok-free.app
   N8N_WEBHOOK_URL=https://something-random.ngrok-free.app/
   COMPOSE_PROFILES=tunnel
   ```

## 9. Start and test

```powershell
docker compose up -d
docker compose ps
```

Every service should be `running` or `healthy`, except `n8n-import` and
`n8n-setup`, which run once and show `exited (0)`.

Run the database tests (a throwaway copy; your data is not touched):

```powershell
docker compose exec postgres sh /tests/run.sh
```

Expected end of the output: `ALL 13 TESTS PASSED` and two concurrency
lines ending in `PASS`. Share a screenshot.

Open http://localhost:5678 and log in with `N8N_OWNER_EMAIL` /
`N8N_OWNER_PASSWORD`. To see which credentials were created and which are
still missing:

```powershell
docker compose logs n8n-import
```

Stop with `docker compose down` (data is kept). `docker compose down -v`
deletes all data, including the store database.

## 10. Optional: n8n Community license

In n8n: **Settings → Usage and plan → Unlock selected paid features for
free**, with kev.alvareze@gmail.com. Paste the key you receive by e-mail.
