import AppKit
import PDFKit
import WebKit

/// Arquivos de apoio (Java, JS, sons): dentro do .app ou, no modo de teste, na pasta Resources do projeto.
enum AppResources {
    static func url(_ name: String) -> URL? {
        if let url = Bundle.main.resourceURL?.appendingPathComponent(name), FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<5 {
            let url = dir.appendingPathComponent("Resources").appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}

/// Conversões de Office: PowerPoint e Excel antigo via Java (Apache POI + PDFBox, sem interface),
/// Word fiel e iWork via WebKit invisível (docx-preview + cupertino-files).
enum Office {
    static let presentationExts: Set = ["pptx", "ppt"]

    static func targets(for ext: String) -> [String] {
        switch ext {
        case "pptx", "ppt": ["pdf", "png", "jpg"]
        case "pages": Documents.textTargets
        case "key": ["pdf", "docx", "md", "txt", "html"]
        default: []
        }
    }

    static func convert(_ src: URL, to ext: String) throws -> URL {
        switch src.pathExtension.lowercased() {
        case "pptx", "ppt":
            return ext == "pdf" ? try slidesPDF(src) : try slidesImages(src, ext: ext)
        case "pages", "key":
            return try viaHTML(src, html: try iworkHTML(src), to: ext)
        default:
            return try Documents.office(src, to: ext)
        }
    }

    // MARK: Java

    /// O Java enxuto que vem dentro do app; fora dele (modo de teste), o Java instalado.
    private static let javaPath: String? = {
        if let java = AppResources.url("Runtime/bin/java"), FileManager.default.isExecutableFile(atPath: java.path) {
            return java.path
        }
        if let home = try? Shell.run("/usr/libexec/java_home", []).trimmingCharacters(in: .whitespacesAndNewlines),
           FileManager.default.isExecutableFile(atPath: home + "/bin/java") {
            return home + "/bin/java"
        }
        return ["/opt/homebrew/opt/openjdk/bin/java", "/usr/local/opt/openjdk/bin/java"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    private static func java(_ args: [String]) throws {
        guard let java = javaPath else {
            throw ToolError.failed(L("Java não encontrado. Instale com: brew install openjdk", "Java not found. Install it with: brew install openjdk"))
        }
        guard let dir = AppResources.url("Java") else {
            throw ToolError.failed(L("Conversor Office não encontrado no app.", "Office converter missing from the app."))
        }
        let classpath = dir.appendingPathComponent("toranja-office.jar").path + ":" + dir.appendingPathComponent("lib").path + "/*"
        do {
            try Shell.run(java, ["-Djava.awt.headless=true", "-Xmx2g",
                                 "-Dlog4j2.loggerContextFactory=org.apache.logging.log4j.simple.SimpleLoggerContextFactory",
                                 "-cp", classpath, "ToranjaOffice"] + args)
        } catch {
            // Mostra só a causa, não o rastro inteiro do Java.
            let detail = error.localizedDescription.components(separatedBy: "\n").first { $0.contains("Exception") } ?? ""
            throw ToolError.failed(L("Não foi possível converter este arquivo.", "Couldn't convert this file.") + (detail.isEmpty ? "" : "\n\(detail)"))
        }
    }

    static func slidesPDF(_ src: URL) throws -> URL {
        let out = Output.url(for: src, ext: "pdf")
        try java(["slides-pdf", src.path, out.path])
        return out
    }

    static func slidesImages(_ src: URL, ext: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try java(["slides-image", src.path, tmp.path, ext])
        let files = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if files.count == 1 {
            let out = Output.url(for: src, ext: ext)
            try FileManager.default.moveItem(at: files[0], to: out)
            return out
        }
        let dir = try Output.folder(for: src, suffix: L("slides", "slides"))
        for file in files {
            try FileManager.default.moveItem(at: file, to: dir.appendingPathComponent("Slide \(file.lastPathComponent)"))
        }
        return dir
    }

    /// Excel antigo (.xls) lido pelo Apache POI.
    static func javaSheets(_ src: URL) throws -> [Spreadsheet.Sheet] {
        let json = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: json) }
        try java(["sheet-json", src.path, json.path])
        let list = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [[String: Any]] ?? []
        return list.map { Spreadsheet.Sheet(name: $0["name"] as? String ?? "Sheet", rows: $0["rows"] as? [[String]] ?? []) }
    }

    static func pdfToSlides(_ src: URL) throws -> URL {
        let out = Output.url(for: src, ext: "pptx")
        try java(["pdf-pptx", src.path, out.path])
        return out
    }

    /// Tabelas de um PDF (uma aba por página), para virar XLSX.
    static func pdfSheets(_ src: URL) throws -> [Spreadsheet.Sheet] {
        let json = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: json) }
        try java(["pdf-sheet", src.path, json.path])
        let list = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [[String: Any]] ?? []
        return list.map { Spreadsheet.Sheet(name: $0["name"] as? String ?? "Sheet", rows: $0["rows"] as? [[String]] ?? []) }
    }

