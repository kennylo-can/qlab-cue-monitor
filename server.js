const http = require('node:http');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

const HOST = process.env.HOST || '0.0.0.0';
const CONFIG_PATH = path.join(__dirname, 'config.json');
const DEFAULT_CONFIG = {
  host: HOST,
  port: Number(process.env.PORT || 8088),
  sourcePort: Number(process.env.SOURCE_PORT || 53000),
  sourceName: 'Companion',
  workspaceName: 'Default Workspace',
  cueListName: 'Default Cue List',
  title: 'QLab Production Dashboard',
};

function loadConfig() {
  try {
    const raw = fs.readFileSync(CONFIG_PATH, 'utf8');
    const loaded = { ...DEFAULT_CONFIG, ...JSON.parse(raw) };
    if (!process.env.PORT && Number(loaded.port) === 3000) {
      loaded.port = DEFAULT_CONFIG.port;
    }
    return loaded;
  } catch {
    return { ...DEFAULT_CONFIG };
  }
}

function saveConfig(nextConfig) {
  fs.writeFileSync(CONFIG_PATH, JSON.stringify(nextConfig, null, 2));
}

let config = loadConfig();
const PORT = Number(config.port || DEFAULT_CONFIG.port);
const SOURCE_PORT = Number(config.sourcePort || DEFAULT_CONFIG.sourcePort);

const publicDir = path.join(__dirname, 'public');

const state = {
  service: {
    host: config.host || HOST,
    port: PORT,
    sourcePort: SOURCE_PORT,
    sourceName: config.sourceName || DEFAULT_CONFIG.sourceName,
    startedAt: new Date().toISOString(),
    shutdownRequested: false,
  },
  settings: config,
  source: {
    mode: 'Companion bridge',
    connected: false,
    lastPacketAt: null,
  },
  workspaceName: config.workspaceName || DEFAULT_CONFIG.workspaceName,
  cueListName: config.cueListName || DEFAULT_CONFIG.cueListName,
  timecode: '--:--:--:--',
  totalCues: 0,
  audioState: 'STABLE',
  masterVol: '-',
  progress: 0,
  elapsedSeconds: 0,
  remainingSeconds: 0,
  lastUpdate: null,
  latestOsc: null,
  currentCue: {
    id: '',
    name: '',
    number: '',
    type: '',
    color: '',
    notes: '',
    path: '',
    listName: '',
  },
  nextCue: {
    id: '',
    name: '',
    number: '',
    type: '',
  },
  log: [],
};

const clients = new Set();

function pushLog(message) {
  state.log.unshift({
    time: new Date().toISOString(),
    message,
  });
  state.log = state.log.slice(0, 20);
}

function encodeWebSocketFrame(text) {
  const payload = Buffer.from(text);
  const len = payload.length;
  let header;
  if (len < 126) {
    header = Buffer.alloc(2);
    header[0] = 0x81;
    header[1] = len;
  } else if (len < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 126;
    header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x81;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(len), 2);
  }
  return Buffer.concat([header, payload]);
}

function broadcast() {
  const text = JSON.stringify(state);
  for (const socket of clients) {
    try {
      socket.write(encodeWebSocketFrame(text));
    } catch {
      clients.delete(socket);
    }
  }
}

function shutdown(code = 0) {
  state.service.shutdownRequested = true;
  broadcast();
  try {
    udp.close();
  } catch {}
  try {
    server.close(() => process.exit(code));
  } catch {
    process.exit(code);
  }
  setTimeout(() => process.exit(code), 500).unref();
}

