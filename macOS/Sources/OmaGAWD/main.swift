import AppKit
import Carbon

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var status: NSStatusItem!
    var model: PlayerModel!
    var controller: PlayerWindow!
    var hotKey: EventHotKeyRef?
    var handler: EventHandlerRef?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let menu = NSMenu(); let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appMenu.addItem(withTitle: "Quit OmaGAWD", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); appItem.submenu = appMenu
        let editItem = NSMenuItem(); menu.addItem(editItem); let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        for (name, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] { edit.addItem(withTitle: name, action: action, keyEquivalent: key) }
        NSApp.mainMenu = menu
        if let url = Bundle.main.url(forResource: "OmaGAWD", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        model = PlayerModel(); controller = PlayerWindow(model: model)
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = status.button {
            let iconHeight: CGFloat = 16
            let image: NSImage
            if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "svg"),
               let vector = NSImage(contentsOf: url), vector.size.height > 0 {
                // Keep the SVG's proportions and let AppKit render at screen scale.
                vector.size = NSSize(width: iconHeight * vector.size.width / vector.size.height, height: iconHeight)
                image = vector
            } else {
                image = NSImage(size: NSSize(width: iconHeight, height: iconHeight))
                for name in ["MenuBarIcon", "MenuBarIcon@2x"] {
                    if let url = Bundle.main.url(forResource: name, withExtension: "png"),
                       let data = try? Data(contentsOf: url), let representation = NSBitmapImageRep(data: data) {
                        representation.size = image.size
                        image.addRepresentation(representation)
                    }
                }
            }
            // Use the system menu bar tint, including dark mode and selection.
            image.isTemplate = true
            if image.representations.isEmpty { button.title = "🦙" } else { button.image = image }
            button.toolTip = "OmaGAWD — ⌘⌥O"; button.setAccessibilityLabel("OmaGAWD"); button.target = self; button.action = #selector(toggle)
        }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let app = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { app.toggle() }; return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_O), UInt32(cmdKey | optionKey), EventHotKeyID(signature: 0x4F4D4147, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { controller.hotKeyWarning = "Command–Option–O is already in use. The menu bar button remains available."; model.message = controller.hotKeyWarning!; controller.reload() }
        controller.show(near: status.button)
        if let i = CommandLine.arguments.firstIndex(of: "--smoke-test"), CommandLine.arguments.count > i + 3 {
            Task { await smokeTest(model: model, controller: controller, fixture: CommandLine.arguments[i + 1], port: CommandLine.arguments[i + 2], report: CommandLine.arguments[i + 3]) }; return
        }
        model.start()
        if let i = CommandLine.arguments.firstIndex(of: "--test-audio"), CommandLine.arguments.indices.contains(i + 1) {
            let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            Task {
                do { let songs = try await model.local.scan([url]); model.songs = songs; model.replace(songs) }
                catch { model.report(error) }
            }
        }
    }
    @objc func toggle() { if controller.window?.isVisible == true { controller.hide() } else { controller.show(near: status.button) } }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { controller.show(near: status.button); return true }
    func applicationWillTerminate(_ notification: Notification) { if let hotKey { UnregisterEventHotKey(hotKey) }; if let handler { RemoveEventHandler(handler) }; model.shutdown() }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
