import AppKit
import PDFKit

struct WheelItem {
    let title: String
    /// SF Symbol; nil = só texto (como as fatias de formato na roda de conversão).
    let symbol: String?
    let perform: @MainActor ([URL]) -> Void
}

/// O conteúdo de cada roda, conforme os arquivos arrastados.
@MainActor
enum Wheels {
    static func items(_ kind: WheelKind, for urls: [URL]) -> [WheelItem] {
        switch kind {
        case .conversion: conversion(urls)
        case .actions: actions(urls)
        case .tools: tools(urls)
        }
    }

    // MARK: Conversão

    private static func normalized(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpeg": "jpg"
        case "tif": "tiff"
        case "htm": "html"
        case "aif": "aiff"
        case "markdown": "md"
        default: ext.lowercased()
        }
    }

    static func targets(for url: URL) -> [String] {
        let ext = normalized(url.pathExtension)
        let list: [String] = switch FileKind(url) {
        case .image: Images.targets + (ext == "gif" ? ["mp4"] : [])
        case .video: Media.videoTargets
        case .audio: Media.audioTargets
        case .pdf: Documents.pdfTargets
        case .document: Documents.textTargets
        case .spreadsheet: Spreadsheet.targets
        case .office: Office.targets(for: ext).isEmpty && Documents.soffice != nil ? ["pdf"] : Office.targets(for: ext)
        default: []
        }
        return list.filter { $0 != ext }
    }

    private static func conversion(_ urls: [URL]) -> [WheelItem] {
        guard var common = urls.first.map(targets(for:)) else { return [] }
        for url in urls.dropFirst() {
            let set = Set(targets(for: url))
            common = common.filter(set.contains)
        }
        if common.isEmpty && Documents.soffice == nil && urls.contains(where: { FileKind($0) == .office }) {
            return [WheelItem(title: L("Precisa de conversor", "Needs converter"), symbol: "arrow.down.circle") { _ in
                Dialog.alert(L("Conversor não instalado", "Converter not installed"), L("""
                Apresentações OpenDocument (.odp) precisam do LibreOffice (gratuito, roda offline).

                Para instalar, rode no Terminal:
                brew install --cask libreoffice
                """, """
                OpenDocument presentations (.odp) need LibreOffice (free, works offline).

                To install it, run in Terminal:
                brew install --cask libreoffice
                """))
            }]
        }
        return common.map { ext in
            WheelItem(title: ext, symbol: nil) { urls in
                Job.each(L("Convertendo para \(ext.uppercased())", "Converting to \(ext.uppercased())"), urls) {
                    try convert($0, to: ext)
                }
            }
        }
    }

    nonisolated static func convert(_ src: URL, to ext: String) throws -> URL {
        switch FileKind(src) {
        case .image: ext == "mp4" ? try Media.convert(src, to: ext) : try Images.convert(src, to: ext)
        case .video, .audio: try Media.convert(src, to: ext)
        case .pdf: try Documents.fromPDF(src, to: ext)
        case .document: try Documents.convert(src, to: ext)
        case .spreadsheet: try Spreadsheet.convert(src, to: ext)
        case .office: try Office.convert(src, to: ext)
        default: throw ToolError.failed(L("Formato não suportado.", "Unsupported format."))
        }
    }

    // MARK: Ações

    private static func actions(_ urls: [URL]) -> [WheelItem] {
        let archives = urls.allSatisfy { FileKind($0) == .archive }
        return [
            WheelItem(title: "AirDrop", symbol: "dot.radiowaves.left.and.right") { urls in
                NSApp.activate()
                NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
            },
            WheelItem(title: "Float", symbol: "pin.fill") { FloatShelf.place($0) },
            WheelItem(title: L("Copiar", "Copy"), symbol: "doc.on.doc") { urls in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects(urls as [NSURL])
                HUD.shared.message(urls.count == 1 ? L("Arquivo copiado — cole com ⌘V", "File copied — paste with ⌘V")
                                                   : L("\(urls.count) arquivos copiados — cole com ⌘V", "\(urls.count) files copied — paste with ⌘V"))
            },
            WheelItem(title: L("Mover", "Move"), symbol: "folder") { urls in transfer(urls) },
            archives
                ? WheelItem(title: L("Extrair", "Extract"), symbol: "archivebox") { urls in
                    Job.each(L("Extraindo", "Extracting"), urls, Archives.extract)
                }
                : WheelItem(title: L("Compactar", "Zip"), symbol: "doc.zipper") { urls in
                    Job.all(L("Compactando", "Zipping")) { [try Archives.zip(urls)] }
                },
            WheelItem(title: L("Abrir com", "Open With"), symbol: "arrow.up.forward.app") { urls in
                guard let app = Dialog.chooseApp() else { return }
                NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            },
            WheelItem(title: L("Copiar caminho", "Copy Path"), symbol: "doc.text") { urls in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
                HUD.shared.message(urls.count == 1 ? L("Caminho copiado", "Path copied")
                                                   : L("\(urls.count) caminhos copiados", "\(urls.count) paths copied"))
            },
            WheelItem(title: "Terminal", symbol: "apple.terminal") { urls in openTerminal(urls[0]) },
        ]
    }

    private static func transfer(_ urls: [URL]) {
        guard let folder = Dialog.chooseFolder(L("Mover", "Move")) else { return }
        Job.run(L("Movendo", "Moving")) {
            var result = JobResult()
            for url in urls {
                let dest = Output.unique(in: folder, base: url.deletingPathExtension().lastPathComponent, ext: url.pathExtension)
                do {
                    try FileManager.default.moveItem(at: url, to: dest)
                    result.outputs.append(dest)
                } catch {
                    result.errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            return result
        }
    }

    private static func openTerminal(_ url: URL) {
        let folder = url.isDirectory ? url : url.deletingLastPathComponent()
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Settings.shared.terminalApp)
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Ferramentas

    private struct Tool {
        let title: String
        let symbol: String
        let kinds: Set<FileKind>
        var minCount = 1
        var maxCount = Int.max
        let perform: @MainActor ([URL]) -> Void
    }

    private static func tools(_ urls: [URL]) -> [WheelItem] {
        let kinds = Set(urls.map(FileKind.init))
        let all: [Tool] = [
            Tool(title: L("Comprimir", "Compress"), symbol: "arrow.down.right.and.arrow.up.left", kinds: [.image, .pdf, .video, .audio]) { urls in
                Job.each(L("Comprimindo", "Compressing"), urls) { url in
                    switch FileKind(url) {
                    case .image: try Images.compress(url)
                    case .pdf: try Documents.compressPDF(url)
                    default: try Media.compress(url)
                    }
                }
            },
            Tool(title: L("Metadados", "Metadata"), symbol: "tag", kinds: [.image, .pdf, .video, .audio]) { urls in
                Job.each(L("Removendo metadados", "Removing metadata"), urls) { url in
                    switch FileKind(url) {
                    case .image: try Images.stripMetadata(url)
                    case .pdf: try Documents.stripMetadata(url)
                    default: try Media.stripMetadata(url)
                    }
                }
            },
            Tool(title: L("Anotar", "Annotate"), symbol: "pencil.tip.crop.circle", kinds: [.image], maxCount: 1) { urls in
                ImageEditor.open(urls[0], mode: .annotate)
            },
            Tool(title: L("Tarja", "Redact"), symbol: "eye.slash", kinds: [.image], maxCount: 1) { urls in
                ImageEditor.open(urls[0], mode: .redact)
            },
            Tool(title: L("Fundo", "Background"), symbol: "person.crop.rectangle", kinds: [.image]) { urls in
                Prompts.background(urls)
            },
            Tool(title: L("Colagem", "Collage"), symbol: "square.grid.2x2", kinds: [.image], minCount: 2) { urls in
                Prompts.collage(urls)
            },
            Tool(title: L("Tamanho", "Resize"), symbol: "arrow.up.left.and.arrow.down.right", kinds: [.image]) { urls in
                Prompts.resize(urls)
            },
            Tool(title: L("Organizar", "Organize"), symbol: "square.grid.2x2", kinds: [.pdf], maxCount: 1) { urls in
                PDFOrganizer.open(urls[0])
            },
            Tool(title: L("Separar", "Split"), symbol: "rectangle.split.2x1", kinds: [.pdf]) { urls in
                Job.each(L("Separando páginas", "Splitting pages"), urls, Documents.split)
            },
            Tool(title: L("Juntar", "Merge"), symbol: "doc.on.doc.fill", kinds: [.image, .pdf], minCount: 2) { urls in
                Job.all(L("Juntando em PDF", "Merging into PDF")) {
                    let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                    let out = Output.unique(in: Output.directory(for: sorted[0]), base: L("Combinado", "Combined"), ext: "pdf")
                    try Images.toPDF(sorted, out: out)
                    return [out]
                }
            },
            Tool(title: L("Ler QR", "Read QR"), symbol: "qrcode.viewfinder", kinds: [.image, .pdf]) { urls in Prompts.readCodes(urls) },
            Tool(title: L("Girar", "Rotate"), symbol: "rotate.right", kinds: [.image]) { urls in
                Job.each(L("Girando", "Rotating"), urls, Images.rotate)
            },
            Tool(title: L("Cortar", "Trim"), symbol: "timeline.selection", kinds: [.video, .audio], maxCount: 1) { urls in
                TrimWindow.open(urls[0], mode: .trim)
            },
            Tool(title: L("Velocidade", "Speed"), symbol: "gauge.with.dots.needle.67percent", kinds: [.video, .audio]) { urls in
                Prompts.speed(urls)
            },
            Tool(title: "Bleep", symbol: "speaker.badge.exclamationmark", kinds: [.video, .audio], maxCount: 1) { urls in
                TrimWindow.open(urls[0], mode: .bleep)
            },
            Tool(title: L("Volume", "Volume"), symbol: "speaker.wave.2", kinds: [.video, .audio]) { urls in
                Job.each(L("Normalizando volume", "Normalizing volume"), urls, Media.normalize)
            },
            Tool(title: L("Sem áudio", "Mute"), symbol: "speaker.slash", kinds: [.video]) { urls in
                Job.each(L("Removendo áudio", "Removing audio"), urls, Media.removeAudio)
            },
            Tool(title: L("Canais", "Channels"), symbol: "headphones", kinds: [.audio, .video]) { urls in Prompts.channels(urls) },
            Tool(title: L("Silêncio", "Silence"), symbol: "waveform.badge.minus", kinds: [.audio]) { urls in
                Job.each(L("Cortando silêncio", "Trimming silence"), urls, Media.trimSilence)
            },
            Tool(title: L("Visualizar", "Visualize"), symbol: "waveform", kinds: [.audio]) { urls in Prompts.visualizer(urls) },
        ]
        return all
            .filter { kinds.isSubset(of: $0.kinds) && (($0.minCount)...($0.maxCount)).contains(urls.count) }
            .map { WheelItem(title: $0.title, symbol: $0.symbol, perform: $0.perform) }
    }
}