function applyConfigPatch(patch) {
  const next = { ...config };
  if (typeof patch.host === 'string') next.host = patch.host || DEFAULT_CONFIG.host;
  if (Number.isFinite(Number(patch.port))) next.port = Number(patch.port);
  if (Number.isFinite(Number(patch.sourcePort))) next.sourcePort = Number(patch.sourcePort);
  if (typeof patch.sourceName === 'string') next.sourceName = patch.sourceName || DEFAULT_CONFIG.sourceName;
  if (typeof patch.workspaceName === 'string') next.workspaceName = patch.workspaceName;
  if (typeof patch.cueListName === 'string') next.cueListName = patch.cueListName;
  if (typeof patch.title === 'string') next.title = patch.title;
  config = next;
  state.settings = config;
  state.service.host = config.host || HOST;
  state.service.port = config.port;
  state.service.sourcePort = config.sourcePort;
  state.service.sourceName = config.sourceName || DEFAULT_CONFIG.sourceName;
  state.workspaceName = config.workspaceName || DEFAULT_CONFIG.workspaceName;
  state.cueListName = config.cueListName || DEFAULT_CONFIG.cueListName;
  saveConfig(config);
}

function normalizeIncomingState(payload) {
  if (!payload || typeof payload !== 'object') return null;
  const next = {};
  if (typeof payload.connectionState === 'string') next.connectionState = payload.connectionState;
  if (typeof payload.workspaceName === 'string') next.workspaceName = payload.workspaceName;
  if (typeof payload.cueListName === 'string') next.cueListName = payload.cueListName;
  if (typeof payload.timecode === 'string') next.timecode = payload.timecode;
  if (typeof payload.audioState === 'string') next.audioState = payload.audioState;
  if (payload.progress !== undefined) next.progress = Number(payload.progress);
  if (payload.elapsedSeconds !== undefined) next.elapsedSeconds = Number(payload.elapsedSeconds);
  if (payload.remainingSeconds !== undefined) next.remainingSeconds = Number(payload.remainingSeconds);
  if (payload.masterVol !== undefined) next.masterVol = String(payload.masterVol);
  if (payload.totalCues !== undefined) next.totalCues = Number(payload.totalCues);
  if (payload.latestOsc) next.latestOsc = payload.latestOsc;
  if (payload.currentCue && typeof payload.currentCue === 'object') next.currentCue = payload.currentCue;
  if (payload.nextCue && typeof payload.nextCue === 'object') next.nextCue = payload.nextCue;
  if (Array.isArray(payload.log)) next.log = payload.log;
  return next;
}

function applyIncomingState(payload, sourceName = DEFAULT_CONFIG.sourceName) {
  const normalized = normalizeIncomingState(payload);
  if (!normalized) return false;
  if (normalized.connectionState) state.connectionState = normalized.connectionState;
  if (normalized.workspaceName) state.workspaceName = normalized.workspaceName;
  if (normalized.cueListName) state.cueListName = normalized.cueListName;
  if (normalized.timecode) state.timecode = normalized.timecode;
  if (normalized.audioState) state.audioState = normalized.audioState;
  if (Number.isFinite(normalized.progress)) state.progress = normalized.progress;
  if (Number.isFinite(normalized.elapsedSeconds)) state.elapsedSeconds = normalized.elapsedSeconds;
  if (Number.isFinite(normalized.remainingSeconds)) state.remainingSeconds = normalized.remainingSeconds;
  if (normalized.masterVol !== undefined) state.masterVol = normalized.masterVol;
  if (Number.isFinite(normalized.totalCues)) state.totalCues = normalized.totalCues;
  if (normalized.latestOsc) state.latestOsc = normalized.latestOsc;
  if (normalized.currentCue) state.currentCue = { ...state.currentCue, ...normalized.currentCue };
  if (normalized.nextCue) state.nextCue = { ...state.nextCue, ...normalized.nextCue };
  if (Array.isArray(normalized.log)) state.log = normalized.log.slice(0, 20);
  state.source.connected = true;
  state.source.lastPacketAt = new Date().toISOString();
  state.service.sourceName = sourceName;
  pushLog(`State received from ${sourceName}`);
  broadcast();
  return true;
}

function serveFile(res, filePath, contentType) {
  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404);
      res.end('Not found');
      return;
    }
    res.writeHead(200, { 'Content-Type': contentType });
    res.end(data);
  });
}

