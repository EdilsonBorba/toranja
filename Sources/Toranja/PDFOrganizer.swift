import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class OrganizerModel: ObservableObject {
    struct Page: Identifiable, Equatable {
        let id = UUID()
        let index: Int
        var rotation: Int
        let thumbnail: NSImage

        static func == (a: Page, b: Page) -> Bool { a.id == b.id && a.rotation == b.rotation }
    }

    let url: URL
    let doc: PDFDocument
    @Published var pages: [Page]
    @Published var selection: Set<UUID> = []
    var dragging: Page?

    init(url: URL) throws {
        self.url = url
        let doc = try Documents.open(url)
        self.doc = doc
        pages = (0..<doc.pageCount).compactMap { i in
            guard let page = doc.page(at: i) else { return nil }
            return Page(index: i, rotation: 0, thumbnail: page.thumbnail(of: NSSize(width: 260, height: 260), for: .cropBox))
        }
    }

    var hasChanges: Bool {
        pages.map(\.index) != Array(0..<doc.pageCount) || pages.contains { $0.rotation != 0 }
    }

    func select(_ page: Page, adding: Bool) {
        if adding {
            if selection.contains(page.id) { selection.remove(page.id) } else { selection.insert(page.id) }
        } else {
            selection = [page.id]
        }
    }

    func rotateSelected() {
        for i in pages.indices where selection.contains(pages[i].id) {
            pages[i].rotation = (pages[i].rotation + 90) % 360
        }
    }

    func deleteSelected() {
        let remaining = pages.filter { !selection.contains($0.id) }
        guard !remaining.isEmpty else { return }
        withAnimation { pages = remaining }
        selection = []
    }

    func save() throws -> URL {
        let result = PDFDocument()
        for page in pages {
            guard let copy = doc.page(at: page.index)?.copy() as? PDFPage else { continue }
            copy.rotation = (copy.rotation + page.rotation) % 360
            result.insert(copy, at: result.pageCount)
        }
        let out = Output.url(for: url, ext: "pdf", suffix: L("organizado", "organized"))
        guard result.write(to: out) else { throw ToolError.failed(L("Falha ao gravar o PDF.", "Failed to save the PDF.")) }
        return out
    }
}

@MainActor
private struct ReorderDrop: DropDelegate {
    let target: OrganizerModel.Page
    let model: OrganizerModel

    func dropEntered(info: DropInfo) {
        guard let dragged = model.dragging, dragged.id != target.id,
              let from = model.pages.firstIndex(where: { $0.id == dragged.id }),
              let to = model.pages.firstIndex(where: { $0.id == target.id }) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            model.pages.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        model.dragging = nil
        return true
    }
}

struct OrganizerView: View {
    @ObservedObject var model: OrganizerModel
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(L("\(model.pages.count) páginas", "\(model.pages.count) pages")).foregroundStyle(.secondary)
                Button { model.rotateSelected() } label: { Label(L("Girar", "Rotate"), systemImage: "rotate.right") }
                    .disabled(model.selection.isEmpty)
                    .keyboardShortcut("r", modifiers: .command)
                Button { model.deleteSelected() } label: { Label(L("Excluir", "Delete"), systemImage: "trash") }
                    .disabled(model.selection.isEmpty || model.selection.count == model.pages.count)
                Spacer()
                Text(L("Arraste para reordenar · ⌘-clique seleciona várias", "Drag to reorder · ⌘-click selects several"))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L("Cancelar", "Cancel"), action: onCancel).keyboardShortcut(.cancelAction)
                Button(L("Salvar PDF organizado", "Save Organized PDF"), action: onSave)
                    .buttonStyle(.borderedProminent)
                    .tint(Color(nsColor: Theme.accent))
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.hasChanges)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 18)], spacing: 18) {
                    ForEach(Array(model.pages.enumerated()), id: \.element.id) { number, page in
                        cell(page, number: number + 1)
                            .onTapGesture { model.select(page, adding: NSEvent.modifierFlags.contains(.command)) }
                            .onDrag {
                                model.dragging = page
                                return NSItemProvider(object: page.id.uuidString as NSString)
                            }
                            .onDrop(of: [.text], delegate: ReorderDrop(target: page, model: model))
                    }
                }
                .padding(20)
            }
            .onDeleteCommand { model.deleteSelected() }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func cell(_ page: OrganizerModel.Page, number: Int) -> some View {
        let selected = model.selection.contains(page.id)
        return VStack(spacing: 6) {
            Image(nsImage: page.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .rotationEffect(.degrees(Double(page.rotation)))
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: page.rotation)
                .frame(width: 130, height: 150)
                .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
            Text("\(number)").font(.caption.weight(.semibold)).foregroundStyle(selected ? .primary : .secondary)
        }
        .padding(8)
        .background(selected ? Color(nsColor: Theme.accent).opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color(nsColor: Theme.accent) : .clear, lineWidth: 2))
        .contentShape(Rectangle())
    }
}

@MainActor
enum PDFOrganizer {
    static func open(_ url: URL) {
        let model: OrganizerModel
        do { model = try OrganizerModel(url: url) } catch {
            Dialog.alert(L("Não foi possível abrir", "Couldn't open"), error.localizedDescription)
            return
        }
        let window = EditorWindows.make(title: L("Organizar", "Organize") + " — " + url.lastPathComponent,
                                        contentAspect: CGSize(width: 900, height: 620), extraHeight: 52)
        window.contentView = NSHostingView(rootView: OrganizerView(model: model, onSave: { [weak window] in
            do {
                let out = try model.save()
                window?.close()
                HUD.shared.finished(JobResult(outputs: [out]))
            } catch {
                Dialog.alert(L("Não foi possível salvar", "Couldn't save"), error.localizedDescription)
            }
        }, onCancel: { [weak window] in window?.close() }))
        EditorWindows.present(window)
    }
}
