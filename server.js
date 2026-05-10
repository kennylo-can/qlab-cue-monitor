const http = require('node:http');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

// ---- Configuration ----

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

// ---- State ----

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
    preWait: '--.--',
    duration: '--:--',
    actionElapsed: 0,
  },
  nextCue: {
    id: '',
    name: '',
    number: '',
    type: '',
    preWait: '--.--',
  },
  log: [],
};

const clients = new Set();
const KEEPALIVE_MS = 30000;
const BROADCAST_COALESCE_MS = 50;

let broadcastTimer = null;
let broadcastPending = false;

// ---- WebSocket Engine ----

function encodeWebSocketFrame(payload, opcode = 0x01) {
  if (!Buffer.isBuffer(payload)) {
    payload = Buffer.from(payload);
  }
  const len = payload.length;
  let header;
  if (len < 126) {
    header = Buffer.alloc(2);
    header[0] = 0x80 | opcode;
    header[1] = len;
  } else if (len < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 126;
    header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(len), 2);
  }
  return Buffer.concat([header, payload]);
}

function decodeWebSocketFrame(buffer) {
  if (buffer.length < 2) return null;
  const opcode = buffer[0] & 0x0f;
  const masked = (buffer[1] & 0x80) !== 0;
  let len = buffer[1] & 0x7f;
  let offset = 2;

  if (len === 126) {
    if (buffer.length < 4) return null;
    len = buffer.readUInt16BE(2);
    offset = 4;
  } else if (len === 127) {
    if (buffer.length < 10) return null;
    len = Number(buffer.readBigUInt64BE(2));
    offset = 10;
  }

  const maskOffset = offset;
  if (masked) offset += 4;

  if (buffer.length < offset + len) return null;

  let payload = buffer.slice(offset, offset + len);
  if (masked) {
    const mask = buffer.slice(maskOffset, maskOffset + 4);
    for (let i = 0; i < payload.length; i++) {
      payload[i] ^= mask[i % 4];
    }
  }

  return { opcode, payload: payload.toString('utf8'), consumed: offset + len };
}

function sendFrame(socket, frame) {
  if (socket.writable && !socket.destroyed) {
    socket.write(frame);
  }
}

function broadcast() {
  if (broadcastTimer) return;
  broadcastTimer = setTimeout(() => {
    broadcastTimer = null;
    const text = JSON.stringify(state);
    const frame = encodeWebSocketFrame(text);
    for (const socket of clients) {
      try {
        sendFrame(socket, frame);
      } catch {
        clients.delete(socket);
      }
    }
  }, BROADCAST_COALESCE_MS);
}

function broadcastImmediate() {
  if (broadcastTimer) {
    clearTimeout(broadcastTimer);
    broadcastTimer = null;
  }
  const text = JSON.stringify(state);
  const frame = encodeWebSocketFrame(text);
  for (const socket of clients) {
    try {
      sendFrame(socket, frame);
    } catch {
      clients.delete(socket);
    }
  }
}

// ---- WebSocket Ping/Pong Heartbeat ----

function setupHeartbeat(socket) {
  socket.isAlive = true;
  socket._heartbeatMisses = 0;

  socket.on('pong', () => {
    socket.isAlive = true;
    socket._heartbeatMisses = 0;
  });
}

function checkHeartbeats() {
  for (const socket of clients) {
    if (!socket.isAlive) {
      socket._heartbeatMisses = (socket._heartbeatMisses || 0) + 1;
      if (socket._heartbeatMisses >= 3) {
        clients.delete(socket);
        socket.destroy();
        continue;
      }
    }
    socket.isAlive = false;
    try {
      socket.write(encodeWebSocketFrame(Buffer.alloc(0), 0x09));
    } catch {
      clients.delete(socket);
      socket.destroy();
    }
  }
}

setInterval(checkHeartbeats, KEEPALIVE_MS).unref();

// ---- Helpers ----

function pushLog(message) {
  state.log.unshift({
    time: new Date().toISOString(),
    message,
  });
  state.log = state.log.slice(0, 20);
}

function shutdown(code = 0) {
  state.service.shutdownRequested = true;
  broadcastImmediate();

  setTimeout(() => {
    try {
      server.close(() => process.exit(code));
    } catch {
      process.exit(code);
    }
  }, 200);
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
  if (normalized.currentCue) {
    state.currentCue = { ...state.currentCue, ...normalized.currentCue };
  }
  if (normalized.nextCue) {
    state.nextCue = { ...state.nextCue, ...normalized.nextCue };
  }
  if (Array.isArray(normalized.log)) state.log = normalized.log.slice(0, 20);
  state.source.connected = true;
  state.source.lastPacketAt = new Date().toISOString();
  state.service.sourceName = sourceName;
  pushLog(`State received from ${sourceName}`);
  broadcast();
  return true;
}

function serveFile(res, filePath, contentType) {
  try {
    const data = fs.readFileSync(filePath);
    res.writeHead(200, { 'Content-Type': contentType, 'Cache-Control': 'no-cache' });
    res.end(data);
  } catch {
    res.writeHead(404);
    res.end('Not found');
  }
}

// ---- HTTP Server ----

