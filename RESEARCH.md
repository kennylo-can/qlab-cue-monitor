# Direct QLab OSC Dashboard — Architecture Research

## Current Architecture (Phase 2)

```
QLab :53000 ←→ QLabOSCClient (raw OSC send/recv, all types)
                ↓
           QLabDataProvider (subscription lifecycle)
                │  /updates 1     → push notifications
                │  /alwaysReply 1 → reply for every query
                │  /listen        → show control events (GO, stop, etc.)
                │  /forgetMeNot 1 → keepalive (no 61s disconnect)
                │  poll 1s        → /cue/active/actionElapsed, percentActionElapsed
                │
                │  Reply handler:
                │   /reply/{addr} {"status":"ok","data":"..."}
                │   → maps to CueSnapshot fields
                │
                │  Update handler:
                │   /update/workspace/{id}/cue_id/{id}
                │   → triggers refetch of active + playhead cues
                │
                │  Event handler:
                │   /qlab/event/workspace/go "1" "Intro" "abc" "Audio"
                │   → logs + triggers refetch
                ↓ delegate callbacks
          DirectQLabOrchestrator (@Published CueSnapshot)
                ↓ Combine sink / WebSocket broadcast
    ┌──────────┼──────────┐
    │           │          │
NativeDashboard   WebSocket → Browser (real-time, no polling)
```

## QLab OSC Protocol Integration

### Connection Flow (fully implemented)
1. TCP connect to QLab :53000
2. `/workspace/{id}/connect {passcode}` → authenticate
3. On "ok" reply:
   - `/alwaysReply 1` → replies for all queries
   - `/updates 1` → push notifications when cue/workspace changes
   - `/listen` → show control events (GO, stop, cue start/stop)
   - `/forgetMeNot 1` → keepalive + `/thump` every 30s
4. Initial data dump:
   - `/cue/active/name`, `/cue/active/number`, `/cue/active/type`
   - `/cue/playhead/name`, `/cue/playhead/number`, `/cue/playhead/type`
   - `/currentCueList`
5. Periodic poll (1s): `/cue/active/actionElapsed`, `/cue/active/percentActionElapsed`

### Reply Data Parsing
QLab replies are JSON strings:
```json
{"status":"ok","data":"Intro Music"}     // name, number, type
{"status":"ok","data":12.5}               // elapsed, progress
{"status":"ok","data":"1"}               // cue list number
```
Data types handled: `String`, `Double`, `Int`, auto-converted to CueSnapshot fields.

### Update Push (invalidation-based)
QLab sends `/update/workspace/{id}/cue_id/{id}` — does NOT contain the data.
We respond by re-querying `/cue/active/*` and `/cue/playhead/*`.
This avoids stale state without polling everything.

### Show Control Events
- `go` → log + refetch active/playhead after 300ms
- `stop`, `pauseAll`, `resumeAll` → log
- `cue/start`, `cue/stop` → log + refetch

## Files

| File | Purpose |
|------|---------|
| `MacOSApp/QLabOSCClient.swift` | Raw OSC transport: encode, decode, send, receive, NWConnection |
| `MacOSApp/QLabDataProvider.swift` | **NEW** — Subscription lifecycle, reply parsing, update/event handling, periodic poll |
| `MacOSApp/DirectQLabOrchestrator.swift` | **REWRITE** — Wires QLabDataProvider ↔ WebSocket bridge, ObservableObject |
| `MacOSApp/DashboardBridge.swift` | Hybrid HTTP+WebSocket server with embedded dashboard HTML/JS/CSS |
| `MacOSApp/NativeDashboardView.swift` | Pure SwiftUI dashboard (proof-of-concept, observes orchestrator via Combine) |

## Key Design Decisions

1. **Subscription-driven, not polling-driven**: Rely on `/updates` push for state changes, only poll volatile data (elapsed, progress) at 1s
2. **Invalidation model**: When QLab pushes an update notification, refetch the specific data we need (not full workspace)
3. **JSON reply parsing**: QLab wraps replies in `{"status":"ok","data":...}`, we unwrap and type-convert
4. **Sequenced startup**: auth → subscribe → dump → poll, with 200-400ms delays between phases
5. **Thread safety**: OSC queue → state queue → main queue for UI
