# Direct QLab OSC Research — Architecture Comparison

## Three Approaches Tested

### A. Current (Baseline): Passive OSC Listener + HTTP Polling
- OSC Receiver passively listens, pattern-matches address substrings
- HTTP server serves `/api/state` JSON
- Browser polls every 500ms via `fetch()`
- DashboardState singleton with no thread safety (data race)
- OSCSender creates new NWConnection per send

**Problems:** No `/updates` subscription → unreliable state. HTTP polling wastes bandwidth/latency. Data race. Crash-prone port parsing.

### B. WebSocket-Direct: QLab OSC Client + WebSocket Push
Files: `QLabOSCClient.swift` + `DashboardBridge.swift` + `DirectQLabOrchestrator.swift`

```
                   ┌──────────────┐
 [QLab :53000] ───┤ QLabOSCClient │── subscribe /updates, /listen, /alwaysReply
                   │ (full proto) │── send GO/Pause/Stop with /reply feedback
                   └──────┬───────┘
                          │ delegate callbacks
                   ┌──────▼──────────┐
                   │ Orchestrator     │── manage state (CueSnapshot)
                   │                  │── wire OSC ↔ WebSocket
                   └──────┬──────────┘
                          │ push state JSON
                   ┌──────▼──────────┐
                   │ WebSocket Server │── serve HTML/CSS/JS
                   │ (port :8088)     │── broadcast state to all clients
                   └──────┬──────────┘
                          │ long-lived WS
                   ┌──────▼──┐
                   │ Browser │ ── real-time DOM update (no polling)
                   └─────────┘
```

**Advantages:**
- Proper `/updates` subscription + `/reply` feedback → reliable state
- WebSocket push → zero-polling, sub-50ms latency
- Multi-client broadcast (production team on phones/tablets)
- Full OSC protocol support (int/float/bool types, JSON replies)
- `/forgetMeNot` keepalive (no 61s disconnect)
- Show control `/listen` for event stream (GO/Stop/Panic events)

### C. Pure SwiftUI Native: No Web at All
File: `NativeDashboardView.swift`

**Advantages:**
- Lowest possible latency (no serialization)
- Native macOS appearance
- No browser dependency

**Drawbacks:**
- macOS only (no phone/tablet monitoring)
- Needs a separate mechanism for remote devices if needed

---

## Recommendation: Approach B (WebSocket-Direct)

This is the best architecture because:
1. **Proper QLab OSC integration** — `/updates` subscription, `/reply` parsing, `/listen` events
2. **Real-time push** — WebSocket eliminates polling, sub-100ms updates
3. **Multi-device** — any device on the local network can monitor
4. **Clean separation** — `QLabOSCClient` is protocol-only, `Orchestrator` is wiring, `DashboardBridge` is transport
5. **Optionally add native view** — `NativeDashboardView` can coexist with the WebSocket bridge

## Files in this Research Branch

| File | Purpose |
|------|---------|
| `MacOSApp/QLabOSCClient.swift` | Full QLab OSC client: subscribe, reply, events, keepalive, all cue actions, full encoder/parser |
| `MacOSApp/DashboardBridge.swift` | Hybrid HTTP+WebSocket server: serves dashboard HTML, upgrades to WS for live push |
| `MacOSApp/DirectQLabOrchestrator.swift` | Wires QLabOSCClient ↔ WebSocket bridge, manages CueSnapshot state |
| `MacOSApp/NativeDashboardView.swift` | Pure SwiftUI dashboard proof-of-concept (no web) |

## Migration Path

1. Replace `OSCReceiver` + `DashboardState` with `QLabOSCClient`
2. Replace `HTTPServer` with `DashboardBridge` (WebSocket instead of polling)
3. Keep `AppModel` but simplify — it becomes mostly config + UI state
4. Existing `ContentView` can embed `NativeDashboardView` in center panel
5. Remote browsers connect to `http://host:8088` for the WebSocket dashboard
