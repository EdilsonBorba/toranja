import AppKit
import UniformTypeIdentifiers

enum ToolError: LocalizedError {
    case failed(String)
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): message
        case .missing(let tool): L("Ferramenta não encontrada: \(tool). Instale com: brew install \(tool)",
                                   "Tool not found: \(tool). Install it with: brew install \(tool)")
        }
    }
}

enum Shell {
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin"]

    /// Primeiro as ferramentas que vêm dentro do app (ffmpeg, ffprobe), depois as do sistema.
    static func find(_ name: String) -> String? {
        if let bundled = AppResources.url("Bin/\(name)"), FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }
        return searchPaths.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String], cwd: URL? = nil) throws -> String {
        guard let path = tool.hasPrefix("/") ? tool : find(tool) else { throw ToolError.missing(tool) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ToolError.failed(String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(400)))
        }
        return text
    }
}

/// Nomes de saída: sempre ao lado do original, nunca sobrescreve.
enum Output {
    static func unique(in dir: URL, base: String, ext: String) -> URL {
        func make(_ name: String) -> URL {
            ext.isEmpty ? dir.appendingPathComponent(name) : dir.appendingPathComponent(name).appendingPathExtension(ext)
        }
        var url = make(base)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = make("\(base) \(n)")
            n += 1
        }
        return url
    }

    /// Onde os resultados são salvos: ao lado do original ou na pasta escolhida nos Ajustes.
    static func directory(for src: URL) -> URL {
        if let folder = Settings.shared.outputFolder, folder.isDirectory { return folder }
        return src.deletingLastPathComponent()
    }

    static func url(for src: URL, ext: String, suffix: String? = nil) -> URL {
        var base = src.deletingPathExtension().lastPathComponent
        if let suffix { base += " (\(suffix))" }
        return unique(in: directory(for: src), base: base, ext: ext)
    }

    static func folder(for src: URL, suffix: String) throws -> URL {
        let url = url(for: src, ext: "", suffix: suffix)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    static func notSmaller(_ out: URL, than src: URL) throws {
        guard size(out) >= size(src) else { return }
        try? FileManager.default.removeItem(at: out)
        throw ToolError.failed(L("Já está otimizado: a versão comprimida não ficou menor.",
                                 "Already optimized: the compressed version wasn't smaller."))
    }
}

enum FileKind: Hashable {
    case image, video, audio, pdf, document, spreadsheet, office, archive, folder, other

    init(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        if isDir && !["rtfd", "pages", "key", "numbers", "app"].contains(ext) { self = .folder; return }
        if Documents.textExts.contains(ext) { self = .document; return }
        if Spreadsheet.exts.contains(ext) { self = .spreadsheet; return }
        if Documents.officeExts.contains(ext) { self = .office; return }
        if Archives.exts.contains(ext) { self = .archive; return }
        guard let type = UTType(filenameExtension: ext) else { self = .other; return }
        if type.conforms(to: .pdf) { self = .pdf }
        else if type.conforms(to: .image) { self = .image }
        else if type.conforms(to: .audio) { self = .audio }
        else if type.conforms(to: .movie) || type.conforms(to: .video) { self = .video }
        else { self = .other }
    }
}

enum Theme {
    /// Cor de toranja (rosa-coral).
    static let accent = NSColor(srgbRed: 0.98, green: 0.42, blue: 0.38, alpha: 1)
    /// Fatias da roda: azul-ardósia escuro, como no vidro do macOS.
    static let slice = NSColor(srgbRed: 0.10, green: 0.14, blue: 0.22, alpha: 1)
    static let glassTint = NSColor(srgbRed: 0.16, green: 0.28, blue: 0.46, alpha: 0.35)
    /// Fundo do estilo "Sólido" da roda.
    static let solidDisc = NSColor(srgbRed: 0.17, green: 0.21, blue: 0.28, alpha: 0.97)

