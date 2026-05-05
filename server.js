const http = require('node:http');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');

const PORT = Number.parseInt(process.env.PORT || '8080', 10);
const POLL_MS = Number.parseInt(process.env.POLL_MS || '100', 10);
const FETCH_TIMEOUT_MS = Number.parseInt(process.env.FETCH_TIMEOUT_MS || '800', 10);
const STATIC_ROOT = path.resolve(process.env.QLAB_CUE_MONITOR_STATIC_ROOT || __dirname);
const DATA_ROOT = path.resolve(process.env.QLAB_CUE_MONITOR_DATA_DIR || __dirname);
const CONFIG_PATH = path.join(DATA_ROOT, '.qlab-cue-monitor.config.json');

fs.mkdirSync(DATA_ROOT, { recursive: true });

function normalizeHost(value) {
  return String(value || '').trim().replace(/\/$/, '');
}

function loadConfig() {
  const defaults = {
    companionHost: normalizeHost(process.env.COMPANION_HOST || 'http://127.0.0.1:8000'),
    connectionId: process.env.CONNECTION_ID || 'qlabfb'
  };

  try {
    const raw = fs.readFileSync(CONFIG_PATH, 'utf8');
    const parsed = JSON.parse(raw);
    return {
      companionHost: normalizeHost(parsed.companionHost || defaults.companionHost),
      connectionId: String(parsed.connectionId || defaults.connectionId).trim() || defaults.connectionId
    };
  } catch {
    return defaults;
  }
}

async function saveConfig(nextConfig) {
  const companionHost = normalizeHost(nextConfig.companionHost);
  if (!companionHost) {
    throw new Error('Companion address is required');
  }
  const payload = {
    companionHost,
    connectionId: String(nextConfig.connectionId || '').trim() || 'qlabfb'
  };
  await fsp.writeFile(CONFIG_PATH, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return payload;
}

let runtimeConfig = loadConfig();

const STATE = {
  ok: false,
  error: 'Starting…',
  snapshot: null,
  updatedAt: null,
  connectionId: runtimeConfig.connectionId,
  companionHost: runtimeConfig.companionHost
};

let endpointMode = null;
let errorStreak = 0;
let refreshing = false;
let pollGeneration = 0;
let pollTimer = null;
const eventClients = new Set();

function cleanValue(value) {
  if (value === null || value === undefined) return '';
  if (typeof value === 'object') {
    if ('value' in value) return cleanValue(value.value);
    if ('result' in value) return cleanValue(value.result);
    if ('data' in value) return cleanValue(value.data);
    return JSON.stringify(value);
  }
  return String(value).replace(/^"|"$/g, '').trim();
}

async function fetchText(url) {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);

  try {
    const res = await fetch(url, { cache: 'no-store', signal: controller.signal });
    if (!res.ok) throw new Error(`${res.status} ${url}`);
    const text = await res.text();
    try {
      return cleanValue(JSON.parse(text));
    } catch {
      return cleanValue(text);
    }
  } finally {
    clearTimeout(timeoutId);
  }
}

function buildVariableUrls(variableName) {
  const connection = encodeURIComponent(runtimeConfig.connectionId);
  const variable = encodeURIComponent(variableName);
  const fullName = encodeURIComponent(`${runtimeConfig.connectionId}:${variableName}`);

  return [
    `${runtimeConfig.companionHost}/api/variable/${connection}/${variable}/value`,
    `${runtimeConfig.companionHost}/api/variable/connection/${connection}/${variable}/value`,
    `${runtimeConfig.companionHost}/api/${connection}/${variable}/value`,
    `${runtimeConfig.companionHost}/api/variable/${fullName}/value`
  ];
}

function isHtmlPayload(value) {
  const lower = value.toLowerCase();
  return lower.includes('<!doctype html>') || lower.includes('<html');
}

