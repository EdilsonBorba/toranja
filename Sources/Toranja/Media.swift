import Foundation

/// Vídeo e áudio via ffmpeg (Homebrew).
enum Media {
    static let videoTargets = ["mp4", "mov", "webm", "mkv", "gif", "mp3", "m4a", "wav"]
    static let audioTargets = ["mp3", "m4a", "wav", "flac", "aiff", "opus"]

    static func ffmpeg(_ args: [String]) throws {
        try Shell.run("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y"] + args)
    }

    static func hasAudio(_ url: URL) -> Bool {
        let out = try? Shell.run("ffprobe", ["-v", "error", "-select_streams", "a", "-show_entries", "stream=index",
                                             "-of", "csv=p=0", url.path])
        return !(out ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static let evenSize = "scale=trunc(iw/2)*2:trunc(ih/2)*2"
    private static let h264 = ["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p"]
    private static let aac = ["-c:a", "aac", "-b:a", "192k"]

    private static func audioArgs(_ ext: String) -> [String] {
        let kbps = Settings.shared.audioQuality.kbps
        return switch ext {
        case "mp3": ["-c:a", "libmp3lame", "-b:a", "\(kbps)k"]
        case "m4a", "aac": ["-c:a", "aac", "-b:a", "\(min(kbps, 256))k"]
        case "wav": ["-c:a", "pcm_s16le"]
        case "flac": ["-c:a", "flac"]
        case "aiff", "aif": ["-c:a", "pcm_s16be"]
        case "opus", "ogg": ["-c:a", "libopus", "-b:a", "\(kbps * 6 / 10)k"]
        default: []
        }
    }

    private static func videoExt(_ src: URL) -> String {
        let ext = src.pathExtension.lowercased()
        return ["mp4", "mov", "m4v"].contains(ext) ? ext : "mp4"
    }

    private static func isVideo(_ src: URL) -> Bool { FileKind(src) == .video }

    /// Codecs de saída mantendo o tipo do original (vídeo recodificado em H.264, áudio no formato da extensão).
    private static func outputArgs(_ src: URL, video: [String] = h264) -> (ext: String, args: [String]) {
        if isVideo(src) {
            return (videoExt(src), video + (hasAudio(src) ? aac : ["-an"]) + ["-movflags", "+faststart"])
        }
        let ext = src.pathExtension.lowercased()
        return (ext, ["-vn"] + audioArgs(ext))
    }

    static func convert(_ src: URL, to ext: String) throws -> URL {
        let out = Output.url(for: src, ext: ext)
        var args = ["-i", src.path]
        switch ext {
        case "mp4", "mov":
            args += ["-vf", evenSize] + h264 + aac + ["-movflags", "+faststart"]
        case "mkv":
            args += ["-vf", evenSize] + h264 + aac
        case "webm":
            args += ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus", "-b:a", "128k"]
        case "gif":
            args += ["-vf", "fps=15,scale='min(720,iw)':-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse",
                     "-loop", "0"]
        default:
            args += ["-vn"] + audioArgs(ext)
        }
        try ffmpeg(args + [out.path])
        return out
    }

    static func compress(_ src: URL) throws -> URL {
        var args = ["-i", src.path]
        let out: URL
        let suffix = L("comprimido", "compressed")
        if !isVideo(src) {
            let isMP3 = src.pathExtension.lowercased() == "mp3"
            out = Output.url(for: src, ext: isMP3 ? "mp3" : "m4a", suffix: suffix)
            args += ["-vn"] + (isMP3 ? ["-c:a", "libmp3lame", "-b:a", "128k"] : ["-c:a", "aac", "-b:a", "128k"])
        } else {
            out = Output.url(for: src, ext: "mp4", suffix: suffix)
            let h = Settings.shared.maxVideoHeight
            let scale = h > 0 ? "scale=-2:'min(\(h),ih)',\(evenSize)" : evenSize
            let crf = Settings.shared.videoCompression == .strong ? "32" : "28"
            args += ["-vf", scale, "-c:v", "libx264", "-crf", crf, "-preset", "medium", "-pix_fmt", "yuv420p",
                     "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart"]
        }
        try ffmpeg(args + [out.path])
        try Output.notSmaller(out, than: src)
        return out
    }

    // MARK: Velocidade

    static func speedLabel(_ factor: Double) -> String {
        let text = factor == factor.rounded() ? String(Int(factor)) : String(factor)
        return L(text.replacingOccurrences(of: ".", with: ","), text) + "×"
    }

    /// atempo aceita 0,5–2 por etapa; encadeia quando precisa de mais.
    private static func atempo(_ factor: Double) -> String {
        var f = factor
        var parts: [String] = []
        while f > 2 { parts.append("atempo=2"); f /= 2 }
        while f < 0.5 { parts.append("atempo=0.5"); f /= 0.5 }
        parts.append("atempo=\(f)")
        return parts.joined(separator: ",")
    }

    static func speed(_ src: URL, factor: Double) throws -> URL {
        let label = speedLabel(factor)
        if !isVideo(src) {
            let out = Output.url(for: src, ext: src.pathExtension, suffix: label)
            try ffmpeg(["-i", src.path, "-filter:a", atempo(factor)] + audioArgs(src.pathExtension.lowercased()) + [out.path])
            return out
        }
        let out = Output.url(for: src, ext: videoExt(src), suffix: label)
        var args = ["-i", src.path, "-filter:v", "setpts=PTS/\(factor)"]
        args += hasAudio(src) ? ["-filter:a", atempo(factor)] + aac : ["-an"]
        try ffmpeg(args + h264 + [out.path])
        return out
    }

    // MARK: Cortar e bleep

    private static func seconds(_ t: Double) -> String { String(format: "%.3f", t) }

    static func trim(_ src: URL, start: Double, end: Double) throws -> URL {
        let (ext, codec) = outputArgs(src, video: ["-c:v", "libx264", "-crf", "18", "-preset", "medium", "-pix_fmt", "yuv420p"])
        let out = Output.url(for: src, ext: ext, suffix: L("cortado", "trimmed"))
        try ffmpeg(["-ss", seconds(start), "-i", src.path, "-t", seconds(end - start)] + codec + [out.path])
        return out
    }

    /// Silencia os trechos e coloca um bipe de 1 kHz no lugar.
    static func bleep(_ src: URL, ranges: [(Double, Double)]) throws -> URL {
        let cond = ranges.map { "between(t,\(seconds($0.0)),\(seconds($0.1)))" }.joined(separator: "+")
        let stereo = "aformat=sample_rates=48000:channel_layouts=stereo"
        let filter = "[0:a]\(stereo),volume=0:enable='\(cond)'[m];"
            + "[1:a]\(stereo),volume=0.22,volume=0:enable='not(\(cond))'[b];"
            + "[m][b]amix=inputs=2:duration=first:normalize=0[a]"
        var args = ["-i", src.path, "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000",
                    "-filter_complex", filter, "-map", "[a]"]
        let ext: String
        if isVideo(src) {
            ext = videoExt(src)
            args += ["-map", "0:v", "-c:v", "copy"] + aac
        } else {
            ext = src.pathExtension.lowercased()
            args += audioArgs(ext)
        }
        let out = Output.url(for: src, ext: ext, suffix: "bleep")
        try ffmpeg(args + ["-shortest", out.path])
        return out
    }

    // MARK: Áudio

    static func removeAudio(_ src: URL) throws -> URL {
        let out = Output.url(for: src, ext: src.pathExtension, suffix: L("sem áudio", "muted"))
        try ffmpeg(["-i", src.path, "-c:v", "copy", "-an", out.path])
        return out
    }

    static func normalize(_ src: URL) throws -> URL {
        let out = Output.url(for: src, ext: src.pathExtension, suffix: L("normalizado", "normalized"))
        var args = ["-i", src.path, "-af", "loudnorm=I=-16:TP=-1.5:LRA=11"]
        if isVideo(src) { args += ["-c:v", "copy"] + aac }
        else { args += audioArgs(src.pathExtension.lowercased()) }
        try ffmpeg(args + [out.path])
        return out
    }

    enum ChannelMode: CaseIterable {
        case mono, stereo, left, right, swap

        var title: String {
            switch self {
            case .mono: "Mono"
            case .stereo: L("Estéreo", "Stereo")
            case .left: L("Só o canal esquerdo", "Left channel only")
            case .right: L("Só o canal direito", "Right channel only")
            case .swap: L("Inverter esquerdo e direito", "Swap left and right")
            }
        }

        var suffix: String {
            switch self {
            case .mono: "mono"
            case .stereo: L("estéreo", "stereo")
            case .left: L("esquerdo", "left")
            case .right: L("direito", "right")
            case .swap: L("invertido", "swapped")
            }
        }

        var args: [String] {
            switch self {
            case .mono: ["-ac", "1"]
            case .stereo: ["-ac", "2"]
            case .left: ["-af", "pan=mono|c0=c0"]
            case .right: ["-af", "pan=mono|c0=c1"]
            case .swap: ["-af", "pan=stereo|c0=c1|c1=c0"]
            }
        }
    }

    static func channels(_ src: URL, mode: ChannelMode) throws -> URL {
        let out = Output.url(for: src, ext: src.pathExtension, suffix: mode.suffix)
        var args = ["-i", src.path] + mode.args
        if isVideo(src) { args += ["-c:v", "copy"] + aac }
        else { args += audioArgs(src.pathExtension.lowercased()) }
        try ffmpeg(args + [out.path])
        return out
    }

    static func trimSilence(_ src: URL) throws -> URL {
        let out = Output.url(for: src, ext: src.pathExtension, suffix: L("sem silêncio", "no silence"))
        let trim = "silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.1"
        try ffmpeg(["-i", src.path, "-af", "\(trim),areverse,\(trim),areverse"]
                   + audioArgs(src.pathExtension.lowercased()) + [out.path])
        return out
    }

    static func stripMetadata(_ src: URL) throws -> URL {
        let out = Output.url(for: src, ext: src.pathExtension, suffix: L("sem metadados", "no metadata"))
        try ffmpeg(["-i", src.path, "-map", "0", "-map_metadata", "-1", "-map_chapters", "-1",
                    "-fflags", "+bitexact", "-c", "copy", out.path])
        return out
    }

    // MARK: Visualizador

    enum VisualizerStyle: CaseIterable {
        case waves, bars, spectrum

        var title: String {
            switch self {
            case .waves: L("Ondas", "Waves")
            case .bars: L("Barras", "Bars")
            case .spectrum: L("Espectro", "Spectrum")
            }
        }
    }

    static func visualizer(_ src: URL, style: VisualizerStyle, background: URL?) throws -> URL {
        let out = Output.url(for: src, ext: "mp4", suffix: L("visualizador", "visualizer"))
        var args = ["-i", src.path]
        if let background {
            args += ["-loop", "1", "-i", background.path]
        } else {
            args += ["-f", "lavfi", "-i", "color=c=0x141C2B:s=1280x720:r=30"]
        }
        let bg = "[1:v]scale=1280:720:force_original_aspect_ratio=increase,crop=1280:720,setsar=1,format=rgba[bg]"
        let viz: String = switch style {
        case .waves: "showwaves=s=1200x300:mode=cline:rate=30:colors=0xFFFFFF@0.95"
        case .bars: "showfreqs=s=1200x320:mode=bar:ascale=sqrt:fscale=log:win_size=2048:colors=0xFA6B61"
        case .spectrum: "showspectrum=s=1280x720:mode=combined:color=intensity:slide=scroll:scale=cbrt"
        }
        let filter = style == .spectrum
            ? "[0:a]\(viz),format=yuv420p[v]"
            : "\(bg);[0:a]\(viz),format=rgba[w];[bg][w]overlay=(W-w)/2:(H-h)/2:shortest=1,format=yuv420p[v]"
        args += ["-filter_complex", filter, "-map", "[v]", "-map", "0:a", "-r", "30"] + h264 + aac + ["-shortest", out.path]
        try ffmpeg(args)
        return out
    }
}
