import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?
    var onLaunch: (() -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        onLaunch?()
    }

    func applicationWillTerminate(_ notification: Notification) {
        onTerminate?()
    }
}

@main
struct QLabOSCDashboardApp: App {
    @StateObject private var appModel = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
                .onAppear {
                    if !appModel.isRunning {
                        appModel.start()
                    }
                    appDelegate.onTerminate = { appModel.stop() }
                }
        }
        .windowResizability(.contentMinSize)
        Settings {
            SettingsView()
                .environmentObject(appModel)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit QLab OSC Dashboard") {
                    appModel.quitApp()
                }
                .keyboardShortcut("q")
            }
        }
    }
}
