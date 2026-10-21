import AppKit
import AVKit

/// Corta vídeo/áudio (ou escolhe o trecho do bleep) com o recorte nativo do macOS, igual ao QuickTime.
@MainActor
final class TrimWindow: NSObject {
    enum Mode { case trim, bleep }

    private static var open: [TrimWindow] = []

    private let url: URL
    private let mode: Mode
    private let window: NSWindow
    private let playerView = AVPlayerView()

    static func open(_ url: URL, mode: Mode) {
        let trim = TrimWindow(url: url, mode: mode)
        open.append(trim)
        trim.show()
    }

    private init(url: URL, mode: Mode) {
        self.url = url
        self.mode = mode
        let isAudio = FileKind(url) == .audio
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: isAudio ? 200 : 500),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = (mode == .trim ? L("Cortar", "Trim") : "Bleep") + " — " + url.lastPathComponent
        window.isReleasedWhenClosed = false
        window.delegate = self

        playerView.player = AVPlayer(url: url)
        playerView.controlsStyle = .inline
        let hint = NSTextField(wrappingLabelWithString: mode == .trim
            ? L("Arraste as alças amarelas até o trecho que quer manter e confirme.",
                "Drag the yellow handles to the part you want to keep, then confirm.")
            : L("Arraste as alças amarelas até o trecho que vai receber o bipe e confirme.",
                "Drag the yellow handles over the part that should be bleeped, then confirm."))
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [hint, playerView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        window.contentView = stack
    }

    private func show() {
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        beginTrimming(attempt: 0)
    }

    /// O recorte só fica disponível quando o arquivo termina de carregar.
    private func beginTrimming(attempt: Int) {
        guard playerView.canBeginTrimming else {
            if attempt < 40 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.beginTrimming(attempt: attempt + 1) }
            } else {
                Dialog.alert(L("Não foi possível abrir o recorte", "Couldn't start trimming"),
                             L("O macOS não consegue recortar este formato. Converta para MP4 ou M4A primeiro.",
                               "macOS can't trim this format. Convert it to MP4 or M4A first."))
                window.close()
            }
            return
        }
        playerView.beginTrimming { [weak self] result in
            MainActor.assumeIsolated { self?.finish(result) }
        }
    }

    private func finish(_ result: AVPlayerViewTrimResult) {
        guard result == .okButton, let item = playerView.player?.currentItem else {
            window.close()
            return
        }
        let duration = item.duration.seconds
        let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime.seconds : 0
        let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime.seconds : duration
        window.close()
        guard end > start else { return }
        switch mode {
        case .trim:
            if start < 0.05 && abs(end - duration) < 0.05 {
                HUD.shared.message(L("Nada foi cortado", "Nothing was trimmed"))
                return
            }
            Job.each(L("Cortando", "Trimming"), [url]) { try Media.trim($0, start: start, end: end) }
        case .bleep:
            Job.each(L("Aplicando bleep", "Bleeping"), [url]) { try Media.bleep($0, ranges: [(start, end)]) }
        }
    }
}

extension TrimWindow: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        playerView.player?.pause()
        Self.open.removeAll { $0 === self }
    }
}
