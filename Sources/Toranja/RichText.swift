import AppKit

/// Converte texto formatado em blocos simples (títulos, parágrafos, listas) para gerar Markdown e EPUB.
enum RichText {
    struct Run {
        var text: String
        var bold: Bool
        var italic: Bool
        var link: URL?
    }

    struct Block {
        enum Kind: Equatable { case heading(Int), paragraph, bullet }
        var kind: Kind
        var runs: [Run]
        var plain: String { runs.map(\.text).joined() }
    }

    private static let bulletMarker = try! NSRegularExpression(pattern: #"^\s*[•◦▪‣∙·–-]\s+"#)

    static func blocks(_ text: NSAttributedString) -> [Block] {
        let ns = text.string as NSString
        let full = NSRange(location: 0, length: ns.length)

        // Tamanho do corpo = tamanho de fonte mais frequente.
        var sizes: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: full) { value, range, _ in
            sizes[((value as? NSFont)?.pointSize ?? 12).rounded(), default: 0] += range.length
        }
        let body = sizes.max { $0.value < $1.value }?.key ?? 12

        var result: [Block] = []
        ns.enumerateSubstrings(in: full, options: .byParagraphs) { paragraph, range, _, _ in
            guard let paragraph, !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            var runs: [Run] = []
            var maxSize: CGFloat = 0
            var allBold = true
            text.enumerateAttributes(in: range) { attrs, r, _ in
                let piece = ns.substring(with: r).replacingOccurrences(of: "\u{2028}", with: "\n")
                let font = attrs[.font] as? NSFont
                let traits = font?.fontDescriptor.symbolicTraits ?? []
                if !piece.trimmingCharacters(in: .whitespaces).isEmpty {
                    maxSize = max(maxSize, font?.pointSize ?? body)
                    if !traits.contains(.bold) { allBold = false }
                }
                let link = attrs[.link] as? URL ?? (attrs[.link] as? String).flatMap(URL.init(string:))
                runs.append(Run(text: piece, bold: traits.contains(.bold), italic: traits.contains(.italic), link: link))
            }

            var kind = Block.Kind.paragraph
            let style = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let marker = bulletMarker.firstMatch(in: paragraph, range: NSRange(location: 0, length: (paragraph as NSString).length))
            if let marker {
                kind = .bullet
                runs = dropPrefix(marker.range.length, from: runs)
            } else if !(style?.textLists.isEmpty ?? true) {
                kind = .bullet
            } else if maxSize >= body * 1.6 {
                kind = .heading(1)
            } else if maxSize >= body * 1.3 {
                kind = .heading(2)
            } else if maxSize >= body * 1.1 && allBold && paragraph.count < 120 {
                kind = .heading(3)
            }
            result.append(Block(kind: kind, runs: merged(runs)))
        }
        return result
    }

    private static func dropPrefix(_ count: Int, from runs: [Run]) -> [Run] {
        var remaining = count
        var out: [Run] = []
        for var run in runs {
            let length = (run.text as NSString).length
            if remaining >= length { remaining -= length; continue }
            if remaining > 0 { run.text = (run.text as NSString).substring(from: remaining); remaining = 0 }
            out.append(run)
        }
        return out
    }

    private static func merged(_ runs: [Run]) -> [Run] {
        var out: [Run] = []
        for run in runs {
            if var last = out.last, last.bold == run.bold, last.italic == run.italic, last.link == run.link {
                last.text += run.text
                out[out.count - 1] = last
            } else {
                out.append(run)
            }
        }
        return out
    }

    /// Separa espaços das pontas: ênfase em Markdown/HTML não pode começar ou terminar com espaço.
    private static func wrap(_ text: String, _ format: (String) -> String) -> String {
        let core = text.trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty, let start = text.range(of: core) else { return text }
        return String(text[..<start.lowerBound]) + format(core) + String(text[start.upperBound...])
    }

    // MARK: Markdown

