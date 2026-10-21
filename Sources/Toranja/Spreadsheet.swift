import AppKit

/// Planilhas sem dependências: lê e grava XLSX, ODS, CSV e TSV (são zips de XML ou texto), e exporta PDF/HTML.
enum Spreadsheet {
    struct Sheet {
        var name: String
        var rows: [[String]]
    }

    static let exts: Set = ["xlsx", "xls", "ods", "csv", "tsv", "numbers"]
    static let targets = ["pdf", "csv", "tsv", "xlsx", "ods", "html"]

    static func convert(_ src: URL, to ext: String) throws -> URL {
        let sheets = try read(src).filter { !$0.rows.isEmpty }
        guard !sheets.isEmpty else { throw ToolError.failed(L("A planilha está vazia.", "The spreadsheet is empty.")) }
        switch ext {
        case "csv", "tsv":
            // Uma planilha → um arquivo; várias → uma pasta com um arquivo por aba.
            if sheets.count == 1 {
                let out = Output.url(for: src, ext: ext)
                try delimited(sheets[0], ext: ext).write(to: out)
                return out
            }
            let dir = try Output.folder(for: src, suffix: L("planilhas", "sheets"))
            for sheet in sheets {
                try delimited(sheet, ext: ext).write(to: Output.unique(in: dir, base: safeName(sheet.name), ext: ext))
            }
            return dir
        case "xlsx":
            let out = Output.url(for: src, ext: ext)
            try writeXLSX(sheets, to: out)
            return out
        case "ods":
            let out = Output.url(for: src, ext: ext)
            try writeODS(sheets, to: out)
            return out
        case "html":
            let out = Output.url(for: src, ext: ext)
            try html(sheets, title: src.deletingPathExtension().lastPathComponent).write(to: out, atomically: true, encoding: .utf8)
            return out
        case "pdf":
            let out = Output.url(for: src, ext: ext)
            try renderPDF(sheets, to: out)
            return out
        default:
            throw ToolError.failed(L("Formato não suportado.", "Unsupported format."))
        }
    }

    private static func safeName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    // MARK: Leitura

    static func read(_ src: URL) throws -> [Sheet] {
        // Normaliza números (tira ruído de ponto flutuante) e linhas/colunas vazias do fim, venha de onde vier.
        try readRaw(src).map { sheet in
            Sheet(name: sheet.name, rows: trimmed(sheet.rows.map { $0.map { numeric($0) != nil ? number($0) : $0 } }))
        }
    }

    private static func readRaw(_ src: URL) throws -> [Sheet] {
        switch src.pathExtension.lowercased() {
        case "csv", "tsv": return [Sheet(name: src.deletingPathExtension().lastPathComponent, rows: try readDelimited(src))]
        case "ods": return try readODS(src)
        case "xls": return try Office.javaSheets(src)
        case "pdf": return try Office.pdfSheets(src)
        case "numbers": return try Office.numbersSheets(src)
        default: return try readXLSX(src)
        }
    }

    private static func unzip(_ src: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Shell.run("/usr/bin/unzip", ["-q", "-o", src.path, "-d", dir.path])
        return dir
    }

    private static func xml(_ url: URL) -> XMLElement? {
        (try? XMLDocument(contentsOf: url, options: []))?.rootElement()
    }

    /// Filhos com o nome local indicado (ignora prefixos de namespace).
    private static func children(_ element: XMLElement?, _ name: String) -> [XMLElement] {
        (element?.children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == name }
    }

    private static func attr(_ element: XMLElement, _ name: String) -> String? {
        element.attributes?.first { $0.localName == name || $0.name == name }?.stringValue
    }

    /// Texto de um nó, juntando trechos ricos (<r><t>) e ignorando a pronúncia fonética (<rPh>).
    private static func text(_ element: XMLElement) -> String {
        if element.localName == "t" { return element.stringValue ?? "" }
        if element.localName == "rPh" { return "" }
        return (element.children ?? []).compactMap { $0 as? XMLElement }.map(text).joined()
    }