async function probeCompanionEndpoint(variableName) {
  const candidates = buildVariableUrls(variableName);
  let lastError;

  for (let mode = 0; mode < candidates.length; mode += 1) {
    const url = candidates[mode];
    try {
      const value = await fetchText(url);
      if (isHtmlPayload(value) || value.includes('Bitfocus Companion')) continue;
      endpointMode = mode;
      return { mode, value };
    } catch (err) {
      lastError = err;
    }
  }

  throw lastError || new Error('No valid Companion variable endpoint matched');
}

async function getCompanionVariable(variableName, mode = endpointMode) {
  const candidates = buildVariableUrls(variableName);
  const urls = Number.isInteger(mode) ? [candidates[mode]] : candidates;
  let lastError;

  for (let index = 0; index < urls.length; index += 1) {
    const url = urls[index];
    try {
      const value = await fetchText(url);
      if (isHtmlPayload(value) || value.includes('Bitfocus Companion')) continue;
      if (!Number.isInteger(mode)) {
        endpointMode = index;
      }
      return value;
    } catch (err) {
      lastError = err;
      if (Number.isInteger(mode)) break;
    }
  }

  throw lastError || new Error('No valid Companion variable endpoint matched');
}

function pad2(value) {
  const n = Number.parseInt(String(value || '0'), 10);
  if (!Number.isFinite(n)) return '00';
  return String(Math.max(0, n)).padStart(2, '0');
}

function makeTime(mm, ss) {
  return `${pad2(mm)}:${pad2(ss)}`;
}

function secondsFromParts(mm, ss) {
  const m = Number.parseInt(String(mm || '0'), 10);
  const s = Number.parseInt(String(ss || '0'), 10);
  if (!Number.isFinite(m) || !Number.isFinite(s)) return NaN;
  return m * 60 + s;
}

function cuePrefix(num) {
  if (!num || num === '--') return 'Q --';
  return String(num).startsWith('Q') ? String(num) : `Q ${num}`;
}

async function fetchSnapshot() {
  let mode = endpointMode;
  let cueName;

  if (!Number.isInteger(mode)) {
    const probe = await probeCompanionEndpoint('r_name');
    mode = probe.mode;
    cueName = probe.value;
  } else {
    cueName = await getCompanionVariable('r_name', mode);
  }

  endpointMode = mode;

  const [cueNumber, rMM, rSS, eMM, eSS, nextCue, nextCueNumber] = await Promise.all([
    getCompanionVariable('r_num', mode),
    getCompanionVariable('r_mm', mode),
    getCompanionVariable('r_ss', mode),
    getCompanionVariable('e_mm', mode),
    getCompanionVariable('e_ss', mode),
    getCompanionVariable('n_name', mode),
    getCompanionVariable('n_num', mode)
  ]);

  return { cueName, cueNumber, rMM, rSS, eMM, eSS, nextCue, nextCueNumber };
}

function toViewState(snapshot) {
  const hasCue = Boolean(snapshot.cueName && snapshot.cueName !== '--');
  const remainingSeconds = secondsFromParts(snapshot.rMM, snapshot.rSS);
  const elapsedSeconds = secondsFromParts(snapshot.eMM, snapshot.eSS);
  const total = remainingSeconds + elapsedSeconds;

  let qlabState = hasCue ? 'RUNNING' : 'IDLE';
  let uiMode = hasCue ? '' : 'idle';

  if (hasCue && Number.isFinite(remainingSeconds)) {
    if (remainingSeconds <= 10) {
      qlabState = 'ENDING';
      uiMode = 'danger';
    } else if (remainingSeconds <= 30) {
      qlabState = 'WARNING';
      uiMode = 'warning';
    }
  }

  let progress = 0;
  if (hasCue && Number.isFinite(total) && total > 0) {
    progress = Math.max(0, Math.min(100, (elapsedSeconds / total) * 100));
  }

  return {
    cueName: hasCue ? snapshot.cueName : 'Waiting for QLab',
    cueNumber: cuePrefix(snapshot.cueNumber),
    nextCueNumber: cuePrefix(snapshot.nextCueNumber),
    remaining: makeTime(snapshot.rMM, snapshot.rSS),
    elapsed: makeTime(snapshot.eMM, snapshot.eSS),
    nextCue: snapshot.nextCue || '--',
    qlabState,
    uiMode,
    progress,
    progressText: `${Math.round(progress)}%`
  };
}

