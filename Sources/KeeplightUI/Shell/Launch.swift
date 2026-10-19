import AppKit

/// The app's entry point: an AppKit shell with an NSStatusItem and a panel, on live services.
@MainActor
public func runKeeplightApp() {
    let application = NSApplication.shared
    let delegate = AppDelegate(services: .live)
    application.delegate = delegate
    // `delegate` is weak on NSApplication.
    withExtendedLifetime(delegate) { application.run() }
}
