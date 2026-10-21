import AppKit
import SwiftUI

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show(tab: SettingsView.Tab = .general) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 660),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 520, height: 520)
            w.center()
            window = w
        }
        window?.title = L("Ajustes do Toranja", "Toranja Settings")
        window?.contentView = NSHostingView(rootView: SettingsView(tab: tab))
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Grupos de formatos usados nas abas Formatos e Compatibilidade.
enum FormatGroups {
    static var all: [(title: String, formats: [String])] {
        [
        (L("Imagens", "Images"), ["jpg", "png", "webp", "heic", "tiff", "svg", "avif", "bmp", "gif"]),
        (L("Vídeo", "Video"), ["mp4", "mov", "webm", "mkv"]),
        (L("Áudio", "Audio"), ["mp3", "m4a", "wav", "flac", "aiff", "opus"]),
        (L("Documentos", "Documents"), ["pdf", "docx", "pages", "txt", "md", "rtf", "html", "odt"]),
        (L("Planilhas", "Spreadsheets"), ["xlsx", "xls", "numbers", "ods", "csv", "tsv"]),
        (L("Apresentações", "Presentations"), ["pptx", "ppt", "key"]),
        ]
    }

    @MainActor
    static func targets(_ ext: String) -> [String] {
        Wheels.targets(for: URL(fileURLWithPath: "/tmp/toranja.\(ext)"))
    }

    static let lossy: Set = ["jpg", "webp", "heic", "avif"]
    static let keepsMetadata: Set = ["jpg", "png", "heic", "tiff"]
    static var images: Set<String> { Set(all[0].formats) }
    static var videos: Set<String> { Set(all[1].formats) }
    static var audios: Set<String> { Set(all[2].formats) }
}

struct SettingsView: View {
    enum Tab: CaseIterable {
        case general, formats, compatibility, output, about

        var title: String {
            switch self {
            case .general: L("Geral", "General")
            case .formats: L("Formatos", "Formats")
            case .compatibility: L("Compatibilidade", "Compatibility")
            case .output: L("Saída", "Output")
            case .about: L("Sobre", "About")
            }
        }
    }

    @State var tab: Tab
    /// Muda a cada ajuste salvo, para a tela reler os valores do UserDefaults.
    @State private var tick = 0
    @State private var selectedFormat = "jpg"
    @State private var search = ""

    private let s = Settings.shared
    private let accent = Color(nsColor: Theme.accent)

