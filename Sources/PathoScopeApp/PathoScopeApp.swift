import SwiftUI

@main
struct PathoScopeApp: App {
    @StateObject private var workspace = WorkspaceModel()

    var body: some Scene {
        Window("PathoScope", id: "main") {
            WorkspaceView()
                .environmentObject(workspace)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1320, height: 820)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开切片…") { workspace.showImporter = true }
                    .keyboardShortcut("o")
            }
        }
    }
}