function setStateFromSnapshot(snapshot) {
  const view = toViewState(snapshot);
  STATE.ok = true;
  STATE.error = null;
  STATE.snapshot = { ...snapshot, view };
  STATE.updatedAt = Date.now();
}

function setOfflineState(error) {
  STATE.ok = false;
  STATE.error = error;
  STATE.updatedAt = Date.now();
}

function variableFromPath(pathname) {
  const parts = pathname.split('/').filter(Boolean);
  const valueIndex = parts.lastIndexOf('value');
  if (valueIndex === -1 || valueIndex < 2) return null;

  const beforeValue = decodeURIComponent(parts[valueIndex - 1] || '');
  if (!beforeValue) return null;
  if (beforeValue.includes(':')) return beforeValue.split(':').pop();
  return beforeValue;
}

function variableResponse(variableName) {
  const snapshot = STATE.snapshot;
  if (!STATE.ok || !snapshot) return '--';

  switch (variableName) {
    case 'r_name':
      return snapshot.cueName;
    case 'r_num':
      return snapshot.cueNumber;
    case 'r_mm':
      return snapshot.rMM;
    case 'r_ss':
      return snapshot.rSS;
    case 'e_mm':
      return snapshot.eMM;
    case 'e_ss':
      return snapshot.eSS;
    case 'n_name':
      return snapshot.nextCue;
    case 'n_num':
      return snapshot.nextCueNumber;
    default:
      return null;
  }
}

function broadcastState() {
  const payload = `event: state\ndata: ${JSON.stringify({
    ok: STATE.ok,
    error: STATE.error,
    updatedAt: STATE.updatedAt,
    snapshot: STATE.ok && STATE.snapshot
      ? { ...STATE.snapshot, view: STATE.snapshot.view }
      : null,
    connectionId: STATE.connectionId,
    companionHost: STATE.companionHost
  })}\n\n`;

  for (const res of eventClients) {
    res.write(payload);
  }
}

function scheduleNextPoll() {
  if (pollTimer) clearTimeout(pollTimer);

  const delay = STATE.ok
    ? POLL_MS
    : Math.min(5000, Math.max(POLL_MS, POLL_MS * (2 ** Math.min(errorStreak, 4))));

  pollTimer = setTimeout(() => {
    void refreshLoop();
  }, delay);
}

async function refreshLoop() {
  if (refreshing) return;
  refreshing = true;

  try {
    const snapshot = await fetchSnapshot();
    errorStreak = 0;
    setStateFromSnapshot(snapshot);
    broadcastState();
  } catch (err) {
    errorStreak = Math.min(errorStreak + 1, 6);
    setOfflineState(err instanceof Error ? err.message : String(err));
    broadcastState();
  } finally {
    refreshing = false;
    scheduleNextPoll();
  }
}

function sendJson(res, statusCode, data) {
  res.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store'
  });
  res.end(JSON.stringify(data));
}

function sendText(res, statusCode, text, contentType = 'text/plain; charset=utf-8') {
  res.writeHead(statusCode, {
    'Content-Type': contentType,
    'Cache-Control': 'no-store'
  });
  res.end(text);
}

function sendFile(res, filePath) {
  const ext = path.extname(filePath).toLowerCase();
  const contentType = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.txt': 'text/plain; charset=utf-8',
    '.ico': 'image/x-icon'
  }[ext] || 'application/octet-stream';

  const stream = fs.createReadStream(filePath);
  stream.on('error', () => {
    sendText(res, 404, 'Not found');
  });
  res.writeHead(200, {
    'Content-Type': contentType,
    'Cache-Control': 'no-store'
  });
  stream.pipe(res);
}

