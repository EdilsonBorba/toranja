import AppKit
import SwiftUI

/// Testa as ferramentas sem interface: Toranja --cli <comando> [opção] <arquivo>…
@MainActor
enum CLI {
    static func run(_ args: [String]) -> Int32 {
        var args = args
        let command = args.removeFirst()
        let option = ["convert", "speed", "visualize", "wheel"].contains(command) ? args.removeFirst() : ""
        var urls = args.map { URL(fileURLWithPath: $0).standardizedFileURL }

        // Desenha a roda num PNG (sem o vidro): Toranja --cli wheel <conversion|actions|tools> <saida.png> <arquivo>…
        if command == "wheel", let kind = WheelKind(rawValue: option) {
            let out = urls.removeFirst()
            let items = Wheels.items(kind, for: urls)
            let radius: CGFloat = items.count > 8 ? 124 : 108
            let side = (radius + 28) * 2
            let view = WheelView(frame: NSRect(x: 0, y: 0, width: side, height: side))
            view.configure(kind: kind, items: items, radius: radius, caption: "7,3 MB")
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side * 2), pixelsHigh: Int(side * 2), bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
            cg.scaleBy(x: 2, y: 2)
            cg.setFillColor(NSColor(srgbRed: 0.33, green: 0.52, blue: 0.72, alpha: 1).cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: side, height: side))
            cg.setFillColor(NSColor(srgbRed: 0.22, green: 0.36, blue: 0.55, alpha: 1).cgColor)
            cg.fillEllipse(in: CGRect(x: 28, y: 28, width: radius * 2, height: radius * 2))
            view.layer?.render(in: cg)
            try? rep.representation(using: .png, properties: [:])?.write(to: out)
            print("ok  \(items.count) fatias → \(out.lastPathComponent)")
            return 0
        }

        // Captura a janela de Ajustes num PNG: Toranja --cli settings <aba> <saida.png> [formato]
        if command == "settings" {
            let tabs: [String: SettingsView.Tab] = ["general": .general, "formats": .formats, "compatibility": .compatibility,
                                                    "output": .output, "about": .about]
            let view = NSHostingView(rootView: SettingsView(tab: tabs[args[0]] ?? .general))
            let window = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 560, height: 660), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = view
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            view.layoutSubtreeIfNeeded()
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[1]))
            }
            print("ok")
            return 0
        }

        // Diagnóstico do Word: texto presente na página e uma captura da tela invisível.
        if command == "docx-debug" {
            let bytes = (try? Data(contentsOf: urls[0]).base64EncodedString()) ?? ""
            let info: String = (try? WebSession.run { session, done in
                session.webView.callAsyncJavaScript("""
                    await toranja.renderDocx(b64);
                    const el = document.querySelector('section.docx p, section.docx td');
                    const cs = el ? getComputedStyle(el) : null;
                    return JSON.stringify({ text: document.body.innerText.length, fonts: [...document.fonts].map(f => f.family + ':' + f.status).slice(0, 8),
                        color: cs?.color, font: cs?.fontFamily, size: cs?.fontSize, visibility: cs?.visibility });
                    """, arguments: ["b64": bytes], in: nil, in: .page) { result in
                    done(result.map { $0 as? String ?? "" })
                }
            }) ?? "falhou"
            print(info)
            return 0
        }

        // Ferramentas que usam vários arquivos de uma vez.
        if command == "collage" || command == "merge" {
            do {
                var out = Output.unique(in: urls[0].deletingLastPathComponent(), base: "Combinado", ext: "pdf")
                if command == "collage" { out = try Images.collage(urls, layout: .grid) } else { try Images.toPDF(urls, out: out) }
                print("ok  → \(out.lastPathComponent)")
                return 0
            } catch {
                print("ERRO \(error.localizedDescription)")
                return 1
            }
        }

        var failed = false
        for url in urls {
            do {
                let out: URL = switch command {
                case "convert": try Wheels.convert(url, to: option)
                case "compress":
                    switch FileKind(url) {
                    case .image: try Images.compress(url)
                    case .pdf: try Documents.compressPDF(url)
                    default: try Media.compress(url)
                    }
                case "strip":
                    switch FileKind(url) {
                    case .image: try Images.stripMetadata(url)
                    case .pdf: try Documents.stripMetadata(url)
                    default: try Media.stripMetadata(url)
                    }
                case "resize": try Images.resize(url, maxSide: 800, factor: nil)
                case "rotate": try Images.rotate(url)
                case "nobg": try Images.changeBackground(url, to: .transparent)
                case "blurbg": try Images.changeBackground(url, to: .blur)
                case "split": try Documents.split(url)
                case "speed": try Media.speed(url, factor: Double(option) ?? 2)
                case "normalize": try Media.normalize(url)
                case "mono": try Media.channels(url, mode: .mono)
                case "swap": try Media.channels(url, mode: .swap)
                case "trim": try Media.trim(url, start: 0.5, end: 2)
                case "bleep": try Media.bleep(url, ranges: [(1, 2)])
                case "silence": try Media.trimSilence(url)
                case "noaudio": try Media.removeAudio(url)
                case "visualize":
                    try Media.visualizer(url, style: Media.VisualizerStyle.allCases[Int(option) ?? 0], background: nil)
                case "zip": try Archives.zip([url])
                case "extract": try Archives.extract(url)
                case "qr": try {
                    print(try Images.barcodes(in: try Images.load(url)))
                    return url
                }()
                default: throw ToolError.failed("comando desconhecido: \(command)")
                }
                print("ok  \(url.lastPathComponent) → \(out.lastPathComponent)")
            } catch {
                failed = true
                print("ERRO \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return failed ? 1 : 0
    }
}