const server = http.createServer((req, res) => {
  const url = req.url || '/';

  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  // Health check
  if (url === '/api/health' || url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({
      ok: true,
      service: state.service,
      source: state.source,
      clients: clients.size,
    }));
    return;
  }

  // State endpoint
  if (url === '/api/state') {
    if (req.method === 'POST' || req.method === 'PUT') {
      let body = '';
      req.on('data', (chunk) => { body += chunk; });
      req.on('end', () => {
        try {
          if (!body || body.trim().length === 0) {
            res.writeHead(400, { 'Content-Type': 'application/json; charset=utf-8' });
            res.end(JSON.stringify({ ok: false, error: 'Empty body' }));
            return;
          }
          const parsed = JSON.parse(body);
          const payload = parsed.state || parsed;
          const sourceName = typeof parsed.sourceName === 'string' ? parsed.sourceName : config.sourceName || DEFAULT_CONFIG.sourceName;
          const accepted = applyIncomingState(payload, sourceName);
          if (!accepted) {
            res.writeHead(400, { 'Content-Type': 'application/json; charset=utf-8' });
            res.end(JSON.stringify({ ok: false, error: 'Invalid state payload' }));
            return;
          }
          res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
          res.end(JSON.stringify({ ok: true }));
        } catch (error) {
          res.writeHead(400, { 'Content-Type': 'application/json; charset=utf-8' });
          res.end(JSON.stringify({ ok: false, error: error.message }));
        }
      });
      return;
    }
    // GET
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify(state));
    return;
  }

  // Settings
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

  // Actions: reload
  if (url === '/api/actions/reload' && req.method === 'POST') {
    state.service.startedAt = new Date().toISOString();
    pushLog('Service reload requested');
    broadcast();
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ ok: true }));
    return;
  }

  // Actions: clear-log
  if (url === '/api/actions/clear-log' && req.method === 'POST') {
    state.log = [];
    pushLog('Log cleared');
    broadcast();
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ ok: true }));
    return;
  }

  // Actions: shutdown
  if (url === '/api/actions/shutdown' && req.method === 'POST') {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ ok: true, message: 'Shutting down' }));
    setImmediate(() => shutdown(0));
    return;
  }

  // Static files
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

// ---- WebSocket Upgrade ----

server.on('upgrade', (req, socket, head) => {
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
  setupHeartbeat(socket);

  // Handle incoming WebSocket frames
  let frameBuffer = Buffer.alloc(0);
  socket.on('data', (chunk) => {
    frameBuffer = Buffer.concat([frameBuffer, chunk]);

    const frame = decodeWebSocketFrame(frameBuffer);
    if (!frame) return;

    frameBuffer = frameBuffer.slice(frame.consumed);

    // Ping → Pong
    if (frame.opcode === 0x09) {
      try {
        socket.write(encodeWebSocketFrame(Buffer.from(frame.payload), 0x0A));
      } catch {}
      return;
    }

    // Pong → handled by heartbeat
    if (frame.opcode === 0x0A) {
      socket.emit('pong');
      return;
    }

    // Close frame
    if (frame.opcode === 0x08) {
      clients.delete(socket);
      try {
        socket.write(encodeWebSocketFrame(Buffer.alloc(0), 0x08));
      } catch {}
      try { socket.end(); } catch {}
      return;
    }

    // Text frames (opcode 0x01) → client commands
    if (frame.opcode === 0x01 && frame.payload) {
      try {
        const cmd = JSON.parse(frame.payload);
        if (cmd.type === 'getState') {
          socket.write(encodeWebSocketFrame(JSON.stringify(state)));
        }
      } catch {}
    }
  });

  socket.on('close', () => clients.delete(socket));
  socket.on('error', () => clients.delete(socket));

  // Send current state on connect
  socket.write(encodeWebSocketFrame(JSON.stringify(state)));
});

// ---- Port Conflict Handling ----

function startServer(port) {
  return new Promise((resolve, reject) => {
    const srv = server.listen(port, HOST, () => {
      resolve(srv);
    });
    srv.on('error', (err) => {
      if (err.code === 'EADDRINUSE') {
        reject(err);
      } else {
        reject(err);
      }
    });
  });
}

async function autoStart(port = PORT, retries = 5) {
  for (let i = 0; i < retries; i++) {
    try {
      await startServer(port);
      return port;
    } catch (err) {
      if (err.code === 'EADDRINUSE' && i < retries - 1) {
        console.warn(`Port ${port} in use, trying ${port + 1}...`);
        port += 1;
      } else {
        throw err;
      }
    }
  }
  throw new Error(`Could not bind to any port after ${retries} attempts`);
}

autoStart(PORT)
  .then((actualPort) => {
    const interfaces = Object.values(os.networkInterfaces())
      .flat()
      .filter(Boolean)
      .filter((item) => item.family === 'IPv4' && !item.internal)
      .map((item) => item.address);

    if (actualPort !== PORT) {
      console.log(`[Note] Original port ${PORT} was in use; bound to ${actualPort} instead.`);
      state.service.port = actualPort;
    }

    console.log(`Dashboard: http://localhost:${actualPort}`);
    for (const ip of interfaces) {
      console.log(`LAN access: http://${ip}:${actualPort}`);
    }
  })
  .catch((err) => {
    console.error('Failed to start server:', err.message || err);
    process.exit(1);
  });

process.on('SIGINT', () => shutdown(0));
process.on('SIGTERM', () => shutdown(0));
process.on('uncaughtException', (err) => {
  console.error('Uncaught exception:', err.message || err);
  pushLog(`Server error: ${err.message || err}`);
});
