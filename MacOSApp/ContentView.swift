import SwiftUI
import WebKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showingSettings = false

    var body: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width > 1100
            Group {
                if wide {
                    wideLayout
                } else {
                    compactLayout
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 640, maxHeight: .infinity)
        .sheet(isPresented: $showingSettings) {
            SettingsView().environmentObject(model)
        }
    }

    private var wideLayout: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 320)
            Divider()
            centerPanel
                .frame(minWidth: 420, maxWidth: .infinity)
            Divider()
            rightPanel
                .frame(minWidth: 300, idealWidth: 360, maxWidth: 420)
        }
    }

    private var compactLayout: some View {
        ScrollView {
            VStack(spacing: 16) {
                sidebar
                centerPanel
                rightPanel
            }
            .padding()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerBar
            panel(title: "Connections") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(model.connections.enumerated()), id: \.element.id) { index, connection in
                        SidebarItemRow(
                            title: connection.name,
                            subtitle: "\(connection.host):\(connection.port)",
                            isSelected: index == model.selectedConnectionIndex
                        ) {
                            model.selectedConnectionIndex = index
                        }
                    }
                    Button("Add Connection") { model.addConnection() }
                }
            }

            panel(title: "Pages") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
                        SidebarItemRow(
                            title: page.name,
                            subtitle: "\(page.buttons.count) buttons",
                            isSelected: index == model.selectedPageIndex
                        ) {
                            model.selectedPageIndex = index
                        }
                    }
                    Button("Add Page") { model.addPage() }
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("QLab OSC")
                .font(.title2.bold())
            Text("Bonjour discovery, TCP feedback, optional workspace")
                .foregroundStyle(.secondary)
        }
    }

    private var centerPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            topBanner
            if let page = currentPage {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
                    ForEach(page.buttons) { action in
                        Button {
                            model.trigger(action)
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(action.title)
                                    .font(.headline)
                                Text(action.oscAddress)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(action.message)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
                            .padding(14)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                emptyState
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var topBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(currentPage?.name ?? "No Page Selected")
                .font(.largeTitle.bold())
            Text("Current cue, next cue, timecode, countdown, and remote control")
                .foregroundStyle(.secondary)
            WrappingButtons {
                Button("Settings") { showingSettings = true }
                Button(model.isRunning ? "Stop Service" : "Start Service") {
                    model.isRunning ? model.stop() : model.start()
                }
                Button("Test Connection") { model.testSelectedProfile() }
                Button("Open Dashboard") {
                    if let url = model.serverURL { NSWorkspace.shared.open(url) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("Select a page on the left")
                .font(.headline)
            Text("Pages hold your control buttons.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusCard
            connectionSettingsCard
            monitorCard
            logsCard
            controlRow
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusCard: some View {
        panel(title: "Status") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Service: \(model.serviceStatus)")
                Text("Web Port: \(model.config.webPort)")
                Text("QLab: \(model.selectedProfile.host):\(model.selectedProfile.port)")
                Text("Protocol: \(model.config.useTCP ? "TCP feedback" : "UDP")")
                Text("Probe: \(model.connectionProbeStatus)")
                Text("Workspace: \(model.selectedProfile.workspace.isEmpty ? "Auto / current workspace" : model.selectedProfile.workspace)")
                Text("Bonjour: \(model.discoveredQLabServices.count) service(s)")
            }
        }
    }

    private var connectionSettingsCard: some View {
        panel(title: "Connection Settings") {
            VStack(alignment: .leading, spacing: 12) {
                settingField("Dashboard Port", value: binding(\.webPort))
                settingField("OSC Feedback Port", value: binding(\.oscListenPort))
                settingField("QLab Host", value: profileBinding(\.host))
                settingField("QLab Port", value: profileNumberBinding(\.port))
                workspaceField
                settingField("Passcode", value: profileBinding(\.passcode), secure: true)
                Toggle("Use TCP feedback", isOn: binding(\.useTCP))
                Toggle("Open dashboard on start", isOn: binding(\.openBrowserOnStart))
                HStack(spacing: 10) {
                    Button("Save Settings") { model.saveConfig() }
                    Button("Restart Service") { model.restart() }
                }
            }
        }
    }

    private var monitorCard: some View {
        panel(title: "Live Monitor") {
            VStack(alignment: .leading, spacing: 12) {
                monitorRow("Current Cue", value: model.latestRemoteState.currentCueName)
                monitorRow("Current Number", value: model.latestRemoteState.currentCueNumber)
                monitorRow("Next Cue", value: model.latestRemoteState.nextCueName)
                monitorRow("Timecode", value: model.latestRemoteState.timecode)
                monitorRow("Countdown", value: model.latestRemoteState.countdown)
            }
        }
    }

    private var logsCard: some View {
        panel(title: "Logs") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(model.logs.prefix(10)), id: \.self) { log in
                    Text(log)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var controlRow: some View {
        WrappingButtons {
            Button("Restart") { model.restart() }
            Button("Stop") { model.stop() }
            Button("Quit App") { model.quitApp() }
        }
    }

    private func panel<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .windowBackgroundColor).opacity(0.65)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary, lineWidth: 1))
    }

    private func monitorRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value.isEmpty ? "-" : value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AppConfig, T>) -> Binding<T> {
        Binding(get: { model.config[keyPath: keyPath] }, set: { model.config[keyPath: keyPath] = $0 })
    }

    private func profileBinding<T>(_ keyPath: WritableKeyPath<QLabProfile, T>) -> Binding<T> {
        Binding(
            get: { model.selectedProfile[keyPath: keyPath] },
            set: {
                var profile = model.selectedProfile
                profile[keyPath: keyPath] = $0
                model.selectedProfile = profile
            }
        )
    }

    private func profileNumberBinding(_ keyPath: WritableKeyPath<QLabProfile, UInt16>) -> Binding<UInt16> {
        Binding(
            get: { model.selectedProfile[keyPath: keyPath] },
            set: {
                var profile = model.selectedProfile
                profile[keyPath: keyPath] = $0
                model.selectedProfile = profile
            }
        )
    }

    private var workspaceField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text("Workspace")
                    .foregroundStyle(.secondary)
                    .frame(width: 160, alignment: .leading)
                Picker("Workspace Mode", selection: workspaceModeBinding) {
                    Text("None").tag(WorkspaceMode.none)
                    Text("Custom").tag(WorkspaceMode.custom)
                }
                .pickerStyle(.segmented)
            }
            if model.selectedProfile.workspaceMode == .custom {
                HStack(alignment: .center) {
                    Text("Workspace ID")
                        .foregroundStyle(.secondary)
                        .frame(width: 160, alignment: .leading)
                    TextField("Optional workspace id", text: profileBinding(\.workspace))
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                Text("Workspace is optional. QLab can usually be addressed as the current workspace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 160)
            }
        }
    }

    private var workspaceModeBinding: Binding<WorkspaceMode> {
        Binding(
            get: { model.selectedProfile.workspaceMode },
            set: {
                var profile = model.selectedProfile
                profile.workspaceMode = $0
                model.selectedProfile = profile
            }
        )
    }

    private func settingField(_ label: String, value: Binding<String>, secure: Bool = false) -> some View {
        HStack(alignment: .center) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .leading)
            if secure {
                SecureField(label, text: value)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField(label, text: value)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func settingField(_ label: String, value: Binding<UInt16>) -> some View {
        HStack(alignment: .center) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 160, alignment: .leading)
            TextField(label, text: Binding(
                get: { String(value.wrappedValue) },
                set: { newValue in
                    if let parsed = UInt16(newValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        value.wrappedValue = parsed
                    }
                }
            ))
            .textFieldStyle(.roundedBorder)
        }
    }

    private var currentPage: ControlPage? {
        guard model.pages.indices.contains(model.selectedPageIndex) else { return nil }
        return model.pages[model.selectedPageIndex]
    }
}

private struct WrappingButtons<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { content }
            VStack(alignment: .leading, spacing: 10) { content }
        }
    }
}

private struct SidebarItemRow: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .fontWeight(isSelected ? .semibold : .regular)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
