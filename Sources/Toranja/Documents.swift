import AppKit
import PDFKit
import Quartz

enum Documents {
    static let textExts: Set = ["txt", "text", "md", "markdown", "rtf", "rtfd", "doc", "docx", "odt", "html", "htm", "webarchive", "wordml"]
    static let officeExts: Set = ["pptx", "ppt", "pages", "key", "odp"]
    static let textTargets = ["docx", "pages", "pdf", "md", "html", "epub", "jpg", "png", "txt", "rtf"]
    static let pdfTargets = ["docx", "pages", "pptx", "xlsx", "txt", "md", "epub", "jpg", "png"]

    static var soffice: String? {
        let path = "/Applications/LibreOffice.app/Contents/MacOS/soffice"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    static func onMain<T>(_ body: () throws -> T) rethrows -> T {
        Thread.isMainThread ? try body() : try DispatchQueue.main.sync(execute: body)
    }

    // MARK: Texto (Word, RTF, HTML, Markdown…)

    static func attributed(_ src: URL) throws -> NSAttributedString {
        if ["txt", "text", "md", "markdown"].contains(src.pathExtension.lowercased()) {
            return NSAttributedString(string: try String(contentsOf: src, encoding: .utf8),
                                      attributes: [.font: NSFont.systemFont(ofSize: 12)])
        }
        // HTML usa o WebKit, que exige a thread principal; sem charset declarado, assume UTF-8.
        let isHTML = ["html", "htm"].contains(src.pathExtension.lowercased())
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = isHTML
            ? [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue] : [:]
        return try onMain { try NSAttributedString(url: src, options: options, documentAttributes: nil) }
    }

    static func convert(_ src: URL, to ext: String) throws -> URL {
        let out = Output.url(for: src, ext: ext)
        switch ext {
        case "pdf":
            try paginated(src, to: out)
            return out
        case "png", "jpg":
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try paginated(src, to: tmp)
            return try pdfToImages(try open(tmp), src: src, ext: ext)
        case "md":
            try RichText.markdown(RichText.blocks(try attributed(src))).write(to: out, atomically: true, encoding: .utf8)
            return out
        case "epub":
            try RichText.epub(try attributed(src), title: src.deletingPathExtension().lastPathComponent, out: out)
            return out
        case "pages":
            try Office.makePages(try attributed(src), out: out)
            return out
        default:
            var args = ["-convert", ext, "-output", out.path, src.path]
            if ["md", "markdown"].contains(src.pathExtension.lowercased()) { args = ["-format", "txt"] + args }
            try Shell.run("/usr/bin/textutil", args)
            return out
        }
    }

    /// Word (.docx) usa o layout real das páginas; os demais formatos são paginados pelo sistema.
    private static func paginated(_ src: URL, to out: URL) throws {
        if src.pathExtension.lowercased() == "docx" {
            try Office.docxPDF(src, out: out)
        } else {
            let text = try attributed(src)
            try onMain { try printPDF(text, to: out) }
        }
    }

    /// Pagina um texto formatado em A4 e grava em PDF (usa o sistema de impressão, sem diálogo).
    static func printPDF(_ text: NSAttributedString, to out: URL, landscape: Bool = false) throws {
        let paper = landscape ? NSSize(width: 842, height: 595) : NSSize(width: 595, height: 842)
        let margin: CGFloat = landscape ? 36 : 56
        let info = NSPrintInfo()
        info.paperSize = paper
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out as NSURL

        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: paper.width - margin * 2, height: 100))
        view.appearance = NSAppearance(named: .aqua)
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.textStorage?.setAttributedString(text)
        if let container = view.textContainer { view.layoutManager?.ensureLayout(for: container) }
        view.sizeToFit()

        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run(), FileManager.default.fileExists(atPath: out.path) else {
            throw ToolError.failed(L("Falha ao gerar o PDF.", "Failed to create the PDF."))
        }
    }

    // MARK: PDF

    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw ToolError.failed(L("Não foi possível abrir o PDF.", "Couldn't open the PDF.")) }
        return doc
    }

    private static func attributed(_ doc: PDFDocument) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.attributedString else { continue }
            text.append(page)
            text.append(NSAttributedString(string: "\n"))
        }
        return text
    }

    static func fromPDF(_ src: URL, to ext: String) throws -> URL {
        let doc = try open(src)
        let out = Output.url(for: src, ext: ext)
        switch ext {
        case "png", "jpg":
            return try pdfToImages(doc, src: src, ext: ext)
        case "pptx":
            return try Office.pdfToSlides(src)
        case "xlsx":
            return try Spreadsheet.convert(src, to: ext)
        case "pages":
            try Office.makePages(attributed(doc), out: out)
        case "txt":
            try (doc.string ?? "").write(to: out, atomically: true, encoding: .utf8)
        case "md":
            try RichText.markdown(RichText.blocks(attributed(doc))).write(to: out, atomically: true, encoding: .utf8)
        case "epub":
            try RichText.epub(attributed(doc), title: src.deletingPathExtension().lastPathComponent, out: out)
        default:
            let text = attributed(doc)
            let type: NSAttributedString.DocumentType = switch ext {
            case "docx": .officeOpenXML
            case "rtf": .rtf
            case "odt": .openDocument
            default: .html
            }
            let data = try onMain {
                try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: type])
            }
            try data.write(to: out)
        }
        return out
    }

    static func renderPage(_ page: PDFPage, scale: CGFloat = 2) throws -> CGImage {
        var size = page.bounds(for: .mediaBox).size
        if page.rotation % 180 != 0 { size = NSSize(width: size.height, height: size.width) }
        let image = page.thumbnail(of: NSSize(width: size.width * scale, height: size.height * scale), for: .mediaBox)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ToolError.failed(L("Falha ao renderizar a página.", "Failed to render the page."))
        }
        return cg
    }

    private static func pdfToImages(_ doc: PDFDocument, src: URL, ext: String) throws -> URL {
        let type = Images.type(for: ext)!
        if doc.pageCount == 1, let page = doc.page(at: 0) {
            let out = Output.url(for: src, ext: ext)
            try Images.write(try renderPage(page), to: out, type: type)
            return out
        }
        let dir = try Output.folder(for: src, suffix: L("páginas", "pages"))
        let digits = String(doc.pageCount).count
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let number = String(repeating: "0", count: digits - String(i + 1).count) + String(i + 1)
            let out = dir.appendingPathComponent("\(L("Página", "Page")) \(number)").appendingPathExtension(ext)
            try Images.write(try renderPage(page), to: out, type: type)
        }
        return dir
    }

    static func compressPDF(_ src: URL) throws -> URL {
        let doc = try open(src)
        guard let filter = QuartzFilter(url: URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")) else {
            throw ToolError.failed(L("Filtro de compressão do sistema não encontrado.", "System compression filter not found."))
        }
        let out = Output.url(for: src, ext: "pdf", suffix: L("comprimido", "compressed"))
        guard doc.write(to: out, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]) else {
            throw ToolError.failed(L("Falha ao gravar o PDF.", "Failed to save the PDF."))
        }
        try Output.notSmaller(out, than: src)
        return out
    }

    static func split(_ src: URL) throws -> URL {
        let doc = try open(src)
        guard doc.pageCount > 1 else { throw ToolError.failed(L("O PDF tem só uma página.", "The PDF has only one page.")) }
        let dir = try Output.folder(for: src, suffix: L("páginas", "pages"))
        let base = src.deletingPathExtension().lastPathComponent
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            single.write(to: dir.appendingPathComponent("\(base) - \(i + 1).pdf"))
        }
        return dir
    }

    static func stripMetadata(_ src: URL) throws -> URL {
        let doc = try open(src)
        doc.documentAttributes = [:]
        let out = Output.url(for: src, ext: "pdf", suffix: L("sem metadados", "no metadata"))
        guard doc.write(to: out) else { throw ToolError.failed(L("Falha ao gravar o PDF.", "Failed to save the PDF.")) }
        return out
    }

    // MARK: Office (PowerPoint, Excel, Pages…) via LibreOffice, se instalado

    static func office(_ src: URL, to ext: String) throws -> URL {
        guard let soffice else {
            throw ToolError.failed(L("Instale o LibreOffice para converter este formato: brew install --cask libreoffice",
                                     "Install LibreOffice to convert this format: brew install --cask libreoffice"))
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Shell.run(soffice, ["--headless", "--convert-to", ext, "--outdir", tmp.path, src.path])
        guard let produced = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil).first else {
            throw ToolError.failed(L("O LibreOffice não gerou nenhum arquivo.", "LibreOffice didn't produce a file."))
        }
        let out = Output.url(for: src, ext: ext)
        try FileManager.default.moveItem(at: produced, to: out)
        return out
    }
}

