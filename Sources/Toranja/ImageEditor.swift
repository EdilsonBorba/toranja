import AppKit
import CoreImage
import SwiftUI

enum EditorMode { case annotate, redact }

enum MarkTool: String, Identifiable {
    case arrow, rect, ellipse, pen, highlight, text, number, solid, blur

    var id: String { rawValue }

    static func tools(for mode: EditorMode) -> [MarkTool] {
        mode == .annotate ? [.arrow, .rect, .ellipse, .pen, .highlight, .text, .number] : [.solid, .blur]
    }

    var symbol: String {
        switch self {
        case .arrow: "arrow.up.right"
        case .rect: "rectangle"
        case .ellipse: "circle"
        case .pen: "scribble"
        case .highlight: "highlighter"
        case .text: "textformat"
        case .number: "1.circle"
        case .solid: "rectangle.fill"
        case .blur: "drop.halffull"
        }
    }

    var title: String {
        switch self {
        case .arrow: L("Seta", "Arrow")
        case .rect: L("Retângulo", "Rectangle")
        case .ellipse: L("Elipse", "Ellipse")
        case .pen: L("Caneta", "Pen")
        case .highlight: L("Marca-texto", "Highlighter")
        case .text: L("Texto", "Text")
        case .number: L("Numeração", "Callout")
        case .solid: L("Tarja sólida", "Solid")
        case .blur: L("Desfocar", "Blur")
        }
    }

    /// Ferramentas desenhadas arrastando de um canto ao outro.
    var isBox: Bool { [.rect, .ellipse, .solid, .blur, .arrow].contains(self) }
}

struct Mark: Identifiable {
    let id = UUID()
    var tool: MarkTool
    var points: [CGPoint]
    var color: Color
    var width: CGFloat
    var text = ""
    var number = 0

    var start: CGPoint { points.first ?? .zero }
    var end: CGPoint { points.last ?? .zero }
    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
}

@MainActor
final class EditorModel: ObservableObject {
    let url: URL
    let mode: EditorMode
    let image: CGImage
    let blurred: CGImage
    let size: CGSize

    @Published var marks: [Mark] = []
    @Published var current: Mark?
    @Published var tool: MarkTool
    @Published var color: Color = .red
    @Published var thickness: Double = 1

