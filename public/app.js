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
  els.status.style.color = connection.toUpperCase().includes('CONNECTED') ? 'var(--active)' : 'var(--standby)';

  els.workspaceName.textContent = `${state.workspaceName || 'MAIN STAGE'} · ${state.cueListName || 'Default Cue List'}`;
  els.serviceState.textContent = `${service.sourceName || 'Companion'} ${service.connected ? 'CONNECTED' : 'WAITING'}`;

  els.currentNumber.textContent = current.number || current.id || '--';
  els.currentName.textContent = current.name || 'Waiting for Companion…';
  els.currentMeta.textContent = [
    current.type ? `Type: ${current.type}` : null,
    current.id ? `ID: ${current.id}` : null,
    current.path ? `Path: ${current.path}` : null,
    current.color ? `Color: ${current.color}` : null,
    current.listName ? `List: ${current.listName}` : null,
  ].filter(Boolean).join('  ·  ') || 'No cue metadata received yet.';

  const progress = Number(state.progress ?? 0);
  els.progressBar.style.width = `${Math.max(0, Math.min(100, progress))}%`;
  els.elapsed.textContent = `ELAPSED: ${formatTime(state.elapsedSeconds ?? 0)}`;
  els.remaining.textContent = `REMAINING: ${formatTime(state.remainingSeconds ?? 0)}`;

  els.nextNumber.textContent = next.number || next.id || '--';
  els.nextName.textContent = next.name || '-';
  els.nextMeta.textContent = next.preWait ? `Pre-wait: ${next.preWait}` : 'Pre-wait: --';

  els.timecode.textContent = state.timecode || '--:--:--:--';
  els.totalCues.textContent = state.totalCues ?? '-';
  els.masterVol.textContent = state.masterVol ?? '-';

  els.latestOsc.textContent = state.latestOsc ? JSON.stringify(state.latestOsc, null, 2) : '-';
  els.log.innerHTML = '';
  for (const item of state.log || []) {
    const row = document.createElement('div');
    row.className = 'log-item';
    row.innerHTML = `<span class="log-time">${new Date(item.time).toLocaleTimeString()}</span><span>${escapeHtml(item.message)}</span>`;
    els.log.appendChild(row);
  }
}

async function fetchState() {
  try {
    const res = await fetch('/api/state', { cache: 'no-store' });
    if (!res.ok) return;
    render(await res.json());
  } catch {}
}

function connectSocket() {
  const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
  const socket = new WebSocket(`${protocol}//${location.host}`);
  socket.onmessage = (event) => {
    try {
      render(JSON.parse(event.data));
    } catch {}
  };
  socket.onclose = () => {
    els.status.textContent = 'DISCONNECTED';
    els.status.style.color = 'var(--warning)';
  };
}

function tickClock() {
  els.wallClock.textContent = new Date().toTimeString().split(' ')[0];
}

fetchState();
connectSocket();
tickClock();
setInterval(tickClock, 1000);
