import AppKit
import QuartzCore

/// Mostra a roda de vidro ao lado do cursor durante o arraste.
@MainActor
final class WheelController {
    private static let margin: CGFloat = 28

    private let panel: NSPanel
    private let container = NSView()
    private var glass: NSView
    private let wheel = WheelView()
    private(set) var currentKind: WheelKind?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        if #available(macOS 26, *) {
            let g = NSGlassEffectView()
            g.tintColor = Theme.glassTint
            glass = g
        } else {
            let v = NSVisualEffectView()
            v.material = .hudWindow
            v.blendingMode = .behindWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.masksToBounds = true
            glass = v
        }
        glass.wantsLayer = true
        glass.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.35)
            s.shadowBlurRadius = 18
            s.shadowOffset = NSSize(width: 0, height: -6)
            return s
        }()
        container.wantsLayer = true
        container.addSubview(glass)
        container.addSubview(wheel)
        panel.contentView = container

        wheel.onPerform = { [weak self] item, urls in
            self?.hide()
            item.perform(urls)
        }
    }

    func show(_ kind: WheelKind, urls: [URL]) {
        let items = Wheels.items(kind, for: urls)
        let radius: CGFloat = items.count > 8 ? 124 : 108
        let side = (radius + Self.margin) * 2

        // A roda abre à esquerda do cursor (ou à direita, se faltar espaço).
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let offset = radius * 1.5
        var center = NSPoint(x: mouse.x - offset, y: mouse.y)
        if let frame = screen?.visibleFrame {
            if center.x - radius < frame.minX + 8 { center.x = mouse.x + offset }
            center.y = min(max(center.y, frame.minY + radius + 8), frame.maxY - radius - 8)
        }
        panel.setFrame(NSRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side), display: false)
        container.frame = NSRect(x: 0, y: 0, width: side, height: side)
        // Recria o fundo a cada abertura: respeita a aparência escolhida (vidro ou sólido) e o novo raio.
        let backdrop = Theme.backdrop(cornerRadius: radius, tint: Theme.glassTint, solid: Theme.solidDisc)
        backdrop.shadow = glass.shadow
        container.replaceSubview(glass, with: backdrop)
        glass = backdrop
        glass.frame = NSRect(x: Self.margin, y: Self.margin, width: radius * 2, height: radius * 2)
        wheel.frame = container.bounds
        wheel.configure(kind: kind, items: items, radius: radius, caption: Self.caption(for: urls))

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }
        wheel.animateIn()
        currentKind = kind
        Feedback.open()
    }

    func hide() {
        guard currentKind != nil else { return }
        currentKind = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.currentKind == nil else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    /// Texto da pílula central: tamanho total dos arquivos arrastados.
    private static func caption(for urls: [URL]) -> String {
        var total = 0
        var budget = 3000
        for url in urls {
            if url.isDirectory {
                let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
                while budget > 0, let child = e?.nextObject() as? URL {
                    total += Output.size(child)
                    budget -= 1
                }
            } else {
                total += Output.size(url)
            }
        }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }
}

final class WheelView: NSView {
    var onPerform: ((WheelItem, [URL]) -> Void)?

    private var items: [WheelItem] = []
    private var radius: CGFloat = 108
    private let root = CALayer()
    private var slices: [CAShapeLayer] = []
    private var contents: [CALayer] = []
    private let pill = CALayer()
    private let pillText = CATextLayer()
    private let innerRing = CAShapeLayer()

    private static let gap: CGFloat = 5
    private static let corner: CGFloat = 9