    static let palette: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]

    init(url: URL, mode: EditorMode) throws {
        self.url = url
        self.mode = mode
        image = try Images.load(url)
        size = CGSize(width: image.width, height: image.height)
        tool = MarkTool.tools(for: mode)[0]
        let ci = CIImage(cgImage: image)
        let soft = ci.clampedToExtent().applyingGaussianBlur(sigma: max(size.width, size.height) / 60).cropped(to: ci.extent)
        blurred = CIContext().createCGImage(soft, from: ci.extent) ?? image
    }

    private var baseWidth: CGFloat { max(2, max(size.width, size.height) / 320) }

    func begin(at p: CGPoint) {
        let number = tool == .number ? marks.filter { $0.tool == .number }.count + 1 : 0
        current = Mark(tool: tool, points: [p], color: color, width: baseWidth * thickness, number: number)
    }

    func drag(to p: CGPoint) {
        guard var mark = current else { return }
        switch mark.tool {
        case .pen, .highlight: mark.points.append(p)
        case .text, .number: mark.points = [p]
        default: mark.points = [mark.start, p]
        }
        current = mark
    }

    func end() {
        guard var mark = current else { return }
        current = nil
        if mark.tool.isBox && (mark.rect.width < 4 && mark.rect.height < 4) { return }
        if mark.tool == .text {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            guard Dialog.alert(L("Texto", "Text"), "", buttons: ["OK", L("Cancelar", "Cancel")], accessory: field) == 0,
                  !field.stringValue.isEmpty else { return }
            mark.text = field.stringValue
        }
        marks.append(mark)
    }

    func undo() { if !marks.isEmpty { marks.removeLast() } }
    func clear() { marks.removeAll() }

    static func draw(_ context: GraphicsContext, image: CGImage, blurred: CGImage, size: CGSize, marks: [Mark]) {
        var ctx = context
        let full = CGRect(origin: .zero, size: size)
        ctx.draw(Image(decorative: image, scale: 1), in: full)
        for m in marks {
            let r = m.rect
            switch m.tool {
            case .solid:
                ctx.fill(Path(r), with: .color(.black))
            case .blur:
                var clipped = ctx
                clipped.clip(to: Path(r))
                clipped.draw(Image(decorative: blurred, scale: 1), in: full)
            case .rect:
                ctx.stroke(Path(roundedRect: r, cornerRadius: m.width * 1.5), with: .color(m.color), lineWidth: m.width)
            case .ellipse:
                ctx.stroke(Path(ellipseIn: r), with: .color(m.color), lineWidth: m.width)
            case .pen, .highlight:
                var path = Path()
                path.addLines(m.points)
                let highlight = m.tool == .highlight
                ctx.stroke(path, with: .color(highlight ? m.color.opacity(0.4) : m.color),
                           style: StrokeStyle(lineWidth: highlight ? m.width * 5 : m.width, lineCap: .round, lineJoin: .round))
            case .arrow:
                let angle = atan2(m.end.y - m.start.y, m.end.x - m.start.x)
                let head = m.width * 5
                let base = CGPoint(x: m.end.x - cos(angle) * head * 0.8, y: m.end.y - sin(angle) * head * 0.8)
                var shaft = Path()
                shaft.move(to: m.start)
                shaft.addLine(to: base)
                ctx.stroke(shaft, with: .color(m.color), style: StrokeStyle(lineWidth: m.width, lineCap: .round))
                var tip = Path()
                tip.move(to: m.end)
                tip.addLine(to: CGPoint(x: m.end.x - cos(angle - 0.45) * head, y: m.end.y - sin(angle - 0.45) * head))
                tip.addLine(to: CGPoint(x: m.end.x - cos(angle + 0.45) * head, y: m.end.y - sin(angle + 0.45) * head))
                tip.closeSubpath()
                ctx.fill(tip, with: .color(m.color))
            case .text:
                ctx.draw(Text(m.text).font(.system(size: m.width * 7, weight: .bold)).foregroundColor(m.color),
                         at: m.start, anchor: .topLeading)
            case .number:
                let radius = m.width * 4.5
                ctx.fill(Path(ellipseIn: CGRect(x: m.start.x - radius, y: m.start.y - radius, width: radius * 2, height: radius * 2)),
                         with: .color(m.color))
                ctx.draw(Text("\(m.number)").font(.system(size: radius * 1.1, weight: .bold)).foregroundColor(.white),
                         at: m.start, anchor: .center)
            }
        }
    }

    func save() throws -> URL {
        let (image, blurred, size, marks) = (image, blurred, size, marks)
        let content = Canvas { ctx, _ in Self.draw(ctx, image: image, blurred: blurred, size: size, marks: marks) }
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        guard let result = renderer.cgImage else { throw ToolError.failed(L("Falha ao gerar a imagem.", "Failed to create the image.")) }
        let ext = Images.writableExt(url)
        let suffix = mode == .annotate ? L("anotado", "annotated") : L("tarjado", "redacted")
        let out = Output.url(for: url, ext: ext, suffix: suffix)
        try Images.write(result, to: out, type: Images.type(for: ext)!, quality: 0.92)
        return out
    }
}

