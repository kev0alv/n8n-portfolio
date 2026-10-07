# Setup guide (Windows)

Everything runs under **kev.alvareze@gmail.com**. Keys and tokens go only in
`.env` and `secrets/` on your machine: never in a chat, a screenshot or a commit.

| # | Step | Status |
|---|---|---|
| 1 | Install WSL2, Docker Desktop and Git | ☐ |
| 2 | Clone the repo and create `.env` | ☐ |
| 3 | Google Cloud project, billing with a USD 1 budget alert, BigQuery API | ☐ |
| 4 | Create the BigQuery dataset (run `bigquery/01`–`05`) | ☐ |
| 5 | Two service accounts and their keys | ☐ |
| 6 | DeepSeek and Groq API keys | ☐ |
| 7 | Telegram bot **Sole** and your on-call chat id | ☐ |
| 8 | Public HTTPS URL so Telegram can reach n8n (decision pending) | ☐ |
| 9 | Start the stack | ☐ |
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

Fill every empty value. For `N8N_ENCRYPTION_KEY` and `USER_HASH_SALT`,
generate random strings in PowerShell:

```powershell
-join ((48..57)+(97..102) | Get-Random -Count 64 | % {[char]$_})
```

## 3. Google Cloud project

1. Go to console.cloud.google.com, signed in as kev.alvareze@gmail.com.
2. **New project** → name `stride-soul` → copy the **Project ID** into
   `GCP_PROJECT_ID` in `.env`.
3. **Billing** → link a billing account. The free BigQuery sandbox does
   not allow `INSERT`/`UPDATE`, which the sales engine needs. Usage stays
   inside the free tier (1 TB of queries and 10 GB of storage per month).
4. **Billing → Budgets & alerts** → budget of **USD 1** with e-mail alerts
   at 50 %, 90 % and 100 %.
5. **APIs & Services → Library** → enable **BigQuery API**.

## 4. Create the dataset

Open **BigQuery Studio**, select the project, then paste and run each file
in order. Each one is safe to re-run.

| File | What it does |
|---|---|
| `bigquery/01_dataset_and_tables.sql` | Dataset `stride_soul` (US) and all tables |
| `bigquery/02_seed.sql` | Settings, 40 catalog variants, shipping and return policies |
| `bigquery/03_procedures.sql` | Sales engine: sale, refund, exchange, support case |
| `bigquery/04_views.sql` | Analytics views for Looker Studio and the analyst agent |
| `bigquery/05_tests.sql` | 10 isolated tests: every row must say **PASS** |

Share a screenshot of the `05_tests.sql` result before moving on.

## 5. Service accounts (least privilege)

**IAM & Admin → Service Accounts → Create service account**, twice:

| Name | Project role | Dataset `stride_soul` role | Key file |
|---|---|---|---|
| `n8n-writer` | BigQuery Job User | BigQuery Data Editor | `secrets/bq-writer.json` |
| `n8n-analyst` | BigQuery Job User | BigQuery Data Viewer | `secrets/bq-analyst.json` |

- Project role: set it while creating the account.
- Dataset role: in BigQuery Studio, open the dataset → **Share → Manage
  permissions → Add principal** → paste the account's e-mail.
- Key: open the account → **Keys → Add key → JSON**. Save the file into
  `secrets/` with the exact name above. Do not keep other copies.

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

## 8. Public HTTPS URL (decision pending)

Telegram delivers messages to the bot through a webhook, and it only calls
**HTTPS** addresses on the internet. n8n on your laptop is `http://localhost`,
so it needs a tunnel. Options being decided:

| Option | Cost | URL | Notes |
|---|---|---|---|
| ngrok, free static domain | Free | Fixed (`*.ngrok-free.app`) | One account, one fixed domain; nothing to change after restarts |
| Cloudflare quick tunnel | Free, no account | Changes on every restart | `N8N_WEBHOOK_URL` must be updated each time |
| Cloudflare named tunnel | Free + your own domain | Fixed | Needs a domain you own |

The chosen URL goes into `N8N_WEBHOOK_URL`.

## 9. Start

```powershell
docker compose up -d
docker compose ps
```

Open http://localhost:5678 and log in with `N8N_OWNER_EMAIL` /
`N8N_OWNER_PASSWORD`. The import step reports which credentials it created
and which are still missing:

```powershell
docker compose logs n8n-import
```

Stop with `docker compose down` (data is kept). `docker compose down -v`
deletes n8n's database too.

## 10. Optional: n8n Community license

In n8n: **Settings → Usage and plan → Unlock selected paid features for
free**, with kev.alvareze@gmail.com. Paste the key you receive by e-mail.