    static func markdown(_ blocks: [Block]) -> String {
        var out = ""
        var previousBullet = false
        for block in blocks {
            let bullet = block.kind == .bullet
            if !out.isEmpty { out += bullet && previousBullet ? "\n" : "\n\n" }
            switch block.kind {
            case .heading(let level):
                out += String(repeating: "#", count: level) + " " + block.plain.trimmingCharacters(in: .whitespaces)
            case .bullet:
                out += "- " + inlineMarkdown(block.runs)
            case .paragraph:
                out += inlineMarkdown(block.runs)
            }
            previousBullet = bullet
        }
        return out + "\n"
    }

    private static func inlineMarkdown(_ runs: [Run]) -> String {
        runs.map { run in
            let escaped = run.text.replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "_", with: "\\_")
            return wrap(escaped) { core in
                var s = core
                if let link = run.link { s = "[\(s)](\(link.absoluteString))" }
                if run.bold && run.italic { s = "***\(s)***" } else if run.bold { s = "**\(s)**" } else if run.italic { s = "*\(s)*" }
                return s
            }.replacingOccurrences(of: "\n", with: "  \n")
        }.joined()
    }

    // MARK: HTML / EPUB

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func inlineHTML(_ runs: [Run]) -> String {
        runs.map { run in
            wrap(escape(run.text)) { core in
                var s = core
                if run.italic { s = "<em>\(s)</em>" }
                if run.bold { s = "<strong>\(s)</strong>" }
                if let link = run.link { s = "<a href=\"\(escape(link.absoluteString))\">\(s)</a>" }
                return s
            }.replacingOccurrences(of: "\n", with: "<br/>")
        }.joined()
    }

    static func xhtmlBody(_ blocks: [Block]) -> String {
        var html = ""
        var inList = false
        for block in blocks {
            if block.kind == .bullet && !inList { html += "<ul>\n"; inList = true }
            if block.kind != .bullet && inList { html += "</ul>\n"; inList = false }
            switch block.kind {
            case .heading(let level): html += "<h\(level)>\(escape(block.plain.trimmingCharacters(in: .whitespaces)))</h\(level)>\n"
            case .bullet: html += "<li>\(inlineHTML(block.runs))</li>\n"
            case .paragraph: html += "<p>\(inlineHTML(block.runs))</p>\n"
            }
        }
        if inList { html += "</ul>\n" }
        return html
    }

    static func epub(_ text: NSAttributedString, title: String, out: URL) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        let meta = tmp.appendingPathComponent("META-INF"), oebps = tmp.appendingPathComponent("OEBPS")
        try fm.createDirectory(at: meta, withIntermediateDirectories: true)
        try fm.createDirectory(at: oebps, withIntermediateDirectories: true)

        let t = escape(title)
        let language = L("pt", "en")
        let modified = ISO8601DateFormatter().string(from: Date())
        let head = #"<?xml version="1.0" encoding="UTF-8"?>"#

        try Data("application/epub+zip".utf8).write(to: tmp.appendingPathComponent("mimetype"))
        try """
        \(head)
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.write(to: meta.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
        try """
        \(head)
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">urn:uuid:\(UUID().uuidString)</dc:identifier>
            <dc:title>\(t)</dc:title>
            <dc:language>\(language)</dc:language>
            <meta property="dcterms:modified">\(modified)</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="text" href="text.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="text"/></spine>
        </package>
        """.write(to: oebps.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        try """
        \(head)
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(language)">
        <head><title>\(t)</title></head>
        <body><nav epub:type="toc"><ol><li><a href="text.xhtml">\(t)</a></li></ol></nav></body>
        </html>
        """.write(to: oebps.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)
        try """
        \(head)
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" lang="\(language)">
        <head><title>\(t)</title><style>body{font-family:serif;line-height:1.5} h1,h2,h3{font-family:sans-serif}</style></head>
        <body>
        \(xhtmlBody(blocks(text)))
        </body>
        </html>
        """.write(to: oebps.appendingPathComponent("text.xhtml"), atomically: true, encoding: .utf8)

        // O "mimetype" precisa ser o primeiro item do zip, sem compressão.
        try Shell.run("/usr/bin/zip", ["-X", "-0", "-q", out.path, "mimetype"], cwd: tmp)
        try Shell.run("/usr/bin/zip", ["-X", "-9", "-r", "-q", out.path, "META-INF", "OEBPS"], cwd: tmp)
    }
}