struct EditorView: View {
    @ObservedObject var model: EditorModel
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geo in
                let scale = min(geo.size.width / model.size.width, geo.size.height / model.size.height)
                let marks = model.marks + (model.current.map { [$0] } ?? [])
                Canvas { ctx, _ in
                    ctx.scaleBy(x: scale, y: scale)
                    EditorModel.draw(ctx, image: model.image, blurred: model.blurred, size: model.size, marks: marks)
                }
                .frame(width: model.size.width * scale, height: model.size.height * scale)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let p = CGPoint(x: value.location.x / scale, y: value.location.y / scale)
                            if model.current == nil {
                                model.begin(at: CGPoint(x: value.startLocation.x / scale, y: value.startLocation.y / scale))
                            }
                            model.drag(to: p)
                        }
                        .onEnded { _ in model.end() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(18)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 2) {
                ForEach(MarkTool.tools(for: model.mode)) { tool in
                    Button { model.tool = tool } label: {
                        Label(tool.title, systemImage: tool.symbol)
                            .labelStyle(.iconOnly)
                            .frame(width: 30, height: 26)
                            .background(model.tool == tool ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help(tool.title)
                }
            }
            if model.mode == .annotate {
                HStack(spacing: 6) {
                    ForEach(EditorModel.palette, id: \.self) { color in
                        Circle()
                            .fill(color)
                            .frame(width: 18, height: 18)
                            .overlay(Circle().stroke(Color.primary.opacity(model.color == color ? 0.9 : 0.2), lineWidth: model.color == color ? 2 : 1))
                            .onTapGesture { model.color = color }
                    }
                }
                Slider(value: $model.thickness, in: 0.5...3)
                    .frame(width: 90)
                    .help(L("Espessura", "Thickness"))
            }
            Spacer()
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(model.marks.isEmpty)
                .help(L("Desfazer", "Undo"))
            Button(L("Limpar", "Clear")) { model.clear() }.disabled(model.marks.isEmpty)
            Button(L("Cancelar", "Cancel"), action: onCancel).keyboardShortcut(.cancelAction)
            Button(model.mode == .annotate ? L("Salvar cópia anotada", "Save Annotated Copy") : L("Salvar cópia tarjada", "Save Redacted Copy"),
                   action: onSave)
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .tint(Color(nsColor: Theme.accent))
                .disabled(model.marks.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

@MainActor
enum ImageEditor {
    static func open(_ url: URL, mode: EditorMode) {
        let model: EditorModel
        do { model = try EditorModel(url: url, mode: mode) } catch {
            Dialog.alert(L("Não foi possível abrir", "Couldn't open"), error.localizedDescription)
            return
        }
        let title = (mode == .annotate ? L("Anotar", "Annotate") : L("Tarja", "Redact")) + " — " + url.lastPathComponent
        let window = EditorWindows.make(title: title, contentAspect: model.size, extraHeight: 52)
        window.contentView = NSHostingView(rootView: EditorView(model: model, onSave: { [weak window] in
            do {
                let out = try model.save()
                window?.close()
                HUD.shared.finished(JobResult(outputs: [out]))
            } catch {
                Dialog.alert(L("Não foi possível salvar", "Couldn't save"), error.localizedDescription)
            }
        }, onCancel: { [weak window] in window?.close() }))
        EditorWindows.present(window)
    }
}

/// Janelas comuns dos editores: tamanho proporcional ao conteúdo e referência mantida enquanto abertas.
@MainActor
enum EditorWindows {
    private static var open: Set<NSWindow> = []

    static func make(title: String, contentAspect: CGSize, extraHeight: CGFloat) -> NSWindow {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let maxW = screen.width * 0.8, maxH = screen.height * 0.8 - extraHeight
        let s = min(maxW / max(contentAspect.width, 1), maxH / max(contentAspect.height, 1), 1)
        let size = NSSize(width: max(680, contentAspect.width * s + 36), height: max(440, contentAspect.height * s + 36 + extraHeight))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 380)
        return window
    }

    static func present(_ window: NSWindow) {
        open.insert(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { note in
            MainActor.assumeIsolated {
                if let w = note.object as? NSWindow { open.remove(w) }
            }
        }
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
