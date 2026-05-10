const $ = (id) => document.getElementById(id);

function formatTime(date = new Date()) {
  return date.toTimeString().split(' ')[0];
}

function parseDuration(value) {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
}

async function refresh() {
  try {
    const res = await fetch('/api/state', { cache: 'no-store' });
    const state = await res.json();
    $('workspaceName').textContent = state.workspaceName || 'QLab Workspace';
    $('currentCueName').textContent = state.currentCueName || 'Waiting...';
    $('currentCueNumber').textContent = state.currentCueNumber || '--';
    $('currentCueType').textContent = state.currentCueType || '-';
    $('nextCueName').textContent = state.nextCueName || '-';
    $('nextCueNumber').textContent = state.nextCueNumber || '--';
    $('nextCueType').textContent = state.nextCueType || '-';
    $('timecode').textContent = state.timecode || '--:--:--:--';
    $('countdown').textContent = state.countdown || '--:--';
    $('elapsed').textContent = `ELAPSED: ${state.elapsed || '--:--'}`;
    $('remaining').textContent = `REMAINING: ${state.remaining || '--:--'}`;
    $('prewait').textContent = `Pre-wait: ${state.prewait || '--.--'}s`;
    $('connectionState').textContent = state.connectionState || 'WAITING FOR QLAB';
    $('latestTime').textContent = state.latestTime || '-';
    $('status').textContent = state.connectionState || 'WAITING FOR QLAB';
    $('workspaceName').textContent = state.workspaceName || 'QLab Workspace';

    const progress = parseDuration(state.progress);
    $('progressBar').style.width = `${Math.min(100, Math.max(0, progress))}%`;
  } catch {
    $('status').textContent = 'Disconnected';
    $('connectionState').textContent = 'OFFLINE';
  }
}

setInterval(() => {
  $('wallClock').textContent = formatTime();
}, 1000);

refresh();
setInterval(refresh, 500);
