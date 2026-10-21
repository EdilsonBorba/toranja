import AppKit

struct JobResult {
    var outputs: [URL] = []
    var errors: [String] = []
}

/// Executa trabalho pesado em segundo plano e mostra o progresso no HUD.
@MainActor
enum Job {
    static func each(_ title: String, _ urls: [URL], _ work: @escaping (URL) throws -> URL) {
        run(title) {
            var result = JobResult()
            for url in urls {
                do { result.outputs.append(try work(url)) }
                catch { result.errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            return result
        }
    }

    static func all(_ title: String, _ work: @escaping () throws -> [URL]) {
        run(title) {
            do { return JobResult(outputs: try work()) }
            catch { return JobResult(errors: [error.localizedDescription]) }
        }
    }

    static func run(_ title: String, _ work: @escaping () -> JobResult) {
        HUD.shared.working(title)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = work()
            Task { @MainActor in HUD.shared.finished(result) }
        }
    }
}

/// Pequeno painel no canto superior direito com o andamento e o resultado.
@MainActor
final class HUD: NSObject {
    static let shared = HUD()

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let button = NSButton(title: "", target: nil, action: nil)
    private var outputs: [URL] = []
    private var errors: [String] = []
    private var running = 0
    private var hideTask: DispatchWorkItem?
    private let content = NSView()
    private var builtAppearance: Settings.Appearance?

    /// Troca o fundo (vidro/sólido) quando a aparência muda nos Ajustes.
    private func applyBackdrop() {
        guard builtAppearance != Settings.shared.appearance else { return }
        builtAppearance = Settings.shared.appearance
        content.removeFromSuperview()
        panel.contentView = Theme.backdrop(cornerRadius: 26, content: content)
    }

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 52),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        content.translatesAutoresizingMaskIntoConstraints = true
        applyBackdrop()

        spinner.style = .spinning
        spinner.controlSize = .small
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.target = self
        button.action = #selector(buttonClicked)

        let stack = NSStackView(views: [spinner, label, button])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
    }

    func working(_ text: String) {
        running += 1
        label.stringValue = text + "…"
        spinner.isHidden = false
        spinner.startAnimation(nil)
        button.isHidden = true
        present(hideAfter: nil)
    }

    func finished(_ result: JobResult) {
        running = max(0, running - 1)
        outputs = result.outputs
        errors = result.errors
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        if errors.isEmpty {
            label.stringValue = outputs.count == 1 ? L("Pronto: ", "Done: ") + outputs[0].lastPathComponent
                                                   : L("Pronto: \(outputs.count) arquivos", "Done: \(outputs.count) files")
            button.title = L("Mostrar", "Show")
            button.isHidden = outputs.isEmpty
            Feedback.done()
            if Settings.shared.revealWhenDone && !outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
        } else {
            label.stringValue = outputs.isEmpty ? L("Não deu certo", "That didn't work")
                                                : L("\(outputs.count) ok, \(errors.count) com erro", "\(outputs.count) ok, \(errors.count) failed")
            button.title = L("Ver erro", "Details")
            button.isHidden = false
            NSSound.beep()
        }
        present(hideAfter: errors.isEmpty ? 5 : 10)
    }

    func message(_ text: String) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        button.isHidden = true
        label.stringValue = text
        present(hideAfter: 2.5)
    }

    func hide() {
        hideTask?.cancel()
        panel.orderOut(nil)
    }

    private func present(hideAfter seconds: Double?) {
        hideTask?.cancel()
        applyBackdrop()
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 16, y: frame.maxY - panel.frame.height - 12))
        }
        panel.orderFrontRegardless()
        guard let seconds else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.running == 0 else { return }
            self.panel.orderOut(nil)
        }
        hideTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: task)
    }

    @objc private func buttonClicked() {
        hide()
        if errors.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(outputs)
        } else {
            Dialog.alert(L("Alguns arquivos não foram processados", "Some files weren't processed"), errors.joined(separator: "\n\n"))
        }
    }
}
