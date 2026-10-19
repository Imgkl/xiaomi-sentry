import AppKit

MainActor.assumeIsolated {
    #if DEBUG
    if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
        Snapshot.run(into: CommandLine.arguments[i + 1])
        exit(0)
    }
    #endif

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Menu bar only: no Dock icon, no app menu.
    app.setActivationPolicy(.accessory)
    app.run()
}