const server = http.createServer((req, res) => {
  const url = req.url || '/';
  if (url === '/api/health' || url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({
      ok: true,
      service: state.service,
      source: state.source,
    }));
    return;
  }
  if (url === '/api/state') {
    if (req.method === 'POST' || req.method === 'PUT') {
      let body = '';
      req.on('data', (chunk) => { body += chunk; });
      req.on('end', () => {
        try {
          const payload = JSON.parse(body || '{}');
          const sourceName = typeof payload.sourceName === 'string' ? payload.sourceName : config.sourceName || DEFAULT_CONFIG.sourceName;
          const accepted = applyIncomingState(payload.state || payload, sourceName);
          if (!accepted) {
            res.writeHead(400, { 'Content-Type': 'application/json; charset=utf-8' });
            res.end(JSON.stringify({ ok: false, error: 'Invalid state payload' }));
            return;
          }
          res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
          res.end(JSON.stringify({ ok: true, state }));
        } catch (error) {
          res.writeHead(400, { 'Content-Type': 'application/json; charset=utf-8' });
          res.end(JSON.stringify({ ok: false, error: error.message }));
        }
      });
      return;
    }
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(state));
    return;
  }
  if (url === '/api/settings' && req.method === 'POST') {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      try {
        const patch = JSON.parse(body || '{}');
        applyConfigPatch(patch);
        broadcast();
        res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({ ok: true, settings: state.settings }));
      } catch (error) {
        res.writeHead(400, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({ ok: false, error: error.message }));
      }
    });
    return;
  }
  if (url === '/api/actions/reload' && req.method === 'POST') {
    state.service.startedAt = new Date().toISOString();
    pushLog('Service reload requested');
    broadcast();
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ ok: true }));
    return;
  }
  if (url === '/api/actions/clear-log' && req.method === 'POST') {
    state.log = [];
    pushLog('Log cleared');
    broadcast();
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ ok: true }));
    return;
  }
  if (url === '/api/actions/shutdown' && req.method === 'POST') {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ ok: true, message: 'Shutting down' }));
    setImmediate(() => shutdown(0));
    return;
  }
  if (url === '/' || url === '/index.html') {
    if (req.method === 'HEAD') {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end();
      return;
    }
    serveFile(res, path.join(publicDir, 'index.html'), 'text/html; charset=utf-8');
    return;
  }
  if (url === '/app.js') {
    serveFile(res, path.join(publicDir, 'app.js'), 'text/javascript; charset=utf-8');
    return;
  }
  if (url === '/styles.css') {
    serveFile(res, path.join(publicDir, 'styles.css'), 'text/css; charset=utf-8');
    return;
  }
  res.writeHead(404);
  res.end('Not found');
});

server.on('upgrade', (req, socket) => {
  if (req.headers.upgrade?.toLowerCase() !== 'websocket') {
    socket.destroy();
    return;
  }
  const key = req.headers['sec-websocket-key'];
  if (!key) {
    socket.destroy();
    return;
  }
  const accept = crypto
    .createHash('sha1')
    .update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')
    .digest('base64');
  const headers = [
    'HTTP/1.1 101 Switching Protocols',
    'Upgrade: websocket',
    'Connection: Upgrade',
    `Sec-WebSocket-Accept: ${accept}`,
    '',
    '',
  ];
  socket.write(headers.join('\r\n'));
  clients.add(socket);
  socket.on('close', () => clients.delete(socket));
  socket.on('error', () => clients.delete(socket));
  socket.on('data', () => {});
  socket.write(encodeWebSocketFrame(JSON.stringify(state)));
});

server.listen(PORT, HOST, () => {
  const interfaces = Object.values(os.networkInterfaces())
    .flat()
    .filter(Boolean)
    .filter((item) => item.family === 'IPv4' && !item.internal)
    .map((item) => item.address);
  console.log(`Dashboard: http://localhost:${PORT}`);
  for (const ip of interfaces) {
    console.log(`LAN access: http://${ip}:${PORT}`);
  }
});

process.on('SIGINT', () => shutdown(0));
process.on('SIGTERM', () => shutdown(0));
