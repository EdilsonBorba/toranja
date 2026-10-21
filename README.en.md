# Toranja 🍊

**Convert, compress and organize files without letting go of the mouse.** A free, open-source macOS
menu-bar utility. Everything runs on your Mac: no account, no subscription, no internet.

[Português](README.md) · [Download](https://github.com/EdilsonBorba/toranja/releases/latest) · [Changelog](CHANGELOG.md)

<p align="center">
  <img src="docs/images/wheel-convert.png" width="260" alt="Convert wheel">
  <img src="docs/images/wheel-actions.png" width="260" alt="Actions wheel">
  <img src="docs/images/wheel-tools.png" width="260" alt="Tools wheel">
</p>

## How it works

Start dragging one or more files and, **without dropping them**, tap a key. A wheel appears next to the
cursor. Drop the files on the slice you want.

| Key | Wheel | What it does |
|---|---|---|
| ⇧ Shift | **Convert** | Images (JPG, PNG, HEIC, WebP, AVIF, TIFF, BMP, GIF, PDF, SVG) · video (MP4, MOV, WebM, MKV, GIF) · audio (MP3, M4A, WAV, FLAC, AIFF, Opus) · documents (Word, Pages, PDF, Markdown, HTML, EPUB, RTF, TXT) · spreadsheets (Excel, Numbers, ODS, CSV, TSV) · presentations (PowerPoint, Keynote) · PDF → Word, Pages, PowerPoint, Excel, images |
| ⌃ Control | **Actions** | AirDrop · Float (floating shelf) · copy · move · zip/extract · open with · copy path · open in Terminal |
| ⌘ Command | **Tools** | Compress · strip metadata · annotate · redact (solid or blur) · change/remove background · collage · resize · rotate · read QR codes · organize, split and merge PDFs · trim · speed · bleep · volume · channels · trim silence · audio visualizer |

Wheels only show what makes sense for the files being dragged. Results are saved next to the original
(or in a folder you choose). **Nothing is ever overwritten.**

## Install

1. Download the latest `Toranja-…-AppleSilicon.zip` from [Releases](https://github.com/EdilsonBorba/toranja/releases/latest).
2. Unzip it and drag **Toranja** into **Applications**.
3. **The first time**, right-click the app → **Open** → **Open**.
   Toranja is not signed with a paid Apple developer account, so macOS asks for this once. If you see
   *"is damaged"* or there is no Open button, run in Terminal:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Toranja.app
   ```
4. 🍊 shows up in the menu bar. Done.

**Requirements:** macOS 14 (Sonoma) or later, Apple silicon Mac (M1 or newer).
Nothing else to install: ffmpeg and a trimmed Java runtime ship inside the app.
Only OpenDocument presentations (`.odp`) need [LibreOffice](https://www.libreoffice.org).

**Verify the download (optional):** every release includes a `SHA256SUMS.txt`.
```sh
shasum -a 256 Toranja-*-AppleSilicon.zip
```

## Settings

🍊 menu → **Settings…** (⌘,)

- **General:** glass or solid look, language (Portuguese/English), launch at login, sounds, which keys open each wheel, Float behavior, terminal app.
- **Formats:** quality and metadata (EXIF, GPS) per output format.
- **Compatibility:** image, video and audio compression strength, maximum size and target size.
- **Output:** save next to the original or to a fixed folder; reveal in Finder when done.

## Privacy

Toranja never connects to the internet, collects no data and needs no special permissions. It notices
a drag by reading the system drag pasteboard and the modifier keys. It does not monitor your keyboard.

## Build from source

Requirements: macOS 14+, Xcode Command Line Tools (`xcode-select --install`), a JDK 11+
(e.g. `brew install --cask temurin`), Node.js and `brew install pkgconf cmake`.

```sh
git clone https://github.com/EdilsonBorba/toranja.git && cd toranja
./build.sh           # builds build/Toranja.app
./build.sh install   # installs into /Applications and opens it
./build.sh dist      # writes the download zip, SHA-256 and ffmpeg sources to dist/
```

On the first run, `build.sh`:

- downloads the Java libraries from Maven Central;
- bundles the JavaScript with esbuild;
- builds ffmpeg from the official sources (`scripts/build-ffmpeg.sh`, about 10 minutes);
- creates the trimmed Java runtime (`scripts/make-java-runtime.sh`).

| Folder | Contents |
|---|---|
| `Sources/Toranja` | The Swift app (AppKit + SwiftUI): drag detection, wheels, tools, settings |
| `office/java` | PowerPoint / legacy Excel / PDF converter using Apache POI and PDFBox |
| `office/js` | Word and Pages/Numbers/Keynote via docx-preview and cupertino-files in a hidden WebKit view |
| `scripts` | ffmpeg, Java runtime, licenses, icon |
| `Resources` | Info.plist, icon and sounds (synthesized for this project) |

```sh
.build/release/Toranja --cli convert pdf file.docx    # test converters from the terminal
.build/release/Toranja --cli wheel tools wheel.png video.mov
```

## License

Toranja's code: [MIT](LICENSE). The downloadable app bundles open-source components under their own
licenses, including FFmpeg (GPL v3), whose source code is attached to every release. See
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