    // MARK: WebKit

    /// Gera um documento do Pages nativo a partir de texto formatado (títulos, listas, negrito, itálico).
    static func makePages(_ text: NSAttributedString, out: URL) throws {
        let blocks = RichText.blocks(text).map { block -> [String: Any] in
            let kind = switch block.kind {
            case .heading(let level): "h\(min(level, 3))"
            case .bullet: "li"
            case .paragraph: "p"
            }
            return ["kind": kind, "runs": block.runs.map { ["text": $0.text, "bold": $0.bold, "italic": $0.italic] }]
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: blocks), as: UTF8.self)
        let encoded: String = try WebSession.run { session, done in
            session.webView.callAsyncJavaScript("return toranja.makePages(json)", arguments: ["json": json], in: nil, in: .page) { result in
                done(result.flatMap { value in
                    (value as? String).map { .success($0) } ?? .failure(ToolError.failed(L("Falha ao criar o documento do Pages.", "Failed to create the Pages document.")))
                })
            }
        }
        guard let data = Data(base64Encoded: encoded) else {
            throw ToolError.failed(L("Falha ao criar o documento do Pages.", "Failed to create the Pages document."))
        }
        try data.write(to: out)
    }

    /// Converte HTML gerado (Pages, Keynote) usando os conversores de documento já existentes.
    private static func viaHTML(_ src: URL, html: String, to ext: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let page = tmp.appendingPathComponent(src.deletingPathExtension().lastPathComponent).appendingPathExtension("html")
        try ("<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body>" + html + "</body></html>")
            .write(to: page, atomically: true, encoding: .utf8)
        if ext == "html" {
            let out = Output.url(for: src, ext: ext)
            try FileManager.default.moveItem(at: page, to: out)
            return out
        }
        let produced = try Documents.convert(page, to: ext)
        let out = produced.isDirectory ? Output.url(for: src, ext: "", suffix: L("páginas", "pages")) : Output.url(for: src, ext: ext)
        try FileManager.default.moveItem(at: produced, to: out)
        return out
    }

    private static func base64(_ src: URL) throws -> String {
        // Documentos iWork em formato de pacote (pasta) são compactados antes de serem lidos.
        guard src.isDirectory else { return try Data(contentsOf: src).base64EncodedString() }
        let zip = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        defer { try? FileManager.default.removeItem(at: zip) }
        try Shell.run("/usr/bin/zip", ["-r", "-q", zip.path, "."], cwd: src)
        return try Data(contentsOf: zip).base64EncodedString()
    }

    static func iwork(_ src: URL) throws -> [String: Any] {
        let app = switch src.pathExtension.lowercased() {
        case "key": "keynote"
        case "numbers": "numbers"
        default: "pages"
        }
        let bytes = try base64(src)
        let json: String = try WebSession.run { session, done in
            session.webView.callAsyncJavaScript("return toranja.readIWork(b64, app)", arguments: ["b64": bytes, "app": app],
                                                in: nil, in: .page) { result in
                done(result.flatMap { value in
                    (value as? String).map { .success($0) } ?? .failure(ToolError.failed(L("Documento não reconhecido.", "Document not recognized.")))
                })
            }
        }
        guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw ToolError.failed(L("Documento não reconhecido.", "Document not recognized."))
        }
        return object
    }

    private static func iworkHTML(_ src: URL) throws -> String {
        let doc = try iwork(src)
        if let html = doc["html"] as? String { return html }
        let slides = doc["slides"] as? [[String: Any]] ?? []
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        return slides.enumerated().map { i, slide in
            let title = slide["title"] as? String ?? ""
            var texts = slide["texts"] as? [String] ?? []
            if let body = slide["body"] as? String, !body.isEmpty, !texts.contains(body) { texts.append(body) }
            texts.removeAll { $0 == title }
            var html = "<h2>\(L("Slide", "Slide")) \(i + 1)\(title.isEmpty ? "" : ": " + esc(title))</h2>"
            html += texts.flatMap { $0.components(separatedBy: .newlines) }.filter { !$0.isEmpty }.map { "<p>\(esc($0))</p>" }.joined()
            if let notes = slide["notes"] as? String, !notes.isEmpty {
                html += "<p><em>\(L("Notas", "Notes")): \(esc(notes))</em></p>"
            }
            return html
        }.joined()
    }

    static func numbersSheets(_ src: URL) throws -> [Spreadsheet.Sheet] {
        let sheets = try iwork(src)["sheets"] as? [[String: Any]] ?? []
        return sheets.map { Spreadsheet.Sheet(name: $0["name"] as? String ?? "Sheet", rows: $0["rows"] as? [[String]] ?? []) }
    }

    /// Word → PDF com o layout real das páginas (docx-preview), cortando a renderização contínua em páginas.
    static func docxPDF(_ src: URL, out: URL) throws {
        let bytes = try Data(contentsOf: src).base64EncodedString()
        let (pdf, rects, size): (Data, [CGRect], CGSize) = try WebSession.run { session, done in
            session.webView.callAsyncJavaScript("""
                const pages = await toranja.renderDocx(b64);
                return [pages, document.documentElement.scrollWidth, document.documentElement.scrollHeight];
                """, arguments: ["b64": bytes], in: nil, in: .page) { result in
                guard case .success(let value) = result, let parts = value as? [Any],
                      let pages = parts[0] as? [[Double]], let width = parts[1] as? Double, let height = parts[2] as? Double, !pages.isEmpty else {
                    if case .failure(let error) = result { done(.failure(error)) }
                    else { done(.failure(ToolError.failed(L("Documento Word vazio ou inválido.", "Empty or invalid Word document.")))) }
                    return
                }
                let rects = pages.map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
                session.webView.frame = NSRect(x: 0, y: 0, width: width, height: height)
                session.webView.createPDF(configuration: WKPDFConfiguration()) { pdf in
                    done(pdf.map { ($0, rects, CGSize(width: width, height: height)) })
                }
            }
        }
        guard let tall = PDFDocument(data: pdf)?.page(at: 0)?.pageRef else {
            throw ToolError.failed(L("Falha ao gerar o PDF.", "Failed to create the PDF."))
        }
        let box = tall.getBoxRect(.mediaBox)
        let rx = box.width / size.width, ry = box.height / size.height
        let scale: CGFloat = 0.75   // pixels CSS (96 dpi) → pontos (72 dpi)
        var first = CGRect(x: 0, y: 0, width: rects[0].width * scale, height: rects[0].height * scale)
        guard let context = CGContext(out as CFURL, mediaBox: &first, nil) else {
            throw ToolError.failed(L("Falha ao gerar o PDF.", "Failed to create the PDF."))
        }
        for rect in rects {
            var media = CGRect(x: 0, y: 0, width: rect.width * scale, height: rect.height * scale)
            context.beginPage(mediaBox: &media)
            context.scaleBy(x: scale / rx, y: scale / ry)
            let source = CGRect(x: rect.minX * rx, y: box.height - rect.maxY * ry, width: rect.width * rx, height: rect.height * ry)
            context.translateBy(x: -source.minX, y: -source.minY)
            context.clip(to: source)
            context.drawPDFPage(tall)
            context.endPage()
        }
        context.closePDF()
    }
}

