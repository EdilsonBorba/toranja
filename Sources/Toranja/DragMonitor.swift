import AppKit

/// Detecta, sem permissões especiais, quando arquivos estão sendo arrastados em qualquer app
/// e quando uma tecla modificadora é tocada durante o arraste.
@MainActor
final class DragMonitor {
    var onModifier: ((ModifierKey) -> Void)?
    var onDragEnd: (() -> Void)?

    private let dragPasteboard = NSPasteboard(name: .drag)
    private var timer: Timer?
    private var mouseWasDown = false
    private var changeCountAtMouseDown = 0
    private var lastFlags: NSEvent.ModifierFlags = []
    private(set) var isDraggingFiles = false

    private static let relevant: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    func start() {
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    var draggedURLs: [URL] {
        dragPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private func tick() {
        let down = NSEvent.pressedMouseButtons & 1 != 0
        let flags = NSEvent.modifierFlags.intersection(Self.relevant)

        if down && !mouseWasDown {
            changeCountAtMouseDown = dragPasteboard.changeCount
        }
        if down && !isDraggingFiles && dragPasteboard.changeCount != changeCountAtMouseDown,
           dragPasteboard.availableType(from: [.fileURL]) != nil {
            isDraggingFiles = true
            // Teclas já seguradas antes do arraste não contam como toque.
            lastFlags = flags
        }
        if !down && mouseWasDown && isDraggingFiles {
            isDraggingFiles = false
            onDragEnd?()
        }
        mouseWasDown = down

        guard isDraggingFiles else { return }
        let pressed = flags.subtracting(lastFlags)
        lastFlags = flags
        if let key = ModifierKey.allCases.first(where: { pressed.contains($0.flag) }) {
            onModifier?(key)
        }
    }
}