    private func bind<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: get, set: { set($0); tick += 1 })
    }

    var body: some View {
        let _ = tick
        VStack(spacing: 0) {
            tabBar.padding(.top, 10).padding(.bottom, 6)
            Group {
                switch tab {
                case .general: general
                case .formats: formats
                case .compatibility: compatibility
                case .output: output
                case .about: about
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .tint(accent)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases, id: \.self) { item in
                Button { withAnimation(.easeOut(duration: 0.15)) { tab = item } } label: {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .foregroundStyle(tab == item ? Color.white : Color.primary)
                        .background(tab == item ? accent : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
    }

    // MARK: Geral

    private func keyPicker(_ title: String, _ kind: WheelKind) -> some View {
        Picker(title, selection: bind({ s.modifier(for: kind) }, { s.setModifier($0, for: kind) })) {
            ForEach(ModifierKey.allCases, id: \.self) { key in Text("\(key.symbol)  \(key.name)").tag(Optional(key)) }
            Divider()
            Text(L("Desligada", "Off")).tag(ModifierKey?.none)
        }
    }

    private var general: some View {
        Form {
            Section(L("Aparência", "Appearance")) {
                Picker(L("Estilo", "Style"), selection: bind({ s.appearance }, { s.appearance = $0 })) {
                    Text(L("Vidro", "Glass")).tag(Settings.Appearance.glass)
                    Text(L("Sólido", "Solid")).tag(Settings.Appearance.solid)
                }
                .pickerStyle(.segmented)
                Picker(L("Idioma", "Language"), selection: bind({ s.language }, { s.language = $0 })) {
                    ForEach(Language.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section(L("Geral", "General")) {
                Toggle(L("Abrir ao iniciar sessão", "Launch at login"), isOn: bind({ s.launchAtLogin }, { s.launchAtLogin = $0 }))
                Toggle(L("Som e vibração", "Sound and haptic feedback"), isOn: bind({ s.feedback }, { s.feedback = $0 }))
            }
            Section {
                keyPicker(L("Roda de conversão", "Conversion wheel"), .conversion)
                keyPicker(L("Roda de ferramentas", "Tools wheel"), .tools)
                keyPicker(L("Roda de ações", "Actions wheel"), .actions)
            } header: {
                Text(L("Teclas de arraste", "Drag modifiers"))
            } footer: {
                Text(L("Toque a tecla escolhida enquanto arrasta arquivos.", "Tap the chosen modifier while dragging files."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker(L("Comportamento do Float", "Float behaviour"), selection: bind({ s.floatBehavior }, { s.floatBehavior = $0 })) {
                    Text(L("Criar um novo Float", "Create a new Float")).tag(Settings.FloatBehavior.newFloat)
                    Text(L("Adicionar ao Float existente", "Add to the existing Float")).tag(Settings.FloatBehavior.existing)
                }
                Picker(L("App de terminal", "Terminal app"), selection: bind({ s.terminalApp }, { s.terminalApp = $0 })) {
                    ForEach(Terminals.installed, id: \.id) { Text($0.name).tag($0.id) }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Formatos

    private var formats: some View {
        HStack(spacing: 0) {
            VStack(spacing: 6) {
                TextField(L("Buscar", "Search"), text: $search)
                    .textFieldStyle(.roundedBorder)
                List(selection: bind({ Optional(selectedFormat) }, { selectedFormat = $0 ?? selectedFormat })) {
                    ForEach(FormatGroups.all, id: \.title) { group in
                        let items = group.formats.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }
                        if !items.isEmpty {
                            Section(group.title) {
                                ForEach(items, id: \.self) { Text($0.uppercased()).tag($0) }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(width: 170)
            .padding(10)
            Divider()
            formatDetail(selectedFormat)
        }
    }

    private func formatDetail(_ ext: String) -> some View {
        let targets = FormatGroups.targets(ext)
        return Form {
            Section {
                Text(targets.isEmpty
                     ? L("Formato de saída.", "Output format.")
                     : L("Converte para: ", "Converts to: ") + targets.map { $0.uppercased() }.joined(separator: ", ") + ".")
                    .foregroundStyle(.secondary)
            } header: {
                Text(L("Ajustes de \(ext.uppercased())", "\(ext.uppercased()) Settings")).font(.title3.bold())
            }
            if FormatGroups.lossy.contains(ext) || FormatGroups.keepsMetadata.contains(ext) {
                Section(L("Ao converter para \(ext.uppercased())", "When converting to \(ext.uppercased())")) {
                    if FormatGroups.lossy.contains(ext) {
                        Picker(L("Qualidade", "Quality"), selection: bind({ s.quality(for: ext) }, { s.setQuality($0, for: ext) })) {
                            Text(L("Máxima", "Maximum")).tag(Settings.Quality.maximum)
                            Text(L("Balanceada", "Balanced")).tag(Settings.Quality.balanced)
                            Text(L("Compacta", "Compact")).tag(Settings.Quality.compact)
                        }
                    }
                    if FormatGroups.keepsMetadata.contains(ext) {
                        Toggle(L("Preservar metadados (EXIF, GPS)", "Preserve metadata (EXIF, GPS)"),
                               isOn: bind({ s.preserveMetadata(for: ext) }, { s.setPreserveMetadata($0, for: ext) }))
                    }
                    Button(L("Restaurar padrões", "Restore Defaults")) { s.resetFormat(ext); tick += 1 }
                }
            }
            if FormatGroups.images.contains(ext) {
                Section(L("Compressão de imagens", "Image compression")) {
                    Picker(L("Compressão", "Compression"), selection: bind({ s.imageCompression }, { s.imageCompression = $0 })) {
                        Text(L("Balanceada", "Balanced")).tag(Settings.Strength.balanced)
                        Text(L("Forte", "Strong")).tag(Settings.Strength.strong)
                    }
                    .pickerStyle(.segmented)
                    Picker(L("Tamanho da imagem", "Image size"), selection: bind({ s.compressionMaxSide }, { s.compressionMaxSide = $0 })) {
                        Text(L("Manter dimensões originais", "Keep original dimensions")).tag(0)
                        ForEach([3840, 2560, 1920, 1280], id: \.self) { Text(L("Até \($0) px", "Up to \($0) px")).tag($0) }
                    }
                    Picker(L("Tamanho alvo", "Target size"), selection: bind({ s.targetKB }, { s.targetKB = $0 })) {
                        Text(L("Desligado", "Off")).tag(0)
                        ForEach([(200, "200 KB"), (500, "500 KB"), (1024, "1 MB"), (2048, "2 MB")], id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Button(L("Restaurar padrões de compressão", "Restore Compression Defaults")) { s.resetCompression(); tick += 1 }
                }
            }
            if FormatGroups.videos.contains(ext) {
                Section(L("Compressão de vídeo", "Video compression")) {
                    Picker(L("Compressão", "Compression"), selection: bind({ s.videoCompression }, { s.videoCompression = $0 })) {
                        Text(L("Balanceada", "Balanced")).tag(Settings.Strength.balanced)
                        Text(L("Forte", "Strong")).tag(Settings.Strength.strong)
                    }
                    .pickerStyle(.segmented)
                    Picker(L("Altura máxima", "Maximum height"), selection: bind({ s.maxVideoHeight }, { s.maxVideoHeight = $0 })) {
                        Text("Original").tag(0)
                        ForEach([2160, 1440, 1080, 720, 480], id: \.self) { Text("\($0)p").tag($0) }
                    }
                }
            }
            if FormatGroups.audios.contains(ext) {
                Section(L("Qualidade de áudio", "Audio quality")) {
                    Picker(L("Qualidade (MP3, M4A, Opus)", "Quality (MP3, M4A, Opus)"),
                           selection: bind({ s.audioQuality }, { s.audioQuality = $0 })) {
                        Text(L("Alta · 320 kbps", "High · 320 kbps")).tag(Settings.AudioQuality.high)
                        Text(L("Balanceada · 192 kbps", "Balanced · 192 kbps")).tag(Settings.AudioQuality.balanced)
                        Text(L("Compacta · 128 kbps", "Compact · 128 kbps")).tag(Settings.AudioQuality.small)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Compatibilidade

    private var compatibility: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(FormatGroups.all, id: \.title) { group in
                    let rows = group.formats
                    let columns = orderedColumns(rows)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title).font(.headline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                                GridRow {
                                    Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary).frame(width: 64, height: 26)
                                    ForEach(columns, id: \.self) { header($0) }
                                }
                                ForEach(rows, id: \.self) { row in
                                    let targets = Set(FormatGroups.targets(row))
                                    GridRow {
                                        header(row).frame(width: 64)
                                        ForEach(columns, id: \.self) { column in
                                            Group {
                                                if column == row { Text("–").foregroundStyle(.tertiary) }
                                                else if targets.contains(column) { Image(systemName: "checkmark").foregroundStyle(accent) }
                                                else { Text("–").foregroundStyle(.quaternary) }
                                            }
                                            .font(.system(size: 11, weight: .semibold))
                                            .frame(width: 46, height: 26)
                                        }
                                    }
                                    .background(rows.firstIndex(of: row)! % 2 == 0 ? Color.primary.opacity(0.04) : .clear)
                                }
                            }
                            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
            .padding(18)
        }
    }

    private func header(_ ext: String) -> some View {
        Text(ext.uppercased()).font(.system(size: 10.5, weight: .bold)).foregroundStyle(.secondary).frame(width: 46, height: 26)
    }

    /// Colunas: os próprios formatos do grupo primeiro, depois os demais destinos possíveis.
    @MainActor
    private func orderedColumns(_ rows: [String]) -> [String] {
        var columns = rows.filter { ext in rows.contains { FormatGroups.targets($0).contains(ext) } }
        for row in rows {
            for target in FormatGroups.targets(row) where !columns.contains(target) { columns.append(target) }
        }
        return columns
    }

    // MARK: Saída

    private var output: some View {
        Form {
            Section {
                Picker(L("Salvar resultados", "Save results"), selection: bind({ s.outputFolder != nil }, { fixed in
                    if fixed { s.outputFolder = chooseFolder() ?? s.outputFolder } else { s.outputFolder = nil }
                })) {
                    Text(L("Ao lado do arquivo original", "Beside the original file")).tag(false)
                    Text(L("Numa pasta fixa", "In a fixed folder")).tag(true)
                }
                .pickerStyle(.radioGroup)
                if let folder = s.outputFolder {
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path)).resizable().frame(width: 28, height: 28)
                        VStack(alignment: .leading) {
                            Text(folder.lastPathComponent)
                            Text(folder.path).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("Escolher…", "Choose…")) { if let f = chooseFolder() { s.outputFolder = f; tick += 1 } }
                    }
                }
                Toggle(L("Mostrar no Finder ao terminar", "Reveal in Finder when done"), isOn: bind({ s.revealWhenDone }, { s.revealWhenDone = $0 }))
            } header: {
                Text(L("Onde salvar", "Where to save"))
            } footer: {
                Text(L("O Toranja nunca sobrescreve arquivos: se o nome já existe, ele cria \"nome 2\". Como não roda isolado do sistema, não precisa pedir acesso a cada pasta.",
                       "Toranja never overwrites files: if the name exists, it creates \"name 2\". It isn't sandboxed, so it doesn't need to ask for access to each folder."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Escolher", "Choose")
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: Sobre

    private var about: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 112, height: 112)
            Text("Toranja").font(.title.bold())
            Text(L("Versão ", "Version ") + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"))
                .foregroundStyle(.secondary)
            Text(L("Feito sob medida, 100% local.\nSem assinatura, sem conta, sem internet.",
                   "Made to measure, 100% local.\nNo subscription, no account, no internet."))
                .multilineTextAlignment(.center)
            let project = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Toranja")
            if FileManager.default.fileExists(atPath: project.path) {
                Button(L("Abrir pasta do projeto", "Open project folder")) { NSWorkspace.shared.open(project) }
            }
            Link(L("Ver no GitHub", "View on GitHub"), destination: URL(string: "https://github.com/EdilsonBorba/toranja")!)
            if let licenses = AppResources.url("Licenses") {
                Button(L("Licenças de terceiros", "Third-party licenses")) { NSWorkspace.shared.open(licenses) }
            }
            Spacer()
            Text(L("Usa software livre: FFmpeg (x264, LAME, Opus, libvpx, libaom, WebP), OpenJDK, Apache POI, Apache PDFBox, docx-preview, JSZip e cupertino-files.",
                   "Built on open source: FFmpeg (x264, LAME, Opus, libvpx, libaom, WebP), OpenJDK, Apache POI, Apache PDFBox, docx-preview, JSZip and cupertino-files."))
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 30).padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity)
    }
}