/// Um WebKit invisível com o pacote office.js carregado. Bloqueia quem chama até o resultado chegar.
@MainActor
final class WebSession: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var onLoad: (() -> Void)?
    private static var active: Set<WebSession> = []

    private init(script: String) {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 1600), configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onLoad?()
        onLoad = nil
    }

    private final class Box<T>: @unchecked Sendable { var value: Result<T, Error>? }

    nonisolated static func run<T>(timeout: TimeInterval = 180,
                                   _ body: @escaping @MainActor (WebSession, @escaping (Result<T, Error>) -> Void) -> Void) throws -> T {
        guard let url = AppResources.url("JS/office.js"), let script = try? String(contentsOf: url, encoding: .utf8) else {
            throw ToolError.failed(L("Conversor Office não encontrado no app.", "Office converter missing from the app."))
        }
        let box = Box<T>()
        let semaphore = DispatchSemaphore(value: 0)
        let start: @MainActor () -> Void = {
            let session = WebSession(script: script)
            active.insert(session)
            session.onLoad = {
                body(session) { result in
                    guard box.value == nil else { return }
                    box.value = result
                    active.remove(session)
                    semaphore.signal()
                }
            }
            session.webView.loadHTMLString("""
                <!DOCTYPE html><html><head><meta charset="utf-8"><style>
                body{margin:0;background:#fff} section.docx{margin:0 !important;box-shadow:none !important}
                </style></head><body><div id="doc"></div></body></html>
                """, baseURL: nil)
        }
        let deadline = Date().addingTimeInterval(timeout)
        if Thread.isMainThread {
            // Modo de teste (linha de comando): gira o run loop enquanto espera.
            MainActor.assumeIsolated { start() }
            while box.value == nil && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { start() } }
            _ = semaphore.wait(timeout: .now() + timeout)
        }
        guard let result = box.value else { throw ToolError.failed(L("A conversão demorou demais.", "The conversion took too long.")) }
        return try result.get()
    }
}
