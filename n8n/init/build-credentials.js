// Builds the n8n credentials file from environment variables and the
// service-account keys in /secrets. Nothing secret is ever committed:
// .env and secrets/*.json are git-ignored.
//
// A credential is only created when its input exists, so the stack boots
// with whatever you have configured so far.
const fs = require('fs');

const out = process.argv[2];
const credentials = [];
const missing = [];

function apiKey(id, name, type, field, value) {
  if (value) credentials.push({ id, name, type, data: { [field]: value } });
  else missing.push(name);
}

function serviceAccount(id, name, file) {
  const path = `/secrets/${file}`;
  if (!fs.existsSync(path)) {
    missing.push(`${name} (secrets/${file})`);
    return;
  }
  const key = JSON.parse(fs.readFileSync(path, 'utf8'));
  credentials.push({
    id,
    name,
    type: 'googleApi',
    data: {
      email: key.client_email,
      privateKey: key.private_key,
      region: 'global',
      inpersonate: false,
      delegatedEmail: '',
      httpNode: false,
      scopes: '',
    },
  });
}

// Operational database (always present: the password is required in .env).
credentials.push({
  id: 'pgStrideSoul0001',
  name: 'Postgres - stride_soul',
  type: 'postgres',
  data: {
    host: 'postgres', port: 5432, database: 'stride_soul',
    user: 'sole_app', password: process.env.SOLE_APP_PASSWORD,
    ssl: 'disable', allowUnauthorizedCerts: false,
  },
});

apiKey('deepSeekMain0001', 'DeepSeek', 'deepSeekApi', 'apiKey', process.env.DEEPSEEK_API_KEY);
apiKey('groqFallback0001', 'Groq (fallback)', 'groqApi', 'apiKey', process.env.GROQ_API_KEY);
apiKey('telegramSole0001', 'Telegram - Sole bot', 'telegramApi', 'accessToken', process.env.TELEGRAM_BOT_TOKEN);
serviceAccount('bigQuery00000001', 'BigQuery - n8n-bigquery', 'bq-service-account.json');

fs.writeFileSync(out, JSON.stringify(credentials));
console.log(`Credentials ready: ${credentials.map(c => c.name).join(', ') || 'none'}`);
if (missing.length) console.log(`Not configured yet (skipped): ${missing.join(', ')}`);