    private var hovered: Int? {
        didSet {
            guard hovered != oldValue else { return }
            updateHover()
            if hovered != nil { Feedback.hover() }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(root)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    private var outerR: CGFloat { radius - 7 }
    private var innerR: CGFloat { radius * 0.41 }
    private var step: CGFloat { 2 * .pi / CGFloat(max(items.count, 1)) }
    /// Fatia 0 no topo, seguindo no sentido horário.
    private func midAngle(_ i: Int) -> CGFloat { .pi / 2 - CGFloat(i) * step }

    func configure(kind: WheelKind, items: [WheelItem], radius: CGFloat, caption: String) {
        self.items = items
        self.radius = radius
        hovered = nil
        rebuild(caption: caption)
    }

    func animateIn() {
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 0.82
        spring.toValue = 1
        spring.mass = 1
        spring.stiffness = 320
        spring.damping = 20
        spring.duration = spring.settlingDuration
        root.add(spring, forKey: "in")
        for (i, layer) in contents.enumerated() {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.beginTime = CACurrentMediaTime() + 0.02 * Double(i)
            fade.duration = 0.18
            fade.fillMode = .backwards
            layer.add(fade, forKey: "in")
        }
    }

    // MARK: Desenho

    private func rebuild(caption: String) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        root.frame = bounds
        root.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        root.position = center
        slices = []
        contents = []

        for (i, item) in items.enumerated() {
            let slice = CAShapeLayer()
            slice.frame = bounds
            slice.path = Self.slicePath(center: center, inner: innerR, outer: outerR,
                                        start: midAngle(i) - step / 2, end: midAngle(i) + step / 2, count: items.count)
            slice.fillColor = Theme.slice.cgColor
            slice.strokeColor = items.count > 1 ? Theme.slice.cgColor : nil
            slice.lineWidth = Self.corner * 2
            slice.lineJoin = .round
            slice.fillRule = .evenOdd
            slice.opacity = 0.82
            root.addSublayer(slice)
            slices.append(slice)

            let content = makeContent(for: item, at: i, scale: scale)
            root.addSublayer(content)
            contents.append(content)
        }

        innerRing.frame = bounds
        let ringR = innerR - 5
        innerRing.path = CGPath(ellipseIn: CGRect(x: center.x - ringR, y: center.y - ringR, width: ringR * 2, height: ringR * 2), transform: nil)
        innerRing.fillColor = NSColor.white.withAlphaComponent(0.04).cgColor
        innerRing.strokeColor = NSColor.white.withAlphaComponent(0.22).cgColor
        innerRing.lineWidth = 1
        root.addSublayer(innerRing)

        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let text = items.isEmpty ? L("Nada aqui", "Nothing here") : caption
        let width = (text as NSString).size(withAttributes: [.font: font]).width + 24
        pill.frame = CGRect(x: center.x - width / 2, y: center.y - 12, width: width, height: 24)
        pill.cornerRadius = 12
        pill.backgroundColor = NSColor(srgbRed: 0.36, green: 0.43, blue: 0.56, alpha: 0.55).cgColor
        pillText.string = text
        pillText.font = font
        pillText.fontSize = 11
        pillText.foregroundColor = NSColor.white.cgColor
        pillText.alignmentMode = .center
        pillText.contentsScale = scale
        pillText.frame = CGRect(x: 0, y: 4, width: width, height: 16)
        pill.addSublayer(pillText)
        root.addSublayer(pill)
        CATransaction.commit()
    }

    private func makeContent(for item: WheelItem, at i: Int, scale: CGFloat) -> CALayer {
        let angle = midAngle(i)
        let rMid = (innerR + outerR) / 2 + 2
        let c = CGPoint(x: center.x + cos(angle) * rMid, y: center.y + sin(angle) * rMid)
        let chord = items.count > 1 ? 2 * rMid * sin(min(step, .pi * 0.9) / 2) - 4 : 90
        var width = min(84, max(44, chord))
        let hasIcon = item.symbol != nil
        let title = item.title.uppercased()
        let kern: CGFloat = hasIcon ? 0.4 : 0.2

        // Reduz a fonte até a palavra mais longa caber na fatia.
        var size: CGFloat = hasIcon ? 8.5 : 12.5
        func widest(_ size: CGFloat) -> CGFloat {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .bold), .kern: kern]
            return title.split(separator: " ").map { (String($0) as NSString).size(withAttributes: attrs).width }.max() ?? 0
        }
        while widest(size) > width - 4 && size > 6.5 { size -= 0.5 }
        width = max(width, ceil(widest(size)) + 4)

