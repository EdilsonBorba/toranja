import AppKit
import ServiceManagement

enum Language: String, CaseIterable {
    case system, portuguese, english

    var title: String {
        switch self {
        case .system: L("Automático (sistema)", "Automatic (system)")
        case .portuguese: "Português"
        case .english: "English"
        }
    }
}

/// Texto no idioma escolhido: L("Português", "English").
func L(_ pt: String, _ en: String) -> String {
    switch Settings.shared.language {
    case .portuguese: pt
    case .english: en
    case .system: Locale.preferredLanguages.first?.hasPrefix("pt") == false ? en : pt
    }
}

enum WheelKind: String, CaseIterable {
    case conversion, actions, tools

    var title: String {
        switch self {
        case .conversion: L("Converter", "Convert")
        case .actions: L("Ações", "Actions")
        case .tools: L("Ferramentas", "Tools")
        }
    }

    var defaultModifier: ModifierKey {
        switch self {
        case .conversion: .shift
        case .actions: .control
        case .tools: .command
        }
    }
}

enum ModifierKey: String, CaseIterable {
    case shift, control, option, command

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: .shift
        case .control: .control
        case .option: .option
        case .command: .command
        }
    }

    var symbol: String {
        switch self {
        case .shift: "⇧"
        case .control: "⌃"
        case .option: "⌥"
        case .command: "⌘"
        }
    }

    var name: String {
        switch self {
        case .shift: "Shift"
        case .control: "Control"
        case .option: "Option"
        case .command: "Command"
        }
    }
}

/// Preferências guardadas no UserDefaults (thread-safe, pode ser lido pelos jobs em segundo plano).
final class Settings: @unchecked Sendable {
    static let shared = Settings()
    private let d = UserDefaults.standard

    func modifier(for kind: WheelKind) -> ModifierKey? {
        guard let raw = d.string(forKey: "modifier.\(kind.rawValue)") else { return kind.defaultModifier }
        return ModifierKey(rawValue: raw)
    }

    /// Atribui a tecla à roda; se outra roda já usava essa tecla, as duas trocam.
    func setModifier(_ key: ModifierKey?, for kind: WheelKind) {
        let previous = modifier(for: kind)
        if let key {
            for other in WheelKind.allCases where other != kind && modifier(for: other) == key {
                d.set(previous?.rawValue ?? "none", forKey: "modifier.\(other.rawValue)")
            }
        }
        d.set(key?.rawValue ?? "none", forKey: "modifier.\(kind.rawValue)")
    }

    func wheel(for key: ModifierKey) -> WheelKind? {
        WheelKind.allCases.first { modifier(for: $0) == key }
    }

    var language: Language {
        get { Language(rawValue: d.string(forKey: "language") ?? "") ?? .system }
        set { d.set(newValue.rawValue, forKey: "language") }
    }

    var feedback: Bool {
        get { d.object(forKey: "feedback") as? Bool ?? true }
        set { d.set(newValue, forKey: "feedback") }
    }

    enum Appearance: String, CaseIterable { case glass, solid }
    var appearance: Appearance {
        get { Appearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .glass }
        set { d.set(newValue.rawValue, forKey: "appearance") }
    }

    enum FloatBehavior: String, CaseIterable { case newFloat, existing }
    var floatBehavior: FloatBehavior {
        get { FloatBehavior(rawValue: d.string(forKey: "floatBehavior") ?? "") ?? .newFloat }
        set { d.set(newValue.rawValue, forKey: "floatBehavior") }
    }

    /// Bundle id do app de terminal usado pela ação "Terminal".
    var terminalApp: String {
        get { d.string(forKey: "terminalApp") ?? "com.apple.Terminal" }
        set { d.set(newValue, forKey: "terminalApp") }
    }

    /// Pasta fixa para os resultados (nil = ao lado do original).
    var outputFolder: URL? {
        get { d.string(forKey: "outputFolder").map { URL(fileURLWithPath: $0) } }
        set { d.set(newValue?.path, forKey: "outputFolder") }
    }

    var revealWhenDone: Bool {
        get { d.bool(forKey: "revealWhenDone") }
        set { d.set(newValue, forKey: "revealWhenDone") }
    }

    // MARK: Formatos

    enum Quality: String, CaseIterable {
        case maximum, balanced, compact
        var value: Double { switch self { case .maximum: 0.95; case .balanced: 0.85; case .compact: 0.7 } }
    }

    /// Qualidade usada ao converter PARA este formato de imagem.
    func quality(for ext: String) -> Quality {
        Quality(rawValue: d.string(forKey: "quality.\(ext)") ?? "") ?? .balanced
    }
    func setQuality(_ q: Quality, for ext: String) { d.set(q.rawValue, forKey: "quality.\(ext)") }

    /// Manter EXIF/GPS ao converter PARA este formato.
    func preserveMetadata(for ext: String) -> Bool { d.object(forKey: "metadata.\(ext)") as? Bool ?? true }
    func setPreserveMetadata(_ on: Bool, for ext: String) { d.set(on, forKey: "metadata.\(ext)") }

    enum Strength: String, CaseIterable { case balanced, strong }
    var imageCompression: Strength {
        get { Strength(rawValue: d.string(forKey: "imageCompression") ?? "") ?? .balanced }
        set { d.set(newValue.rawValue, forKey: "imageCompression") }
    }
    /// Qualidade JPEG/HEIC/WebP usada ao comprimir.
    var imageQuality: Double { imageCompression == .strong ? 0.45 : 0.7 }

    /// Lado maior máximo ao comprimir imagens (0 = manter dimensões).
    var compressionMaxSide: Int {
        get { d.integer(forKey: "compressionMaxSide") }
        set { d.set(newValue, forKey: "compressionMaxSide") }
    }

    var videoCompression: Strength {
        get { Strength(rawValue: d.string(forKey: "videoCompression") ?? "") ?? .balanced }
        set { d.set(newValue.rawValue, forKey: "videoCompression") }
    }

    enum AudioQuality: String, CaseIterable {
        case high, balanced, small
        var kbps: Int { switch self { case .high: 320; case .balanced: 192; case .small: 128 } }
    }
    var audioQuality: AudioQuality {
        get { AudioQuality(rawValue: d.string(forKey: "audioQuality") ?? "") ?? .balanced }
        set { d.set(newValue.rawValue, forKey: "audioQuality") }
    }

    /// Volta os ajustes de um formato (ou de compressão) ao padrão.
    func resetFormat(_ ext: String) {
        d.removeObject(forKey: "quality.\(ext)")
        d.removeObject(forKey: "metadata.\(ext)")
    }
    func resetCompression() {
        ["imageCompression", "compressionMaxSide", "targetKB", "videoCompression", "maxVideoHeight", "audioQuality"].forEach(d.removeObject)
    }

    /// Tamanho alvo em KB para compressão de imagens (0 = desligado).
    var targetKB: Int {
        get { d.integer(forKey: "targetKB") }
        set { d.set(newValue, forKey: "targetKB") }
    }

    /// Altura máxima do vídeo comprimido (0 = manter original).
    var maxVideoHeight: Int {
        get { d.object(forKey: "maxVideoHeight") as? Int ?? 1080 }
        set { d.set(newValue, forKey: "maxVideoHeight") }
    }

    var hasSeenWelcome: Bool {
        get { d.bool(forKey: "hasSeenWelcome") }
        set { d.set(newValue, forKey: "hasSeenWelcome") }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Toranja: login item: \(error)")
            }
        }
    }
}
