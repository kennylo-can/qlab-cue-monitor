import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showAdvanced = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                gridSection {
                    field("Web Port", value: binding(\.webPort))
                    field("QLab Host", value: profileBinding(\.host))
                    field("QLab Port", value: profileNumberBinding(\.port))
                    workspaceField
                    field("Passcode", value: profileBinding(\.passcode), secure: true)
                    Toggle("Use TCP feedback", isOn: binding(\.useTCP))
                    Toggle("Open dashboard on start", isOn: binding(\.openBrowserOnStart))
                }
                discoverySection
                if showAdvanced {
                    gridSection {
                        field("Dashboard Port", value: binding(\.webPort))
                        field("OSC Feedback Port", value: binding(\.oscListenPort))
                    }
                }
                buttons
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 760, minHeight: 560)
        .onChange(of: model.config.webPort) { _ in model.scheduleSaveConfig() }
        .onChange(of: model.config.oscListenPort) { _ in model.scheduleSaveConfig() }
        .onChange(of: model.config.useTCP) { _ in model.scheduleSaveConfig() }
        .onChange(of: model.config.openBrowserOnStart) { _ in model.scheduleSaveConfig() }
        .onChange(of: model.selectedProfile.host) { _ in model.scheduleSaveConfig() }
        .onChange(of: model.selectedProfile.port) { _ in model.scheduleSaveConfig() }
        .onChange(of: model.selectedProfile.workspace) { _ in model.scheduleSaveConfig() }
        .onChange(of: model.selectedProfile.passcode) { _ in model.scheduleSaveConfig() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("QLab Settings")
                .font(.largeTitle.bold())
            Text("Companion-style single profile setup. Host, port, workspace, passcode, and TCP/UDP mode.")
                .foregroundStyle(.secondary)
        }
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Button("Save") { model.saveConfig() }
            Button("Save & Close") {
                model.saveConfig()
                dismiss()
            }
            Button(model.isRunning ? "Stop Service" : "Start Service") {
                model.isRunning ? model.stop() : model.start()
            }
            Button("Test Connection") { model.testSelectedProfile() }
            Button("Open Dashboard") {
                if !model.isRunning { model.start() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if let url = model.serverURL { NSWorkspace.shared.open(url) }
                }
            }
            Button(showAdvanced ? "Hide Advanced" : "Show Advanced") {
                showAdvanced.toggle()
            }
            Button("Close") { dismiss() }
        }
    }

    private func gridSection<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.quaternary, lineWidth: 1)
        )
    }

    private func field(_ label: String, value: Binding<String>, secure: Bool = false) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(label)
                    .frame(width: 180, alignment: .leading)
                if secure {
                    SecureField(label, text: value)
                        .textFieldStyle(.roundedBorder)
                } else {
                    TextField(label, text: value)
                        .textFieldStyle(.roundedBorder)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                    .foregroundStyle(.secondary)
                if secure {
                    SecureField(label, text: value)
                        .textFieldStyle(.roundedBorder)
                } else {
                    TextField(label, text: value)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private func field(_ label: String, value: Binding<UInt16>) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(label)
                    .frame(width: 180, alignment: .leading)
                TextField(label, text: Binding(
                    get: { String(value.wrappedValue) },
                    set: { newValue in
                        if let parsed = UInt16(newValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            value.wrappedValue = parsed
                        }
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                    .foregroundStyle(.secondary)
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
    }

    private var workspaceField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Workspace")
                    .frame(width: 180, alignment: .leading)
                Picker("Workspace Mode", selection: workspaceModeBinding) {
                    Text("None").tag(WorkspaceMode.none)
                    Text("Custom").tag(WorkspaceMode.custom)
                }
                .pickerStyle(.segmented)
            }
            if model.selectedProfile.workspaceMode == .custom {
                HStack {
                    Text("Workspace ID")
                        .frame(width: 180, alignment: .leading)
                    TextField("Optional workspace id", text: profileBinding(\.workspace))
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                Text("Workspace is optional. QLab can usually be addressed without a workspace id.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 180)
            }
        }
    }

    private var discoverySection: some View {
        gridSection {
            VStack(alignment: .leading, spacing: 10) {
                Text("Discovered QLab")
                    .font(.headline)
                if model.discoveredQLabServices.isEmpty {
                    Text("No Bonjour QLab services found yet. Make sure QLab is on the same network and publishing its OSC service.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(model.discoveredQLabServices) { service in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(service.name)
                                Text("\(service.host):\(service.port)")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                            Spacer()
                            Button("Use") {
                                model.useDiscoveredService(service)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
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
}