    private static func columnIndex(_ ref: String) -> Int? {
        var n = 0
        var found = false
        for ch in ref.uppercased().unicodeScalars {
            guard ch.value >= 65 && ch.value <= 90 else { break }
            n = n * 26 + Int(ch.value - 64)
            found = true
        }
        return found ? n - 1 : nil
    }

    private static func readXLSX(_ src: URL) throws -> [Sheet] {
        let dir = try unzip(src)
        defer { try? FileManager.default.removeItem(at: dir) }
        let xl = dir.appendingPathComponent("xl")
        guard let workbook = xml(xl.appendingPathComponent("workbook.xml")) else {
            throw ToolError.failed(L("Planilha inválida ou protegida por senha.", "Invalid or password-protected spreadsheet."))
        }

        let shared = children(xml(xl.appendingPathComponent("sharedStrings.xml")), "si").map(text)

        // Estilos de data: formatos embutidos 14–22/45–47 ou personalizados com dia/mês/ano.
        let styles = xml(xl.appendingPathComponent("styles.xml"))
        var dateFormats: Set<Int> = Set(14...22).union(45...47)
        for fmt in children(children(styles, "numFmts").first, "numFmt") {
            if let id = attr(fmt, "numFmtId").flatMap(Int.init), let code = attr(fmt, "formatCode")?.lowercased(),
               code.contains("y") || (code.contains("d") && code.contains("m")) {
                dateFormats.insert(id)
            }
        }
        let dateStyles: Set<Int> = Set(children(children(styles, "cellXfs").first, "xf").enumerated().compactMap { i, xf in
            attr(xf, "numFmtId").flatMap(Int.init).map { dateFormats.contains($0) ? i : -1 }
        }.filter { $0 >= 0 })

        var targets: [String: String] = [:]
        for rel in children(xml(xl.appendingPathComponent("_rels/workbook.xml.rels")), "Relationship") {
            if let id = attr(rel, "Id"), let target = attr(rel, "Target") { targets[id] = target }
        }

        return children(children(workbook, "sheets").first, "sheet").compactMap { sheet in
            let name = attr(sheet, "name") ?? "Sheet"
            guard let id = attr(sheet, "id"), var target = targets[id] else { return nil }
            if target.hasPrefix("/") { target = String(target.dropFirst()) } else { target = "xl/" + target }
            guard let root = xml(dir.appendingPathComponent(target)) else { return nil }
            var rows: [[String]] = []
            for row in children(children(root, "sheetData").first, "row") {
                let r = (attr(row, "r").flatMap(Int.init) ?? rows.count + 1) - 1
                guard r < 1_000_000 else { break }
                while rows.count <= r { rows.append([]) }
                var next = 0
                for cell in children(row, "c") {
                    let col = attr(cell, "r").flatMap(columnIndex) ?? next
                    next = col + 1
                    let raw = children(cell, "v").first?.stringValue ?? ""
                    let value: String
                    switch attr(cell, "t") {
                    case "s": value = Int(raw).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? ""
                    case "inlineStr": value = children(cell, "is").first.map(text) ?? ""
                    case "b": value = raw == "1" ? "TRUE" : "FALSE"
                    case "str", "e": value = raw
                    default:
                        let style = attr(cell, "s").flatMap(Int.init) ?? 0
                        value = dateStyles.contains(style) ? excelDate(raw) : number(raw)
                    }
                    guard !value.isEmpty else { continue }
                    while rows[r].count <= col { rows[r].append("") }
                    rows[r][col] = value
                }
            }
            return Sheet(name: name, rows: trimmed(rows))
        }
    }

    /// Remove o ruído de ponto flutuante (0.30000000000000004 → 0.3).
    private static func number(_ raw: String) -> String {
        guard let d = Double(raw) else { return raw }
        if d == d.rounded() && abs(d) < 1e15 { return String(Int64(d)) }
        return String(format: "%.15g", d)
    }

