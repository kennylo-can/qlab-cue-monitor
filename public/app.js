const $ = (id) => document.getElementById(id);

const els = {
  status: $('status'),
  workspaceName: $('workspaceName'),
  wallClock: $('wallClock'),
  serviceState: $('serviceState'),
  currentNumber: $('currentNumber'),
  currentName: $('currentName'),
  currentMeta: $('currentMeta'),
  progressBar: $('progressBar'),
  elapsed: $('elapsed'),
  remaining: $('remaining'),
  nextNumber: $('nextNumber'),
  nextName: $('nextName'),
  nextMeta: $('nextMeta'),
  timecode: $('timecode'),
  totalCues: $('totalCues'),
  masterVol: $('masterVol'),
  latestOsc: $('latestOsc'),
  log: $('log'),
};

let logCount = 0;

function escapeHtml(text) {
  return String(text)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function formatTime(value) {
  if (!Number.isFinite(value) || value < 0) return '--:--';
  const mins = Math.floor(value / 60);
  const secs = Math.floor(value % 60);
  return `${String(mins).padStart(2, '0')}:${String(secs).padStart(2, '0')}`;
}

function render(state = {}) {
  const service = state.service || {};
  const current = state.currentCue || {};
  const next = state.nextCue || {};

  const connection = state.connectionState || 'WAITING FOR COMPANION';
  els.status.textContent = connection;
  els.status.style.color = connection.toUpperCase().includes('CONNECTED')
    ? 'var(--active)'
    : connection.toUpperCase().includes('DISCONNECTED')
    ? 'var(--warning)'
    : 'var(--standby)';

  els.workspaceName.textContent = `${state.workspaceName || 'MAIN STAGE'} · ${state.cueListName || 'Default Cue List'}`;
  els.serviceState.textContent = `${service.sourceName || 'Companion'} ${state.source && state.source.connected ? 'CONNECTED' : 'WAITING'}`;

  els.currentNumber.textContent = current.number || current.id || '--';
  els.currentName.textContent = current.name || 'Waiting for data…';
  els.currentMeta.textContent = [
    current.type ? `Type: ${current.type}` : null,
    current.id ? `ID: ${current.id}` : null,
    current.path ? `Path: ${current.path}` : null,
    current.color ? `Color: ${current.color}` : null,
    current.listName ? `List: ${current.listName}` : null,
    current.preWait ? `Pre-wait: ${current.preWait}` : null,
  ].filter(Boolean).join('  ·  ') || 'No cue metadata yet.';

  const progress = Number(state.progress ?? 0);
  els.progressBar.style.width = `${Math.max(0, Math.min(100, progress))}%`;
  els.elapsed.textContent = `ELAPSED: ${formatTime(state.elapsedSeconds ?? 0)}`;
  els.remaining.textContent = `REMAINING: ${formatTime(state.remainingSeconds ?? 0)}`;

  els.nextNumber.textContent = next.number || next.id || '--';
  els.nextName.textContent = next.name || '-';
  els.nextMeta.textContent = next.preWait
    ? `Pre-wait: ${next.preWait}`
    : !next.number && !next.id
    ? 'Pre-wait: --'
    : els.nextMeta.textContent;

  els.timecode.textContent = state.timecode || '--:--:--:--';
  els.totalCues.textContent = state.totalCues ?? '-';
  els.masterVol.textContent = state.masterVol ?? '-';

  els.latestOsc.textContent = state.latestOsc ? JSON.stringify(state.latestOsc, null, 2) : '-';

  // Smart log rendering: only add new entries, don't rebuild
  const logEntries = state.log || [];
  if (logEntries.length > logCount) {
    const newEntries = logEntries.slice(logCount);
    for (const item of newEntries) {
      const row = document.createElement('div');
      row.className = 'log-item';
      row.innerHTML = `<span class="log-time">${new Date(item.time).toLocaleTimeString()}</span><span>${escapeHtml(item.message)}</span>`;
      els.log.prepend(row);
    }
    logCount = logEntries.length;
    // Keep max 50 log items in DOM
    while (els.log.children.length > 50) {
      els.log.lastChild.remove();
    }
  } else if (logEntries.length < logCount) {
    // Log was cleared
    els.log.innerHTML = '';
    logCount = 0;
  }
}

// ---- WebSocket with auto-reconnect ----

let socket = null;
let reconnectDelay = 500;
const MAX_RECONNECT_DELAY = 15000;
let firstRenderDone = false;

function connectSocket() {
  if (socket && socket.readyState === WebSocket.OPEN) return;

  const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
  socket = new WebSocket(`${protocol}//${location.host}`);

  socket.onopen = () => {
    reconnectDelay = 500;
    if (!firstRenderDone) {
      // Skip the HTTP fetch since WS will deliver state immediately
      firstRenderDone = true;
    }
  };

  socket.onmessage = (event) => {
    try {
      render(JSON.parse(event.data));
      firstRenderDone = true;
    } catch {}
  };

  socket.onclose = () => {
    socket = null;
    els.status.textContent = 'DISCONNECTED';
    els.status.style.color = 'var(--warning)';
    scheduleReconnect();
  };

  socket.onerror = () => {
    socket?.close();
  };
}

function scheduleReconnect() {
  const delay = reconnectDelay;
  reconnectDelay = Math.min(reconnectDelay * 1.5, MAX_RECONNECT_DELAY);
  setTimeout(connectSocket, delay);
}

// ---- Initialization ----

// Only fetch via HTTP as fallback; WebSocket is the primary data source
async function initialFetch() {
  try {
    const res = await fetch('/api/state', { cache: 'no-store' });
    if (!res.ok) return;
    // Render only if WS hasn't arrived yet
    if (!firstRenderDone) {
      render(await res.json());
      firstRenderDone = true;
    }
  } catch {}
}

function tickClock() {
  els.wallClock.textContent = new Date().toTimeString().split(' ')[0];
}

initialFetch();
connectSocket();
tickClock();
setInterval(tickClock, 1000);