enum Archives {
    static let exts: Set = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "tbz", "txz"]

    static func zip(_ urls: [URL]) throws -> URL {
        let dir = urls[0].deletingLastPathComponent()
        if urls.count == 1 {
            let out = Output.unique(in: Output.directory(for: urls[0]), base: urls[0].deletingPathExtension().lastPathComponent, ext: "zip")
            try Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", urls[0].path, out.path])
            return out
        }
        let out = Output.unique(in: Output.directory(for: urls[0]), base: L("Arquivos", "Archive"), ext: "zip")
        let sameFolder = urls.allSatisfy { $0.deletingLastPathComponent() == dir }
        let names = sameFolder ? urls.map(\.lastPathComponent) : urls.map(\.path)
        try Shell.run("/usr/bin/zip", ["-r", "-y", "-q"] + (sameFolder ? [] : ["-j"]) + [out.path] + names + ["-x", "*.DS_Store"], cwd: dir)
        return out
    }

    static func extract(_ src: URL) throws -> URL {
        var base = src.deletingPathExtension()
        if base.pathExtension.lowercased() == "tar" { base = base.deletingPathExtension() }
        let out = Output.unique(in: Output.directory(for: src), base: base.lastPathComponent, ext: "")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        do {
            if src.pathExtension.lowercased() == "zip" {
                try Shell.run("/usr/bin/ditto", ["-x", "-k", src.path, out.path])
            } else {
                try Shell.run("/usr/bin/tar", ["-xf", src.path, "-C", out.path])
            }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }
}
