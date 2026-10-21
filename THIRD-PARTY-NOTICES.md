# Third-party software / Software de terceiros

Toranja's own source code is MIT-licensed (see `LICENSE`). The downloadable app also ships the
open-source components below, each under its own license. Their license texts are inside the app at
`Toranja.app/Contents/Resources/Licenses` (and `Contents/Resources/Runtime/legal` for OpenJDK).

O código do Toranja é MIT (veja `LICENSE`). O app para download também leva os componentes abaixo,
cada um com sua própria licença. Os textos das licenças estão dentro do app, em
`Toranja.app/Contents/Resources/Licenses` (e `Contents/Resources/Runtime/legal` para o OpenJDK).

## Bundled programs / Programas embutidos

| Component | Version | License | Used for |
|---|---|---|---|
| [FFmpeg](https://ffmpeg.org) (`ffmpeg`, `ffprobe`) | 8.0.1 | **GPL v3** (built with `--enable-gpl --enable-version3`) | Video, audio, GIF, WebP, AVIF |
| ↳ [x264](https://www.videolan.org/developers/x264.html) | stable `b35605ac` | GPL v2+ | H.264 video |
| ↳ [LAME](https://lame.sourceforge.io) | 3.100 | LGPL v2+ | MP3 |
| ↳ [Opus](https://opus-codec.org) | 1.5.2 | BSD-3-Clause | Opus audio |
| ↳ [libvpx](https://chromium.googlesource.com/webm/libvpx) | 1.15.2 | BSD-3-Clause | WebM / VP9 |
| ↳ [libaom](https://aomedia.googlesource.com/aom) | 3.13.1 | BSD-2-Clause + AOM patent license | AVIF |
| ↳ [libwebp](https://chromium.googlesource.com/webm/libwebp) | 1.6.0 | BSD-3-Clause | WebP |
| [OpenJDK](https://adoptium.net) runtime (Eclipse Temurin, trimmed with `jlink`) | 11 | GPL v2 + Classpath Exception | Runs the Office converter |

FFmpeg and its libraries are separate programs that Toranja runs as external processes; they are
not linked into Toranja itself.

### GPL source code / Código-fonte GPL

The exact source code used to build the bundled `ffmpeg`/`ffprobe` is attached to every release as
`Toranja-<version>-ffmpeg-sources.tar`, together with `scripts/build-ffmpeg.sh`, which builds it.
The same script downloads it from the official sites listed above.

O código-fonte exato usado para compilar o `ffmpeg`/`ffprobe` embutido acompanha cada versão em
`Toranja-<versão>-ffmpeg-sources.tar`, junto com `scripts/build-ffmpeg.sh`, que o compila.

## Office converter libraries / Bibliotecas do conversor Office

| Component | Version | License |
|---|---|---|
| [Apache POI](https://poi.apache.org) | 5.5.1 | Apache 2.0 |
| [Apache PDFBox](https://pdfbox.apache.org) (+ FontBox, graphics2d) | 3.0.6 / 3.0.5 | Apache 2.0 |
| Apache Commons (Codec, Collections, Compress, IO, Lang, Logging, Math) | — | Apache 2.0 |
| [Apache XMLBeans](https://xmlbeans.apache.org), [Log4j API](https://logging.apache.org/log4j) | 5.3.0 / 2.24.3 | Apache 2.0 |
| [SparseBitSet](https://github.com/brettwooldridge/SparseBitSet) | 1.3 | Apache 2.0 |
| [curvesapi](https://github.com/virtuald/curvesapi) | 1.08 | BSD-3-Clause |
| [docx-preview](https://github.com/VolodymyrBaydalka/docxjs) | 0.4.1 | Apache 2.0 |
| [JSZip](https://stuk.github.io/jszip/) | 3.10.1 | MIT (dual MIT/GPLv3; used under MIT) |
| [cupertino-files](https://github.com/den-frie-vilje/cupertino-files) | 0.4.0 | MIT (includes parts under Apache 2.0, MPL 2.0 and BSD-3-Clause; see `Licenses/cupertino-files`) |

The NOTICE and LICENSE files of the Apache components are kept inside each `.jar` and copied to
`Licenses/java/`.