        // Quebra de linha feita aqui: o CATextLayer mede diferente e cortaria o texto.
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .bold), .kern: kern]
        var lines: [String] = []
        for word in title.split(separator: " ").map(String.init) {
            if let last = lines.last, ((last + " " + word) as NSString).size(withAttributes: attrs).width <= width - 4 {
                lines[lines.count - 1] = last + " " + word
            } else {
                lines.append(word)
            }
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let label = NSAttributedString(string: lines.joined(separator: "\n"), attributes: attrs.merging([
            .foregroundColor: NSColor.white, .paragraphStyle: style,
        ]) { a, _ in a })
        let textHeight = ceil(label.boundingRect(with: CGSize(width: 400, height: 80), options: [.usesLineFragmentOrigin]).height)
        let iconSize: CGFloat = hasIcon ? 16 : 0
        let spacing: CGFloat = hasIcon ? 4 : 0
        let total = iconSize + spacing + textHeight

        let group = CALayer()
        group.frame = CGRect(x: c.x - width / 2, y: c.y - total / 2, width: width, height: total)

        let text = CATextLayer()
        text.string = label
        text.alignmentMode = .center
        text.contentsScale = scale
        text.frame = CGRect(x: 0, y: 0, width: width, height: textHeight)
        group.addSublayer(text)

        if let symbol = item.symbol,
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.title)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold).applying(.init(paletteColors: [.white]))) {
            let icon = CALayer()
            icon.contents = image
            icon.contentsGravity = .resizeAspect
            icon.contentsScale = scale
            icon.frame = CGRect(x: (width - iconSize) / 2, y: textHeight + spacing, width: iconSize, height: iconSize)
            group.addSublayer(icon)
        }
        return group
    }

    /// Setor de anel com cantos arredondados e espaço constante entre as fatias.
    /// O formato é desenhado reduzido e depois "engordado" pelo traço com junção redonda.
    private static func slicePath(center c: CGPoint, inner: CGFloat, outer: CGFloat,
                                  start a0: CGFloat, end a1: CGFloat, count: Int) -> CGPath {
        let path = CGMutablePath()
        if count <= 1 {
            path.addEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
            path.addEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
            return path
        }
        let ro = outer - corner, ri = inner + corner
        let d = gap / 2 + corner
        let o0 = a0 + asin(min(1, d / ro)), o1 = a1 - asin(min(1, d / ro))
        let i0 = a0 + asin(min(1, d / ri)), i1 = a1 - asin(min(1, d / ri))
        path.addArc(center: c, radius: ro, startAngle: o0, endAngle: o1, clockwise: false)
        path.addLine(to: CGPoint(x: c.x + cos(i1) * ri, y: c.y + sin(i1) * ri))
        path.addArc(center: c, radius: ri, startAngle: i1, endAngle: i0, clockwise: true)
        path.closeSubpath()
        return path
    }

    private func updateHover() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        for (i, slice) in slices.enumerated() {
            let on = i == hovered
            let color = (on ? Theme.accent : Theme.slice).cgColor
            slice.fillColor = color
            if slice.strokeColor != nil { slice.strokeColor = color }
            slice.opacity = on ? 1 : 0.82
            let push: CGFloat = on && items.count > 1 ? 4 : 0
            let t = CATransform3DMakeTranslation(cos(midAngle(i)) * push, sin(midAngle(i)) * push, 0)
            slice.transform = t
            contents[i].transform = on ? CATransform3DScale(t, 1.06, 1.06, 1) : CATransform3DIdentity
        }
        CATransaction.commit()
    }

    private func index(at point: NSPoint) -> Int? {
        guard !items.isEmpty else { return nil }
        let dx = point.x - center.x, dy = point.y - center.y
        let r = hypot(dx, dy)
        guard r >= innerR - 4, r <= radius + 12 else { return nil }
        var rel = (.pi / 2 - atan2(dy, dx) + step / 2).truncatingRemainder(dividingBy: 2 * .pi)
        if rel < 0 { rel += 2 * .pi }
        return min(Int(rel / step), items.count - 1)
    }

    // MARK: Destino do arraste

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { hovered = nil }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        hovered = index(at: convert(sender.draggingLocation, from: nil))
        guard hovered != nil else { return [] }
        let mask = sender.draggingSourceOperationMask
        return [NSDragOperation.copy, .generic, .link, .move].first { mask.contains($0) } ?? .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let i = hovered else { return false }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        let item = items[i]
        DispatchQueue.main.async { [weak self] in self?.onPerform?(item, urls) }
        return true
    }
}
