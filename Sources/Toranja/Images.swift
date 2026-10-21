import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

enum Images {
    static let targets = ["jpg", "webp", "heic", "tiff", "avif", "bmp", "pdf", "png", "gif"]

    static func source(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ToolError.failed(L("Não foi possível abrir a imagem.", "Couldn't open the image."))
        }
        return source
    }

    static func pixelSize(_ source: CGImageSource) -> CGSize {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        return CGSize(width: props[kCGImagePropertyPixelWidth] as? Int ?? 0,
                      height: props[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    /// Carrega a imagem com a orientação EXIF já aplicada, opcionalmente reduzida.
    static func load(_ url: URL, maxPixel: Int? = nil) throws -> CGImage {
        if url.pathExtension.lowercased() == "svg" { return try rasterizeSVG(url, maxPixel: maxPixel) }
        let source = try source(url)
        let size = pixelSize(source)
        let longest = Int(max(size.width, size.height))
        if longest > 0 {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: min(maxPixel ?? longest, longest),
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) { return image }
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ToolError.failed(L("Não foi possível ler a imagem.", "Couldn't read the image."))
        }
        return image
    }

    /// SVG é vetorial: desenha no tamanho pedido (padrão: lado maior com pelo menos 2048 px).
    private static func rasterizeSVG(_ url: URL, maxPixel: Int?) throws -> CGImage {
        guard let svg = NSImage(contentsOf: url), svg.size.width > 0, svg.size.height > 0 else {
            throw ToolError.failed(L("Não foi possível abrir o SVG.", "Couldn't open the SVG."))
        }
        let longest = max(svg.size.width, svg.size.height)
        let scale = CGFloat(maxPixel ?? max(2048, Int(longest))) / longest
        let w = max(1, Int(svg.size.width * scale)), h = max(1, Int(svg.size.height * scale))
        guard let ctx = context(width: w, height: h) else { throw ToolError.failed(L("Imagem grande demais.", "Image too large.")) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        svg.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage() else { throw ToolError.failed(L("Falha ao gerar a imagem.", "Failed to create the image.")) }
        return image
    }

    /// EXIF, GPS, TIFF e IPTC do original, com a orientação zerada (a imagem já foi girada ao carregar).
    static func metadata(of url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [:] }
        var out: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let value = props[key] { out[key] = value }
        }
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            out[kCGImagePropertyTIFFDictionary] = tiff
        }
        out[kCGImagePropertyOrientation] = 1
        return out
    }

    static func type(for ext: String) -> UTType? {
        UTType(filenameExtension: ext == "jpg" ? "jpeg" : ext)
    }

    static func encode(_ image: CGImage, type: UTType, quality: Double, properties: [CFString: Any] = [:]) throws -> Data {
        switch type.preferredFilenameExtension {
        case "webp": return try encodeExternal(image, ext: "webp", quality: quality)
        case "avif": return try encodeExternal(image, ext: "avif", quality: quality)
        default: break
        }
        let img = (type == .jpeg || type == .bmp) ? flattened(image) : image
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ToolError.failed(L("Formato não suportado para gravação.", "Format not supported for writing."))
        }
        let options = properties.merging([kCGImageDestinationLossyCompressionQuality: quality]) { _, new in new }
        CGImageDestinationAddImage(dest, img, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ToolError.failed(L("Falha ao gerar a imagem.", "Failed to create the image.")) }
        return data as Data
    }

    static func write(_ image: CGImage, to url: URL, type: UTType, quality: Double = 0.9, properties: [CFString: Any] = [:]) throws {
        try encode(image, type: type, quality: quality, properties: properties).write(to: url)
    }

    /// O ImageIO não grava WebP nem AVIF: usamos cwebp/ffmpeg a partir de um PNG temporário.
    private static func encodeExternal(_ image: CGImage, ext: String, quality: Double) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = tmp.appendingPathExtension("png"), out = tmp.appendingPathExtension(ext)
        defer {
            try? FileManager.default.removeItem(at: png)
            try? FileManager.default.removeItem(at: out)
        }
        try write(image, to: png, type: .png)
        if ext == "avif" {
            let crf = String(Int(60 - quality * 40))
            try Media.ffmpeg(["-i", png.path, "-c:v", "libaom-av1", "-still-picture", "1", "-crf", crf,
                              "-cpu-used", "6", "-pix_fmt", "yuv420p", out.path])
        } else {
            try Media.ffmpeg(["-i", png.path, "-c:v", "libwebp", "-quality", String(Int(quality * 100)), out.path])
        }
        return try Data(contentsOf: out)
    }

    static func flattened(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let ctx = context(width: image.width, height: image.height, alpha: false) else { return image }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    static func context(width: Int, height: Int, alpha: Bool = true) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
    }

    static func scaled(_ image: CGImage, by factor: Double) -> CGImage {
        let w = max(1, Int(Double(image.width) * factor)), h = max(1, Int(Double(image.height) * factor))
        guard let ctx = context(width: w, height: h) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    // MARK: Conversão

    static func convert(_ src: URL, to ext: String) throws -> URL {
        let out = Output.url(for: src, ext: ext)
        if ext == "pdf" {
            try toPDF([src], out: out)
            return out
        }
        guard let type = type(for: ext) else { throw ToolError.failed(L("Formato desconhecido: \(ext)", "Unknown format: \(ext)")) }
        let settings = Settings.shared
        try write(try load(src), to: out, type: type, quality: settings.quality(for: ext).value,
                  properties: settings.preserveMetadata(for: ext) ? metadata(of: src) : [:])
        return out
    }

    static func toPDF(_ urls: [URL], out: URL) throws {
        let doc = PDFDocument()
        for url in urls {
            if FileKind(url) == .pdf, let other = PDFDocument(url: url) {
                for i in 0..<other.pageCount {
                    if let page = other.page(at: i) { doc.insert(page, at: doc.pageCount) }
                }
                continue
            }
            let cg = try load(url)
            let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            guard let page = PDFPage(image: image) else { continue }
            doc.insert(page, at: doc.pageCount)
        }
        guard doc.pageCount > 0, doc.write(to: out) else { throw ToolError.failed(L("Falha ao criar o PDF.", "Failed to create the PDF.")) }
    }

    // MARK: Ferramentas

    static func compress(_ src: URL) throws -> URL {
        let ext = src.pathExtension.lowercased()
        let suffix = L("comprimido", "compressed")
        let maxSide = Settings.shared.compressionMaxSide > 0 ? Settings.shared.compressionMaxSide : nil
        let out: URL
        switch ext {
        case "png", "gif":
            // Quantização para paleta (similar ao pngquant), preservando transparência.
            out = Output.url(for: src, ext: ext, suffix: suffix)
            let strong = Settings.shared.imageCompression == .strong
            let colors = ext == "gif" || strong ? (strong ? 96 : 128) : 256
            let side = Settings.shared.compressionMaxSide
            let scale = side > 0 ? "scale='min(iw,\(side))':'min(ih,\(side))':force_original_aspect_ratio=decrease," : ""
            try Media.ffmpeg(["-i", src.path, "-vf",
                              "\(scale)split[a][b];[a]palettegen=max_colors=\(colors):reserve_transparent=1[p];[b][p]paletteuse=dither=sierra2_4a",
                              out.path])
        case "heic", "webp", "avif":
            out = Output.url(for: src, ext: ext, suffix: suffix)
            try fit(try load(src, maxPixel: maxSide), type: type(for: ext)!, out: out)
        default:
            out = Output.url(for: src, ext: "jpg", suffix: suffix)
            try fit(try load(src, maxPixel: maxSide), type: .jpeg, out: out)
        }
        try Output.notSmaller(out, than: src)
        return out
    }

    /// Usa a qualidade configurada, ou busca a maior qualidade que cabe no tamanho alvo.
    private static func fit(_ image: CGImage, type: UTType, out: URL) throws {
        let settings = Settings.shared
        guard settings.targetKB > 0 else {
            try write(image, to: out, type: type, quality: settings.imageQuality)
            return
        }
        let target = settings.targetKB * 1024
        var img = image
        for _ in 0..<8 {
            var lo = 0.05, hi = 0.95
            var best: Data?
            for _ in 0..<7 {
                let q = (lo + hi) / 2
                let data = try encode(img, type: type, quality: q)
                if data.count <= target { best = data; lo = q } else { hi = q }
            }
            if let best {
                try best.write(to: out)
                return
            }
            img = scaled(img, by: 0.75)
        }
        throw ToolError.failed(L("Não foi possível chegar a \(settings.targetKB) KB.", "Couldn't get down to \(settings.targetKB) KB."))
    }

    static func resize(_ src: URL, maxSide: Int?, factor: Double?) throws -> URL {
        let size = pixelSize(try source(src))
        let longest = Double(max(size.width, size.height))
        let target = maxSide ?? Int(longest * (factor ?? 1))
        guard target < Int(longest) else {
            throw ToolError.failed(L("A imagem já é menor que \(target) px.", "The image is already smaller than \(target) px."))
        }
        let image = try load(src, maxPixel: target)
        let ext = writableExt(src)
        let out = Output.url(for: src, ext: ext, suffix: "\(image.width)×\(image.height)")
        try write(image, to: out, type: type(for: ext)!, quality: 0.9)
        return out
    }

    static func rotate(_ src: URL) throws -> URL {
        let image = try load(src)
        let w = image.width, h = image.height
        guard let ctx = context(width: h, height: w) else { throw ToolError.failed(L("Falha ao girar.", "Failed to rotate.")) }
        // Gira 90° no sentido horário.
        ctx.translateBy(x: 0, y: CGFloat(w))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let rotated = ctx.makeImage() else { throw ToolError.failed(L("Falha ao girar.", "Failed to rotate.")) }
        let ext = writableExt(src)
        let out = Output.url(for: src, ext: ext, suffix: L("girado", "rotated"))
        try write(rotated, to: out, type: type(for: ext)!, quality: 0.92)
        return out
    }

    /// Remove EXIF, GPS, XMP e IPTC sem recomprimir (quando o formato permite).
    static func stripMetadata(_ src: URL) throws -> URL {
        let source = try source(src)
        guard let uti = CGImageSourceGetType(source) else { throw ToolError.failed(L("Formato desconhecido.", "Unknown format.")) }
        let suffix = L("sem metadados", "no metadata")
        let out = Output.url(for: src, ext: src.pathExtension, suffix: suffix)
        let metadata = CGImageMetadataCreateMutable()
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        if let orientation = props[kCGImagePropertyOrientation] as? Int, orientation != 1 {
            CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary,
                                                         kCGImagePropertyTIFFOrientation, orientation as CFNumber)
        }
        let opts: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeXMP: true,
            kCGImageMetadataShouldExcludeGPS: true,
        ]
        if let dest = CGImageDestinationCreateWithURL(out as CFURL, uti, 1, nil),
           CGImageDestinationCopyImageSource(dest, source, opts as CFDictionary, nil) {
            return out
        }
        // Formato sem cópia sem perdas: recodifica (load já aplica a orientação e descarta metadados).
        let ext = writableExt(src)
        let fallback = Output.url(for: src, ext: ext, suffix: suffix)
        try write(try load(src), to: fallback, type: type(for: ext)!, quality: 0.95)
        return fallback
    }

    // MARK: Fundo

    enum Background {
        case transparent, blur
        case color(NSColor)
        case image(URL)
    }

    /// Máscara do objeto em destaque (pessoas, animais, objetos) na resolução da imagem.
    static func subjectMask(_ image: CGImage) throws -> CIImage {
        let handler = VNImageRequestHandler(cgImage: image)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw ToolError.failed(L("Nenhum objeto em destaque encontrado.", "No prominent subject found."))
        }
        let mask = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        return CIImage(cvPixelBuffer: mask)
    }

    static func changeBackground(_ src: URL, to background: Background) throws -> URL {
        let image = try load(src)
        let foreground = CIImage(cgImage: image)
        let extent = foreground.extent
        let backdrop: CIImage
        switch background {
        case .transparent:
            backdrop = CIImage(color: .clear).cropped(to: extent)
        case .blur:
            backdrop = foreground.clampedToExtent()
                .applyingGaussianBlur(sigma: max(extent.width, extent.height) / 70)
                .cropped(to: extent)
        case .color(let color):
            backdrop = CIImage(color: CIColor(cgColor: color.cgColor)).cropped(to: extent)
        case .image(let url):
            let other = CIImage(cgImage: try load(url))
            let s = max(extent.width / other.extent.width, extent.height / other.extent.height)
            let scaled = other.transformed(by: CGAffineTransform(scaleX: s, y: s))
            backdrop = scaled.transformed(by: CGAffineTransform(translationX: (extent.width - scaled.extent.width) / 2 - scaled.extent.minX,
                                                                y: (extent.height - scaled.extent.height) / 2 - scaled.extent.minY))
                .cropped(to: extent)
        }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = foreground
        blend.backgroundImage = backdrop
        blend.maskImage = try subjectMask(image)
        guard let output = blend.outputImage,
              let cg = CIContext().createCGImage(output, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw ToolError.failed(L("Falha ao gerar a imagem.", "Failed to create the image."))
        }
        let transparent = if case .transparent = background { true } else { false }
        let ext = transparent ? "png" : writableExt(src)
        let out = Output.url(for: src, ext: ext, suffix: transparent ? L("sem fundo", "no background") : L("novo fundo", "new background"))
        try write(cg, to: out, type: type(for: ext)!, quality: 0.92)
        return out
    }

    // MARK: Colagem

    enum CollageLayout { case grid, row, column }

    static func collage(_ urls: [URL], layout: CollageLayout) throws -> URL {
        let images = try urls.map { try load($0, maxPixel: 2000) }
        let gap: CGFloat = 16
        var frames: [CGRect] = []
        var canvas = CGSize.zero

        switch layout {
        case .row:
            let h: CGFloat = 1200
            var x = gap
            for img in images {
                let w = h * CGFloat(img.width) / CGFloat(img.height)
                frames.append(CGRect(x: x, y: gap, width: w, height: h))
                x += w + gap
            }
            canvas = CGSize(width: x, height: h + gap * 2)
        case .column:
            let w: CGFloat = 1200
            let heights = images.map { w * CGFloat($0.height) / CGFloat($0.width) }
            canvas = CGSize(width: w + gap * 2, height: heights.reduce(gap) { $0 + $1 + gap })
            var top = canvas.height - gap
            for h in heights {
                frames.append(CGRect(x: gap, y: top - h, width: w, height: h))
                top -= h + gap
            }
        case .grid:
            let cols = Int(ceil(sqrt(Double(images.count))))
            let rows = Int(ceil(Double(images.count) / Double(cols)))
            let aspect = images.map { CGFloat($0.width) / CGFloat($0.height) }.reduce(0, +) / CGFloat(images.count)
            let cw: CGFloat = 1000, ch = cw / aspect
            canvas = CGSize(width: CGFloat(cols) * (cw + gap) + gap, height: CGFloat(rows) * (ch + gap) + gap)
            for i in images.indices {
                let r = i / cols, c = i % cols
                frames.append(CGRect(x: gap + CGFloat(c) * (cw + gap),
                                     y: canvas.height - gap - CGFloat(r + 1) * ch - CGFloat(r) * gap, width: cw, height: ch))
            }
        }

        guard let ctx = context(width: Int(canvas.width), height: Int(canvas.height), alpha: false) else {
            throw ToolError.failed(L("Imagem grande demais.", "Image too large."))
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: canvas))
        ctx.interpolationQuality = .high
        for (img, frame) in zip(images, frames) {
            // Preenche a célula mantendo a proporção (corta as sobras).
            let s = max(frame.width / CGFloat(img.width), frame.height / CGFloat(img.height))
            let w = CGFloat(img.width) * s, h = CGFloat(img.height) * s
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 10, cornerHeight: 10, transform: nil))
            ctx.clip()
            ctx.draw(img, in: CGRect(x: frame.midX - w / 2, y: frame.midY - h / 2, width: w, height: h))
            ctx.restoreGState()
        }
        guard let result = ctx.makeImage() else { throw ToolError.failed(L("Falha ao gerar a imagem.", "Failed to create the image.")) }
        let out = Output.unique(in: Output.directory(for: urls[0]), base: L("Colagem", "Collage"), ext: "jpg")
        try write(result, to: out, type: .jpeg, quality: 0.9)
        return out
    }

    static func barcodes(in image: CGImage) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }

    /// Extensão que conseguimos gravar mantendo o formato original, quando possível.
    static func writableExt(_ src: URL) -> String {
        let ext = src.pathExtension.lowercased()
        switch ext {
        case "jpeg", "jpg": return "jpg"
        case "png", "heic", "tiff", "gif", "webp", "bmp", "avif": return ext
        case "tif": return "tiff"
        default: return "png"
        }
    }
}