function handleEvents(req, res) {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream; charset=utf-8',
    'Cache-Control': 'no-cache, no-store, must-revalidate',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no'
  });

  res.write(`event: state\ndata: ${JSON.stringify({
    ok: STATE.ok,
    error: STATE.error,
    updatedAt: STATE.updatedAt,
    snapshot: STATE.ok && STATE.snapshot
      ? { ...STATE.snapshot, view: STATE.snapshot.view }
      : null,
    connectionId: STATE.connectionId,
    companionHost: STATE.companionHost
  })}\n\n`);

  eventClients.add(res);
  const keepAlive = setInterval(() => {
    res.write(': keepalive\n\n');
  }, 15000);

  req.on('close', () => {
    clearInterval(keepAlive);
    eventClients.delete(res);
  });
}

async function handleRequest(req, res) {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const { pathname } = url;

  if (req.method === 'GET' && pathname === '/api/config') {
    return sendJson(res, 200, {
      companionHost: runtimeConfig.companionHost,
      connectionId: runtimeConfig.connectionId
    });
  }

  if (req.method === 'POST' && pathname === '/api/config') {
    let body = '';
    for await (const chunk of req) {
      body += chunk;
    }

    let parsed;
    try {
      parsed = JSON.parse(body || '{}');
    } catch {
      return sendJson(res, 400, { ok: false, error: 'Invalid JSON' });
    }

    const nextConfig = {
      companionHost: normalizeHost(parsed.companionHost || parsed.host || runtimeConfig.companionHost),
      connectionId: String(parsed.connectionId || runtimeConfig.connectionId).trim() || runtimeConfig.connectionId
    };

    try {
      runtimeConfig = await saveConfig(nextConfig);
      STATE.connectionId = runtimeConfig.connectionId;
      STATE.companionHost = runtimeConfig.companionHost;
      endpointMode = null;
      errorStreak = 0;
      refreshing = false;
      pollGeneration += 1;
      if (pollTimer) clearTimeout(pollTimer);
      void refreshLoop();
      broadcastState();
      return sendJson(res, 200, {
        ok: true,
        companionHost: runtimeConfig.companionHost,
        connectionId: runtimeConfig.connectionId
      });
    } catch (err) {
      return sendJson(res, 500, { ok: false, error: err instanceof Error ? err.message : String(err) });
    }
  }

  if (req.method === 'GET' && pathname === '/api/state') {
    return sendJson(res, 200, {
      ok: STATE.ok,
      error: STATE.error,
      updatedAt: STATE.updatedAt,
      snapshot: STATE.ok && STATE.snapshot ? { ...STATE.snapshot, view: STATE.snapshot.view } : null,
      connectionId: STATE.connectionId,
      companionHost: STATE.companionHost
    });
  }

  if (req.method === 'GET' && pathname === '/api/events') {
    return handleEvents(req, res);
  }

  if (req.method === 'GET' && pathname.startsWith('/api/')) {
    const variableName = variableFromPath(pathname);
    if (variableName) {
      const value = variableResponse(variableName);
      if (value !== null) {
        return sendText(res, 200, String(value));
      }
    }
  }

  const relativePath = pathname === '/' ? '/index.html' : pathname;
  const filePath = path.resolve(STATIC_ROOT, `.${relativePath}`);
  if (!filePath.startsWith(STATIC_ROOT)) {
    return sendText(res, 403, 'Forbidden');
  }

  try {
    const stat = await fsp.stat(filePath);
    if (stat.isFile()) {
      return sendFile(res, filePath);
    }
  } catch {
    // fall through to 404
  }

  return sendText(res, 404, 'Not found');
}

const server = http.createServer((req, res) => {
  void handleRequest(req, res).catch((err) => {
    console.error(err);
    sendText(res, 500, 'Internal Server Error');
  });
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`QLab Cue Monitor server listening on http://0.0.0.0:${PORT}`);
  console.log(`Companion upstream: ${runtimeConfig.companionHost}`);
});

void refreshLoop();