    /// Fundo de vidro (macOS 26) ou sólido, conforme Ajustes → Aparência.
    @MainActor
    static func backdrop(cornerRadius: CGFloat, tint: NSColor? = nil, solid: NSColor = .windowBackgroundColor, content: NSView? = nil) -> NSView {
        if Settings.shared.appearance == .glass {
            if #available(macOS 26, *) {
                let glass = NSGlassEffectView()
                glass.cornerRadius = cornerRadius
                glass.tintColor = tint
                glass.contentView = content
                return glass
            }
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            return rounded(blur, cornerRadius, content)
        }
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = solid.cgColor
        return rounded(view, cornerRadius, content)
    }

    @MainActor
    private static func rounded(_ view: NSView, _ radius: CGFloat, _ content: NSView?) -> NSView {
        view.wantsLayer = true
        view.layer?.cornerRadius = radius
        view.layer?.masksToBounds = true
        if let content {
            content.frame = view.bounds
            content.autoresizingMask = [.width, .height]
            view.addSubview(content)
        }
        return view
    }

    /// Ícone da barra de menus: uma fatia de toranja desenhada como template.
    static func statusIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let c = NSPoint(x: rect.midX, y: rect.midY)
            NSColor.black.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 1.6
            ring.stroke()
            NSColor.black.setFill()
            let segments = 8
            for i in 0..<segments {
                let mid = CGFloat(i) * 360 / CGFloat(segments)
                let wedge = NSBezierPath()
                wedge.move(to: c)
                wedge.appendArc(withCenter: c, radius: 5.6, startAngle: mid - 17, endAngle: mid + 17)
                wedge.close()
                wedge.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Sons próprios do Toranja (Resources/Sounds) e vibração do trackpad.
@MainActor
enum Feedback {
    private static var cache: [String: NSSound] = [:]

    private static func play(_ name: String, volume: Float) {
        guard Settings.shared.feedback else { return }
        let sound: NSSound? = cache[name] ?? {
            guard let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Sounds") else { return nil }
            let s = NSSound(contentsOf: url, byReference: true)
            cache[name] = s
            return s
        }()
        guard let sound else { return }
        sound.stop()
        sound.volume = volume
        sound.play()
    }

    static func hover() {
        guard Settings.shared.feedback else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        play("hover", volume: 0.35)
    }

    static func open() { play("open", volume: 0.3) }
    static func done() { play("done", volume: 0.35) }
}

@MainActor
enum Dialog {
    @discardableResult
    static func alert(_ title: String, _ text: String, buttons: [String] = ["OK"], accessory: NSView? = nil) -> Int {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        buttons.forEach { alert.addButton(withTitle: $0) }
        alert.accessoryView = accessory
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    static func chooseFolder(_ prompt: String) -> URL? {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFile(_ types: [UTType], prompt: String) -> URL? {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseApp() -> URL? {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = L("Abrir", "Open")
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Mostra um menu de opções e devolve o índice escolhido.
    static func pick(_ title: String, _ text: String, options: [String], selected: Int = 0) -> Int? {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26), pullsDown: false)
        popup.addItems(withTitles: options)
        popup.selectItem(at: selected)
        guard alert(title, text, buttons: ["OK", L("Cancelar", "Cancel")], accessory: popup) == 0 else { return nil }
        return popup.indexOfSelectedItem
    }
}

/// Apps de terminal conhecidos; os Ajustes mostram só os instalados.
enum Terminals {
    static let known: [(name: String, id: String)] = [
        ("Terminal", "com.apple.Terminal"), ("iTerm", "com.googlecode.iterm2"), ("Ghostty", "com.mitchellh.ghostty"),
        ("Warp", "dev.warp.Warp-Stable"), ("WezTerm", "com.github.wez.wezterm"), ("kitty", "net.kovidgoyal.kitty"),
        ("Alacritty", "org.alacritty"),
    ]

    static var installed: [(name: String, id: String)] {
        known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    }
}

extension URL {
    var isDirectory: Bool { (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
}
