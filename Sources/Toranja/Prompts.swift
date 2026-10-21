import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Ferramentas que pedem uma escolha antes de rodar.
@MainActor
enum Prompts {
    static func resize(_ urls: [URL]) {
        let options: [(String, Int?, Double?)] = [
            ("50%", nil, 0.5), ("25%", nil, 0.25),
            ("3840 px", 3840, nil), ("2560 px", 2560, nil), ("1920 px", 1920, nil),
            ("1280 px", 1280, nil), ("1024 px", 1024, nil), ("800 px", 800, nil), ("512 px", 512, nil),
        ]
        guard let choice = Dialog.pick(L("Redimensionar", "Resize"), L("Tamanho do lado maior:", "Longest side:"),
                                       options: options.map(\.0)) else { return }
        let (_, side, factor) = options[choice]
        Job.each(L("Redimensionando", "Resizing"), urls) { try Images.resize($0, maxSide: side, factor: factor) }
    }

    static func background(_ urls: [URL]) {
        let names = [L("Transparente (remover)", "Transparent (remove)"), L("Desfocar fundo", "Blur background"),
                     L("Branco", "White"), L("Preto", "Black"), L("Outra cor…", "Other color…"), L("Imagem…", "Image…")]
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26), pullsDown: false)
        popup.addItems(withTitles: names)
        let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 44, height: 26))
        well.color = Theme.accent
        let stack = NSStackView(views: [popup, well])
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 28)
        guard Dialog.alert(L("Fundo da imagem", "Image background"),
                           L("O objeto em destaque é detectado automaticamente.", "The main subject is detected automatically."),
                           buttons: ["OK", L("Cancelar", "Cancel")], accessory: stack) == 0 else { return }
        NSColorPanel.shared.close()
        let option: Images.Background
        switch popup.indexOfSelectedItem {
        case 0: option = .transparent
        case 1: option = .blur
        case 2: option = .color(.white)
        case 3: option = .color(.black)
        case 4: option = .color(well.color)
        default:
            guard let image = Dialog.chooseFile([.image], prompt: L("Usar", "Use")) else { return }
            option = .image(image)
        }
        Job.each(L("Trocando fundo", "Changing background"), urls) { try Images.changeBackground($0, to: option) }
    }

    static func collage(_ urls: [URL]) {
        let layouts: [(String, Images.CollageLayout)] = [
            (L("Grade", "Grid"), .grid), (L("Lado a lado", "Side by side"), .row), (L("Empilhada", "Stacked"), .column),
        ]
        guard let choice = Dialog.pick(L("Colagem", "Collage"), L("\(urls.count) imagens. Disposição:", "\(urls.count) images. Layout:"),
                                       options: layouts.map(\.0)) else { return }
        Job.all(L("Criando colagem", "Creating collage")) { [try Images.collage(urls, layout: layouts[choice].1)] }
    }

    static func speed(_ urls: [URL]) {
        let factors: [Double] = [0.25, 0.5, 0.75, 1.25, 1.5, 2, 3, 4]
        let names = factors.map { Media.speedLabel($0) }
        guard let choice = Dialog.pick(L("Velocidade", "Speed"), L("Nova velocidade:", "New speed:"), options: names, selected: 5) else { return }
        Job.each(L("Mudando velocidade", "Changing speed"), urls) { try Media.speed($0, factor: factors[choice]) }
    }

    static func channels(_ urls: [URL]) {
        let modes = Media.ChannelMode.allCases
        guard let choice = Dialog.pick(L("Canais de áudio", "Audio channels"), L("Converter para:", "Convert to:"),
                                       options: modes.map(\.title)) else { return }
        Job.each(L("Convertendo canais", "Converting channels"), urls) { try Media.channels($0, mode: modes[choice]) }
    }

    static func visualizer(_ urls: [URL]) {
        let styles = Media.VisualizerStyle.allCases
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26), pullsDown: false)
        popup.addItems(withTitles: styles.map(\.title))
        let withImage = NSButton(checkboxWithTitle: L("Usar imagem de fundo…", "Use background image…"), target: nil, action: nil)
        let stack = NSStackView(views: [popup, withImage])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 240, height: 56)
        guard Dialog.alert(L("Visualizador de áudio", "Audio visualizer"),
                           L("Cria um vídeo MP4 com a onda sonora animada.", "Creates an MP4 video with an animated waveform."),
                           buttons: ["OK", L("Cancelar", "Cancel")], accessory: stack) == 0 else { return }
        var background: URL?
        if withImage.state == .on {
            guard let image = Dialog.chooseFile([.image], prompt: L("Usar", "Use")) else { return }
            background = image
        }
        let style = styles[popup.indexOfSelectedItem]
        Job.each(L("Criando visualização", "Creating visualization"), urls) {
            try Media.visualizer($0, style: style, background: background)
        }
    }

    static func readCodes(_ urls: [URL]) {
        HUD.shared.working(L("Lendo QR codes", "Reading QR codes"))
        DispatchQueue.global(qos: .userInitiated).async {
            var codes: [String] = []
            for url in urls {
                if FileKind(url) == .pdf, let doc = PDFDocument(url: url) {
                    for i in 0..<doc.pageCount {
                        if let page = doc.page(at: i), let image = try? Documents.renderPage(page) {
                            codes += (try? Images.barcodes(in: image)) ?? []
                        }
                    }
                } else if let image = try? Images.load(url) {
                    codes += (try? Images.barcodes(in: image)) ?? []
                }
            }
            Task { @MainActor in showCodes(codes) }
        }
    }

    private static func showCodes(_ codes: [String]) {
        HUD.shared.hide()
        guard !codes.isEmpty else {
            Dialog.alert(L("Nenhum QR code encontrado", "No QR codes found"),
                         L("Não encontrei códigos nos arquivos.", "I couldn't find any codes in the files."))
            return
        }
        let link = codes.compactMap { URL(string: $0) }.first { $0.scheme?.hasPrefix("http") == true }
        let buttons = [L("Copiar", "Copy")] + (link == nil ? [] : [L("Abrir link", "Open link")]) + [L("Fechar", "Close")]
        let title = codes.count == 1 ? L("QR code encontrado", "QR code found") : L("\(codes.count) códigos encontrados", "\(codes.count) codes found")
        let choice = Dialog.alert(title, codes.joined(separator: "\n\n"), buttons: buttons)
        if choice == 0 {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(codes.joined(separator: "\n"), forType: .string)
        } else if choice == 1, let link {
            NSWorkspace.shared.open(link)
        }
    }
}
