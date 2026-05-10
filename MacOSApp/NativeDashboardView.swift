import SwiftUI
import Combine

// MARK: - Pure SwiftUI Dashboard (no web browser needed)

struct NativeDashboardView: View {
    @StateObject private var vm = NativeDashboardVM()

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            ScrollView {
                VStack(spacing: 20) {
                    cueCards
                    timeGrid
                    eventLog
                    Spacer(minLength: 40)
                }
                .padding(24)
            }
            Divider()
            controlBar
        }
        .frame(minWidth: 800, minHeight: 600)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(vm.workspaceName)
                    .font(.title.bold())
                Text("Direct QLab OSC")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusBadge(vm.connectionState)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func statusBadge(_ state: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state == "CONNECTED" ? Color.green : state == "BAD PASSCODE" ? Color.red : Color.orange)
                .frame(width: 8, height: 8)
            Text(state)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.secondary.opacity(0.1)))
    }

    // MARK: - Cue Cards

    private var cueCards: some View {
        HStack(spacing: 16) {
            cueCard(
                label: "CURRENT CUE",
                name: vm.currentCueName,
                number: vm.currentCueNumber,
                type: vm.currentCueType,
                color: .accentColor
            )
            cueCard(
                label: "NEXT CUE",
                name: vm.nextCueName,
                number: vm.nextCueNumber,
                type: vm.nextCueType,
                color: .secondary
            )
        }
    }

    private func cueCard(label: String, name: String, number: String, type: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .tracking(1)
            Text(name.isEmpty ? "--" : name)
                .font(.system(size: 32, weight: .bold))
                .lineLimit(2)
            HStack(spacing: 8) {
                if !number.isEmpty {
                    Text(number)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(color)
                }
                if !type.isEmpty {
                    Text(type)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1)))
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary, lineWidth: 1))
    }

    // MARK: - Time Grid

    private var timeGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            timeCell(label: "TIMECODE", value: vm.timecode, mono: true)
            timeCell(label: "COUNTDOWN", value: vm.countdown, mono: true)
            timeCell(label: "ELAPSED", value: vm.elapsed, mono: true)
            progressCell(label: "PROGRESS", progress: vm.progress)
        }
    }

    private func timeCell(label: String, value: String, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .tracking(1)
            Text(value.isEmpty ? "--:--" : value)
                .font(mono ? .system(size: 20, weight: .semibold, design: .monospaced) : .title3.weight(.semibold))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1))
    }

    private func progressCell(label: String, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .tracking(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary)
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * progress / 100.0, height: 6)
                        .animation(.easeInOut(duration: 0.3), value: progress)
                }
            }
            .frame(height: 6)
            Text("\(Int(progress))%")
                .font(.title3.weight(.semibold))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1))
    }

    // MARK: - Event Log

    private var eventLog: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("EVENT LOG")
                .font(.caption)
                .foregroundStyle(.secondary)
                .tracking(1)
            if vm.logs.isEmpty {
                Text("No events yet")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(vm.logs.prefix(15)), id: \.self) { entry in
                        Text(entry)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1))
    }

    // MARK: - Control Bar

    private var controlBar: some View {
        HStack(spacing: 16) {
            Button(action: { vm.orchestrator?.go() }) {
                Label("GO", systemImage: "play.fill")
                    .frame(minWidth: 100)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button(action: { vm.orchestrator?.pause() }) {
                Label("Pause", systemImage: "pause.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button(action: { vm.orchestrator?.stop() }) {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button(action: { vm.orchestrator?.resume() }) {
                Label("Resume", systemImage: "forward.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button(action: { vm.orchestrator?.panic() }) {
                Label("Panic", systemImage: "exclamationmark.triangle.fill")
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .controlSize(.large)

            Spacer()

            Button(action: { vm.restart() }) {
                Label("Reconnect", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - ViewModel

final class NativeDashboardVM: ObservableObject {
    @Published var currentCueName = ""
    @Published var currentCueNumber = ""
    @Published var currentCueType = ""
    @Published var nextCueName = ""
    @Published var nextCueNumber = ""
    @Published var nextCueType = ""
    @Published var timecode = "--:--:--:--"
    @Published var countdown = "--:--"
    @Published var elapsed = "--:--"
    @Published var progress: Double = 0
    @Published var connectionState = "WAITING FOR QLAB"
    @Published var workspaceName = "QLab Dashboard"
    @Published var logs: [String] = []

    var orchestrator: DirectQLabOrchestrator?
    private var cancellables = Set<AnyCancellable>()

    func start() {
        let config = AppConfig.load()
        let profile = config.profiles.first ?? QLabProfile(name: "Default", host: "127.0.0.1", port: 53000, passcode: "")
        workspaceName = profile.workspace.isEmpty ? "QLab Dashboard" : profile.workspace

        let orch = DirectQLabOrchestrator(
            host: profile.host,
            port: profile.port,
            useTCP: config.useTCP,
            passcode: profile.passcode,
            workspace: profile.workspace,
            webPort: config.webPort
        )
        orchestrator = orch

        orch.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snap in
                self?.currentCueName = snap.currentCueName
                self?.currentCueNumber = snap.currentCueNumber
                self?.currentCueType = snap.currentCueType
                self?.nextCueName = snap.nextCueName
                self?.nextCueNumber = snap.nextCueNumber
                self?.nextCueType = snap.nextCueType
                self?.timecode = snap.timecode
                self?.countdown = snap.countdown
                self?.elapsed = snap.elapsed
                self?.progress = snap.progress
            }
            .store(in: &cancellables)

        orch.$connectionState
            .receive(on: DispatchQueue.main)
            .assign(to: \.connectionState, on: self)
            .store(in: &cancellables)

        orch.$logs
            .receive(on: DispatchQueue.main)
            .assign(to: \.logs, on: self)
            .store(in: &cancellables)

        orch.start()
    }

    func stop() {
        cancellables.removeAll()
        orchestrator?.stop()
        orchestrator = nil
    }

    func restart() {
        stop()
        start()
    }
}
