// One-shot, run by the n8n-setup service before n8n starts (see docker-compose.yml).
// - creates credentials that do not exist yet, from values in .env;
// - imports workflows from ./workflows that are not in n8n yet;
// - makes sure the workflows listed in PUBLISH are published (active), so they run right after start.
// Nothing that already exists is overwritten, so changes made in the n8n UI survive `docker compose up`.
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const env = process.env;
const log = (m) => console.log(`[n8n-setup] ${m}`);
const n8n = (...args) => execFileSync('n8n', args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });

// Credential IDs are fixed because the workflow JSON files reference them.
const CREDENTIALS = [
  {
    id: 'ZJgIPopJgGjKkCiD', name: 'Postgres account', type: 'postgres',
    when: env.APP_DB_PASSWORD,
    data: { host: 'postgres', database: 'app', user: 'app', password: env.APP_DB_PASSWORD, port: 5432, ssl: 'disable' },
  },
  {
    id: 'eC5Ih8jiRzcY1AP5', name: 'Anthropic account', type: 'anthropicApi',
    when: env.ANTHROPIC_API_KEY,
    data: { apiKey: env.ANTHROPIC_API_KEY },
  },
  {
    id: 'B7q0z4ZYxNQdMX09', name: 'Slack account', type: 'slackApi',
    when: env.SLACK_BOT_TOKEN,
    data: { accessToken: env.SLACK_BOT_TOKEN, signatureSecret: env.SLACK_SIGNING_SECRET || '' },
  },
];

// Published on every start if they are not active yet and the credentials they need exist.
const PUBLISH = {
  QhsWeBDcapYxxLYL: ['B7q0z4ZYxNQdMX09', 'eC5Ih8jiRzcY1AP5', 'ZJgIPopJgGjKkCiD'], // obrio (Slack Trigger)
  AccessReqReport1: ['ZJgIPopJgGjKkCiD'], // daily report
};

// --- credentials -----------------------------------------------------------
const tmp = '/tmp/n8n-setup-creds.json';
let existingCreds = new Set();
try {
  n8n('export:credentials', '--all', `--output=${tmp}`);
  existingCreds = new Set(JSON.parse(fs.readFileSync(tmp, 'utf8')).map((c) => c.id));
} catch {
  // no credentials yet
} finally {
  fs.rmSync(tmp, { force: true });
}

const missing = CREDENTIALS.filter((c) => !existingCreds.has(c.id));
const toCreate = missing.filter((c) => c.when);
for (const c of missing.filter((c) => !c.when)) log(`credential "${c.name}" skipped: not set in .env`);
if (toCreate.length) {
  try {
    fs.writeFileSync(tmp, JSON.stringify(toCreate.map(({ when, ...c }) => c)), { mode: 0o600 });
    n8n('import:credentials', `--input=${tmp}`);
  } finally {
    fs.rmSync(tmp, { force: true }); // holds plain-text secrets
  }
  for (const c of toCreate) {
    existingCreds.add(c.id);
    log(`credential "${c.name}" created`);
  }
}

// --- workflows -------------------------------------------------------------
// `list:workflow` prints "id|name" per line.
const listWorkflows = (...flags) => new Map(
  n8n('list:workflow', ...flags).split('\n')
    .map((l) => l.trim().split('|'))
    .filter(([id]) => /^[A-Za-z0-9]{16}$/.test(id))
    .map(([id, ...name]) => [id, name.join('|')]),
);
const existingWorkflows = listWorkflows();

const dir = '/workflows';
for (const file of fs.readdirSync(dir).filter((f) => f.endsWith('.json')).sort()) {
  const wf = JSON.parse(fs.readFileSync(path.join(dir, file), 'utf8'));
  const { id, name } = Array.isArray(wf) ? wf[0] : wf;
  if (existingWorkflows.has(id)) {
    log(`workflow "${name}" already exists, left as is`);
    continue;
  }
  n8n('import:workflow', `--input=${path.join(dir, file)}`);
  existingWorkflows.set(id, name);
  log(`workflow "${name}" imported`);
}

// --- publish ---------------------------------------------------------------
let active = new Map();
try {
  active = listWorkflows('--active=true');
} catch {
  // none active: list:workflow exits with an error on an empty result
}

for (const [id, needs] of Object.entries(PUBLISH)) {
  const name = existingWorkflows.get(id);
  if (name === undefined) continue;
  if (active.has(id)) {
    log(`workflow "${name}" is active`);
    continue;
  }
  const lacking = needs.filter((c) => !existingCreds.has(c));
  if (lacking.length) {
    log(`workflow "${name}" not published: missing credentials ${lacking.join(', ')}`);
    continue;
  }
  try {
    n8n('publish:workflow', `--id=${id}`);
    log(`workflow "${name}" published`);
  } catch (e) {
    const reason = String(e.stdout || '') + String(e.stderr || e.message);
    if (/archived/i.test(reason)) log(`workflow "${name}" is archived in n8n, skipped`);
    else log(`workflow "${name}" not published: ${reason.trim().split('\n').pop()}`);
  }
}
log('done');