    private static func excelDate(_ raw: String) -> String {
        guard let serial = Double(raw) else { return raw }
        // Excel conta dias desde 30/12/1899.
        let date = Date(timeIntervalSince1970: (serial - 25569) * 86400)
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = serial.truncatingRemainder(dividingBy: 1) == 0 ? "yyyy-MM-dd" : (serial < 1 ? "HH:mm:ss" : "yyyy-MM-dd HH:mm:ss")
        return f.string(from: date)
    }

    private static func readODS(_ src: URL) throws -> [Sheet] {
        let dir = try unzip(src)
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let content = xml(dir.appendingPathComponent("content.xml")),
              let spreadsheet = children(children(content, "body").first, "spreadsheet").first else {
            throw ToolError.failed(L("Planilha ODS inválida.", "Invalid ODS spreadsheet."))
        }
        return children(spreadsheet, "table").map { table in
            var rows: [[String]] = []
            for row in children(table, "table-row") {
                var cells: [String] = []
                for cell in children(row, "table-cell") + children(row, "covered-table-cell") {
                    let value = attr(cell, "value").map(number) ?? attr(cell, "date-value")
                        ?? children(cell, "p").map { $0.stringValue ?? "" }.joined(separator: "\n")
                    // Células vazias repetidas (comum no fim das linhas) são limitadas.
                    let repeats = min(attr(cell, "number-columns-repeated").flatMap(Int.init) ?? 1, value.isEmpty ? 256 : 1024)
                    cells += Array(repeating: value, count: repeats)
                }
                let repeats = min(attr(row, "number-rows-repeated").flatMap(Int.init) ?? 1, cells.allSatisfy(\.isEmpty) ? 64 : 1024)
                rows += Array(repeating: cells, count: repeats)
            }
            return Sheet(name: attr(table, "name") ?? "Sheet", rows: trimmed(rows))
        }
    }

    private static func readDelimited(_ src: URL) throws -> [[String]] {
        let data = try Data(contentsOf: src)
        guard var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else {
            throw ToolError.failed(L("Codificação de texto desconhecida.", "Unknown text encoding."))
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let firstLine = text.prefix { $0 != "\n" }
        let delimiter: Character = src.pathExtension.lowercased() == "tsv" ? "\t"
            : firstLine.filter { $0 == ";" }.count > firstLine.filter { $0 == "," }.count ? ";" : ","

        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = Array(text)
        chars.append("\n")
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == delimiter {
                row.append(field)
                field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(c)
            }
            i += 1
        }
        return trimmed(rows)
    }

    /// Tira linhas e colunas vazias do fim.
    private static func trimmed(_ rows: [[String]]) -> [[String]] {
        var rows = rows.map { row -> [String] in
            var r = row
            while r.last?.isEmpty == true { r.removeLast() }
            return r
        }
        while rows.last?.isEmpty == true { rows.removeLast() }
        return rows
    }

    // MARK: Gravação

    /// CSV com separador ";" quando o sistema usa vírgula decimal (Excel em português espera isso).
    private static func delimited(_ sheet: Sheet, ext: String) -> Data {
        let separator = ext == "tsv" ? "\t" : (Locale.current.decimalSeparator == "," ? ";" : ",")
        let lines = sheet.rows.map { row in
            row.map { value in
                let field = separator == ";" && numeric(value) != nil ? value.replacingOccurrences(of: ".", with: ",") : value
                return field.contains(separator) || field.contains("\"") || field.contains("\n")
                    ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
            }.joined(separator: separator)
        }
        let body = lines.joined(separator: "\r\n") + "\r\n"
        return Data(((ext == "csv" ? "\u{FEFF}" : "") + body).utf8)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .unicodeScalars.filter { $0.value >= 32 || $0 == "\n" || $0 == "\t" }.map(String.init).joined()
    }

