import AppKit
import Quartz
import QuickLookThumbnailing

/// Uma "prateleira" de vidro flutuante para estacionar arquivos e arrastá-los depois.
@MainActor
final class FloatShelf: NSObject {
    private static var floats: [FloatShelf] = []

    /// Ação "Float" da roda: cria um Float novo ou junta ao último aberto, conforme os Ajustes.
    static func place(_ urls: [URL]) {
        if Settings.shared.floatBehavior == .existing, let last = floats.last {
            last.add(urls)
        } else {
            let float = FloatShelf()
            floats.append(float)
            float.add(urls)
        }
    }

    static func showAll() {
        if floats.isEmpty { floats.append(FloatShelf()) }
        floats.forEach { $0.show() }
    }

    private var panel: NSPanel?
    private var files: [URL] = []
    private let list = NSStackView()
    private let dragAll = FileDragView()
    private let dragAllLabel = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "Float")
    private let placeholder = NSTextField(labelWithString: "")

    func add(_ urls: [URL]) {
        for url in urls where !files.contains(url) { files.append(url) }
        show()
        reload()
    }

    func remove(_ url: URL) {
        files.removeAll { $0 == url }
        reload()
    }

    func clear() {
        files.removeAll()
        reload()
    }

    func show() {
        if panel == nil { build() }
        reload()
        panel?.alphaValue = 0
        panel?.orderFrontRegardless()
        panel?.animator().alphaValue = 1
    }

    @objc private func clearClicked() { clear() }
    @objc private func closeClicked() {
        panel?.orderOut(nil)
        Self.floats.removeAll { $0 === self }
    }

    private func build() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 360),
                            styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 210, height: 220)

        let root = ShelfDropView()
        root.onDrop = { [weak self] urls in self?.add(urls) }
        let glass = Theme.backdrop(cornerRadius: 22)
        glass.frame = root.bounds
        glass.autoresizingMask = [.width, .height]
        root.addSubview(glass)
        panel.contentView = root

        title.font = .systemFont(ofSize: 13, weight: .bold)
        let clear = iconButton("trash", L("Limpar", "Clear"), #selector(clearClicked))
        let close = iconButton("xmark", L("Fechar Float (não apaga arquivos)", "Close Float without deleting files"), #selector(closeClicked))
        let header = NSStackView(views: [title, NSView(), clear, close])
        header.spacing = 6

        dragAll.urls = { [weak self] in self?.files ?? [] }
        dragAll.onDragEnded = { [weak self] in self?.pruneMissing() }
        dragAll.wantsLayer = true
        dragAll.layer?.cornerRadius = 12
        dragAll.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.9).cgColor
        dragAllLabel.font = .systemFont(ofSize: 11, weight: .bold)
        dragAllLabel.textColor = .white
        dragAllLabel.alignment = .center
        dragAllLabel.translatesAutoresizingMaskIntoConstraints = false
        dragAll.addSubview(dragAllLabel)

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document

        placeholder.stringValue = L("Solte arquivos aqui", "Drop files here")
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center

        for view in [header, dragAll, scroll, placeholder] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            dragAll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            dragAll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            dragAll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            dragAll.heightAnchor.constraint(equalToConstant: 32),
            dragAllLabel.centerXAnchor.constraint(equalTo: dragAll.centerXAnchor),
            dragAllLabel.centerYAnchor.constraint(equalTo: dragAll.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: dragAll.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            placeholder.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: 16),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        // Floats novos aparecem em cascata, para não esconder os anteriores.
        if let screen = NSScreen.main?.visibleFrame {
            let offset = CGFloat(max(0, Self.floats.count - 1) % 8) * 28
            panel.setFrameOrigin(NSPoint(x: screen.maxX - 280 - offset, y: screen.midY - 180 - offset))
        }
        self.panel = panel
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tip
        return button
    }

    private func reload() {
        guard panel != nil else { return }
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for url in files {
            let row = FileRow(url: url)
            row.onRemove = { [weak self] in self?.remove(url) }
            row.onDragEnded = { [weak self] in self?.pruneMissing() }
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        title.stringValue = files.isEmpty ? "Float" : "Float · \(files.count)"
        dragAllLabel.stringValue = (files.count == 1 ? L("ARRASTAR ARQUIVO", "DRAG FILE") : L("ARRASTAR TODOS", "DRAG ALL"))
        dragAll.isHidden = files.isEmpty
        placeholder.isHidden = !files.isEmpty
    }

    /// Arquivos movidos para fora do Float saem da lista.
    private func pruneMissing() {
        let before = files.count
        files.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        if files.count != before { reload() }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Fundo do Float: aceita arquivos soltos.
final class ShelfDropView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingSource is FileDragView ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        onDrop?(urls)
        return !urls.isEmpty
    }
}

/// Origem de arraste para um ou mais arquivos.
class FileDragView: NSView, NSDraggingSource {
    var urls: () -> [URL] = { [] }
    var onDragEnded: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDragged(with event: NSEvent) {
        let urls = urls()
        guard !urls.isEmpty else { return }
        let items = urls.enumerated().map { i, url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let offset = CGFloat(min(i, 4)) * 4
            item.setDraggingFrame(NSRect(x: offset, y: offset, width: 40, height: 40), contents: icon)
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .generic, .link] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        DispatchQueue.main.async { [weak self] in self?.onDragEnded?() }
    }
}

final class FileRow: FileDragView, QLPreviewPanelDataSource {
    let url: URL
    var onRemove: (() -> Void)?
    private let thumbnail = NSImageView()
    private var hovering = false { didSet { layer?.backgroundColor = hovering ? NSColor.labelColor.withAlphaComponent(0.08).cgColor : nil } }

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        urls = { [url] }
        wantsLayer = true
        layer?.cornerRadius = 10
        thumbnail.image = NSWorkspace.shared.icon(forFile: url.path)
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 5
        thumbnail.layer?.masksToBounds = true

        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.lineBreakMode = .byTruncatingMiddle
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let size = NSTextField(labelWithString: ByteCountFormatter.string(fromByteCount: Int64(Output.size(url)), countStyle: .file))
        size.font = .systemFont(ofSize: 10)
        size.textColor = .secondaryLabelColor
        let texts = NSStackView(views: [name, size])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1

        for view in [thumbnail, texts] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 46),
            thumbnail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            thumbnail.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: 36),
            thumbnail.heightAnchor.constraint(equalToConstant: 36),
            texts.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 10),
            texts.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = url.path
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        loadThumbnail()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func loadThumbnail() {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 72, height: 72),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async { self?.thumbnail.image = image }
        }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { NSWorkspace.shared.open(url) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: L("Abrir", "Open"), action: #selector(openFile), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Visualização Rápida", "Quick Look"), action: #selector(showQuickLook), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Mostrar no Finder", "Show in Finder"), action: #selector(reveal), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Remover do Float", "Remove from Float"), action: #selector(removeFromShelf), keyEquivalent: "").target = self
        return menu
    }

    @objc private func openFile() { NSWorkspace.shared.open(url) }
    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    @objc private func removeFromShelf() { onRemove?() }

    @objc private func showQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        NSApp.activate()
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { url as NSURL }
}
