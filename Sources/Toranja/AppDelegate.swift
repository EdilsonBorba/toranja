import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = DragMonitor()
    private let wheel = WheelController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateOldDefaults()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Theme.statusIcon()
        statusItem.button?.toolTip = "Toranja"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        monitor.onModifier = { [weak self] key in self?.modifierTapped(key) }
        monitor.onDragEnd = { [weak self] in self?.wheel.hide() }
        monitor.start()

        if !Settings.shared.hasSeenWelcome {
            Settings.shared.hasSeenWelcome = true
            showHelp()
        }
    }

    private func modifierTapped(_ key: ModifierKey) {
        guard let kind = Settings.shared.wheel(for: key) else { return }
        // Tocar a mesma tecla de novo fecha a roda e devolve o arraste normal.
        if wheel.currentKind == kind {
            wheel.hide()
            return
        }
        let urls = monitor.draggedURLs
        guard !urls.isEmpty else { return }
        wheel.show(kind, urls: urls)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = Settings.shared

        let ready = NSMenuItem(title: L("Toranja está pronto", "Toranja is ready"), action: nil, keyEquivalent: "")
        ready.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
        ready.isEnabled = false
        menu.addItem(ready)
        // Lembrete das teclas: converter · ferramentas · ações.
        let keys = [WheelKind.conversion, .tools, .actions].compactMap { kind in
            settings.modifier(for: kind).map { "\($0.symbol): \(kind.title)" }
        }.joined(separator: " · ")
        let hint = NSMenuItem(title: keys, action: nil, keyEquivalent: "")
        hint.isEnabled = false
        hint.indentationLevel = 1
        menu.addItem(hint)

        menu.addItem(.separator())
        let prefs = action(L("Ajustes…", "Settings…"), #selector(showSettings))
        prefs.keyEquivalent = ","
        prefs.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(prefs)
        let float = action(L("Mostrar Float", "Show Float"), #selector(showFloat))
        float.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)
        menu.addItem(float)
        let help = action(L("Como usar…", "Getting Started…"), #selector(showHelp))
        help.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        menu.addItem(help)
        menu.addItem(action(L("Sobre o Toranja", "About Toranja"), #selector(showAbout)))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Sair do Toranja", "Quit Toranja"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func showSettings() { SettingsWindow.show() }
    @objc private func showAbout() { SettingsWindow.show(tab: .about) }
    @objc private func showFloat() { FloatShelf.showAll() }

    @objc private func showHelp() {
        let s = Settings.shared
        func key(_ kind: WheelKind) -> String { s.modifier(for: kind).map { "\($0.symbol) \($0.name)" } ?? L("(desligada)", "(off)") }
        Dialog.alert(L("Bem-vindo ao Toranja 🍊", "Welcome to Toranja 🍊"), L("""
        1. Comece a arrastar um ou mais arquivos (do Finder, da mesa, de qualquer app).
        2. Sem soltar, toque uma tecla:

        \(key(.conversion)) — Converter (JPG, PNG, PDF, MP4, MP3, DOCX, EPUB…)
        \(key(.actions)) — Ações (AirDrop, Float, copiar, mover, Terminal…)
        \(key(.tools)) — Ferramentas (comprimir, anotar, tarja, fundo, cortar, PDF…)

        3. Solte o arquivo na fatia desejada. O resultado aparece ao lado do original.

        Toque a mesma tecla de novo para fechar a roda. Tudo roda localmente, sem internet.
        """, """
        1. Start dragging one or more files (from Finder, the desktop, any app).
        2. Without letting go, tap a key:

        \(key(.conversion)) — Convert (JPG, PNG, PDF, MP4, MP3, DOCX, EPUB…)
        \(key(.actions)) — Actions (AirDrop, Float, copy, move, Terminal…)
        \(key(.tools)) — Tools (compress, annotate, redact, background, trim, PDF…)

        3. Drop the file on a slice. The result is saved next to the original.

        Tap the same key again to close the wheel. Everything runs locally, offline.
        """))
    }

    /// Até a 1.3 o app se chamava local.borba.Toranja; traz os ajustes antigos uma única vez.
    private func migrateOldDefaults() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedOldDefaults") else { return }
        for (key, value) in d.persistentDomain(forName: "local.borba.Toranja") ?? [:] where d.object(forKey: key) == nil {
            d.set(value, forKey: key)
        }
        d.set(true, forKey: "migratedOldDefaults")
    }
}