    private static func numeric(_ s: String) -> Double? {
        guard s.range(of: #"^-?\d+(\.\d+)?([eE][-+]?\d+)?$"#, options: .regularExpression) != nil else { return nil }
        return Double(s)
    }

    private static func columnName(_ i: Int) -> String {
        var n = i + 1
        var name = ""
        while n > 0 {
            let r = (n - 1) % 26
            name = String(UnicodeScalar(65 + r)!) + name
            n = (n - 1) / 26
        }
        return name
    }

    private static func pack(_ dir: URL, to out: URL, storedFirst: String? = nil) throws {
        if let first = storedFirst {
            try Shell.run("/usr/bin/zip", ["-X", "-0", "-q", out.path, first], cwd: dir)
        }
        let items = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0 != storedFirst }
        try Shell.run("/usr/bin/zip", ["-X", "-9", "-r", "-q", out.path] + items, cwd: dir)
    }

    private static func writeFiles(_ files: [String: String], to dir: URL) throws {
        for (path, content) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }
    }

    private static func writeXLSX(_ sheets: [Sheet], to out: URL) throws {
        let head = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        var files: [String: String] = [:]
        var sheetEntries = "", relEntries = "", overrides = ""
        var usedNames: Set<String> = []
        for (i, sheet) in sheets.enumerated() {
            var name = String(sheet.name.filter { !"[]:*?/\\".contains($0) }.prefix(31))
            if name.isEmpty || usedNames.contains(name) { name = "Sheet\(i + 1)" }
            usedNames.insert(name)
            sheetEntries += #"<sheet name="\#(escape(name))" sheetId="\#(i + 1)" r:id="rId\#(i + 1)"/>"#
            relEntries += #"<Relationship Id="rId\#(i + 1)" Type="\#(rel)/worksheet" Target="worksheets/sheet\#(i + 1).xml"/>"#
            overrides += #"<Override PartName="/xl/worksheets/sheet\#(i + 1).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
            var data = ""
            for (r, row) in sheet.rows.enumerated() {
                data += #"<row r="\#(r + 1)">"#
                for (c, value) in row.enumerated() where !value.isEmpty {
                    let ref = columnName(c) + String(r + 1)
                    if numeric(value) != nil {
                        data += #"<c r="\#(ref)"><v>\#(value)</v></c>"#
                    } else {
                        data += #"<c r="\#(ref)" t="inlineStr"><is><t xml:space="preserve">\#(escape(value))</t></is></c>"#
                    }
                }
                data += "</row>"
            }
            files["xl/worksheets/sheet\(i + 1).xml"] = "\(head)<worksheet xmlns=\"\(main)\"><sheetData>\(data)</sheetData></worksheet>"
        }
        let styleRel = sheets.count + 1
        files["[Content_Types].xml"] = """
        \(head)<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
        \(overrides)</Types>
        """
        files["_rels/.rels"] = """
        \(head)<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="\(rel)/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """
        files["xl/workbook.xml"] = "\(head)<workbook xmlns=\"\(main)\" xmlns:r=\"\(rel)\"><sheets>\(sheetEntries)</sheets></workbook>"
        files["xl/_rels/workbook.xml.rels"] = """
        \(head)<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(relEntries)\
        <Relationship Id="rId\(styleRel)" Type="\(rel)/styles" Target="styles.xml"/></Relationships>
        """
        files["xl/styles.xml"] = """
        \(head)<styleSheet xmlns="\(main)"><fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>\
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs></styleSheet>
        """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFiles(files, to: dir)
        try pack(dir, to: out)
    }

    private static func writeODS(_ sheets: [Sheet], to out: URL) throws {
        let head = #"<?xml version="1.0" encoding="UTF-8"?>"#
        var tables = ""
        for sheet in sheets {
            tables += #"<table:table table:name="\#(escape(sheet.name))">"#
            let columns = sheet.rows.map(\.count).max() ?? 0
            for row in sheet.rows {
                tables += "<table:table-row>"
                for c in 0..<max(columns, 1) {
                    let value = c < row.count ? row[c] : ""
                    if value.isEmpty {
                        tables += "<table:table-cell/>"
                    } else if numeric(value) != nil {
                        tables += #"<table:table-cell office:value-type="float" office:value="\#(value)"><text:p>\#(value)</text:p></table:table-cell>"#
                    } else {
                        let paragraphs = value.components(separatedBy: "\n").map { "<text:p>\(escape($0))</text:p>" }.joined()
                        tables += #"<table:table-cell office:value-type="string">\#(paragraphs)</table:table-cell>"#
                    }
                }
                tables += "</table:table-row>"
            }
            tables += "</table:table>"
        }
        let files = [
            "META-INF/manifest.xml": """
            \(head)<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">\
            <manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/>\
            <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/></manifest:manifest>
            """,
            "content.xml": """
            \(head)<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
            xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" \
            office:version="1.2"><office:body><office:spreadsheet>\(tables)</office:spreadsheet></office:body></office:document-content>
            """,
        ]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeFiles(files, to: dir)
        try Data("application/vnd.oasis.opendocument.spreadsheet".utf8).write(to: dir.appendingPathComponent("mimetype"))
        try pack(dir, to: out, storedFirst: "mimetype")
    }

    // MARK: PDF

    /// Desenha as tabelas direto no PDF: larguras calculadas pelo conteúdo, cabeçalho repetido em cada página.
    private static func renderPDF(_ sheets: [Sheet], to out: URL) throws {
        let margin: CGFloat = 32, pad: CGFloat = 4
        let portrait = CGSize(width: 595, height: 842)
        var mediaBox = CGRect(origin: .zero, size: portrait)
        guard let pdf = CGContext(out as CFURL, mediaBox: &mediaBox, nil) else {
            throw ToolError.failed(L("Falha ao criar o PDF.", "Failed to create the PDF."))
        }

        func attrs(_ size: CGFloat, bold: Bool = false, right: Bool = false) -> [NSAttributedString.Key: Any] {
            let style = NSMutableParagraphStyle()
            style.alignment = right ? .right : .left
            style.lineBreakMode = .byWordWrapping
            return [.font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
                    .foregroundColor: NSColor.black, .paragraphStyle: style]
        }
        func width(_ s: String, _ a: [NSAttributedString.Key: Any]) -> CGFloat {
            s.components(separatedBy: "\n").map { ceil(($0 as NSString).size(withAttributes: a).width) }.max() ?? 0
        }
        func height(_ s: String, _ w: CGFloat, _ a: [NSAttributedString.Key: Any]) -> CGFloat {
            ceil((s as NSString).boundingRect(with: CGSize(width: w, height: 10_000), options: [.usesLineFragmentOrigin], attributes: a).height)
        }

        for sheet in sheets {
            let columns = sheet.rows.map(\.count).max() ?? 0
            guard columns > 0 else { continue }
            let rows = sheet.rows.map { $0 + Array(repeating: "", count: columns - $0.count) }

            // Largura natural de cada coluna: célula mais larga (até 220 pt) e a palavra mais longa do cabeçalho.
            func natural(_ size: CGFloat) -> (full: [CGFloat], minimum: [CGFloat]) {
                var full = [CGFloat](repeating: 0, count: columns), minimum = full
                for (r, row) in rows.prefix(2000).enumerated() {
                    let a = attrs(size, bold: r == 0)
                    for (c, value) in row.enumerated() {
                        full[c] = max(full[c], min(220, width(value, a)))
                        let longestWord = value.split(whereSeparator: \.isWhitespace).map { width(String($0), a) }.max() ?? 0
                        minimum[c] = max(minimum[c], min(120, longestWord))
                    }
                }
                return (full.map { $0 + pad * 2 }, minimum.map { $0 + pad * 2 })
            }

            // Escolhe orientação e fonte para caber; se ainda não couber, as colunas quebram o texto.
            var size: CGFloat = 9
            var page = portrait
            var (full, minimum) = natural(size)
            if full.reduce(0, +) > portrait.width - margin * 2 { page = CGSize(width: portrait.height, height: portrait.width) }
            let usable = page.width - margin * 2
            while minimum.reduce(0, +) > usable && size > 5.5 {
                size -= 0.5
                (full, minimum) = natural(size)
            }
            var widths = full
            if full.reduce(0, +) > usable {
                // Distribui o espaço extra além do mínimo proporcionalmente ao que cada coluna gostaria de ter.
                let extra = max(0, usable - minimum.reduce(0, +))
                let wanted = zip(full, minimum).map { max(0, $0 - $1) }
                let totalWanted = max(1, wanted.reduce(0, +))
                widths = zip(minimum, wanted).map { $0 + extra * $1 / totalWanted }
            }

            var box = CGRect(origin: .zero, size: page)
            var y: CGFloat = 0
            let header = rows[0]

            func newPage() {
                pdf.beginPage(mediaBox: &box)
                NSGraphicsContext.saveGraphicsState()
                pdf.translateBy(x: 0, y: page.height)
                pdf.scaleBy(x: 1, y: -1)
                NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: true)
                y = margin
                if sheets.count > 1 {
                    (sheet.name as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: attrs(11, bold: true))
                    y += 20
                }
            }
            func endPage() {
                NSGraphicsContext.restoreGraphicsState()
                pdf.endPage()
            }
            func drawRow(_ row: [String], isHeader: Bool) {
                let heights = row.enumerated().map { c, v in height(v, widths[c] - pad * 2, attrs(size, bold: isHeader)) }
                let h = max(size + 4, heights.max() ?? 0) + pad * 2
                if y + h > page.height - margin {
                    endPage()
                    newPage()
                    if !isHeader { drawRow(header, isHeader: true) }
                }
                var x = margin
                for (c, value) in row.enumerated() {
                    let cell = CGRect(x: x, y: y, width: widths[c], height: h)
                    if isHeader {
                        pdf.setFillColor(CGColor(gray: 0.92, alpha: 1))
                        pdf.fill(cell)
                    }
                    pdf.setStrokeColor(CGColor(gray: 0.72, alpha: 1))
                    pdf.setLineWidth(0.5)
                    pdf.stroke(cell)
                    let a = attrs(size, bold: isHeader, right: !isHeader && numeric(value) != nil)
                    (value as NSString).draw(with: cell.insetBy(dx: pad, dy: pad), options: [.usesLineFragmentOrigin], attributes: a)
                    x += widths[c]
                }
                y += h
            }

            newPage()
            for (r, row) in rows.enumerated() { drawRow(row, isHeader: r == 0) }
            endPage()
        }
        pdf.closePDF()
    }

    private static func html(_ sheets: [Sheet], title: String) -> String {
        var body = ""
        for sheet in sheets {
            if sheets.count > 1 { body += "<h2>\(escape(sheet.name))</h2>" }
            body += "<table>"
            let columns = sheet.rows.map(\.count).max() ?? 0
            for (r, row) in sheet.rows.enumerated() {
                body += "<tr>"
                for c in 0..<columns {
                    let value = c < row.count ? row[c] : ""
                    let tag = r == 0 ? "th" : "td"
                    let align = numeric(value) != nil ? " class=\"n\"" : ""
                    body += "<\(tag)\(align)>\(escape(value).replacingOccurrences(of: "\n", with: "<br>"))</\(tag)>"
                }
                body += "</tr>"
            }
            body += "</table>"
        }
        // Tabelas largas usam fonte menor para os cabeçalhos não quebrarem no meio da palavra.
        let columns = sheets.map { $0.rows.map(\.count).max() ?? 0 }.max() ?? 0
        let fontSize = max(6.5, 10 - Double(max(0, columns - 6)) * 0.35)
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>\(escape(title))</title><style>
        body{font-family:-apple-system,Helvetica,sans-serif;font-size:\(String(format: "%.1f", fontSize))pt}
        table{border-collapse:collapse;margin-bottom:18pt}
        th,td{border:0.5pt solid #bbb;padding:2pt 4pt;vertical-align:top}
        th{background:#eee;font-weight:bold}
        td.n{text-align:right}
        h2{font-size:12pt}
        </style></head><body>\(body)</body></html>
        """
    }
}
