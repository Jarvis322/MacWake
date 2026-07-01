import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Backs the Dynamic Island's optional "Shelf" — a last-copied-text peek and a small
/// file drop tray, in the spirit of NotchNook/Boring Notch's shelf. Off by default:
/// polling the clipboard is a privacy-sensitive thing to do passively, so it only runs
/// once the user opts in from Settings.
@MainActor
final class ClipboardWatcher: ObservableObject {
    static let shared = ClipboardWatcher()

    @Published private(set) var lastCopiedText: String?
    @Published private(set) var shelvedFiles: [URL] = []
    @Published var justRecopied = false

    private let maxShelvedFiles = 6
    private let maxPreviewLength = 160
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var isWatching = false

    private init() {}

    func setEnabled(_ enabled: Bool) {
        guard enabled != isWatching else { return }
        isWatching = enabled
        if enabled {
            // Seed the baseline so enabling the feature doesn't immediately surface
            // whatever was already on the clipboard before the user opted in.
            lastChangeCount = NSPasteboard.general.changeCount
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
        } else {
            timer?.invalidate()
            timer = nil
            lastCopiedText = nil
        }
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lastCopiedText = text.count > maxPreviewLength ? String(text.prefix(maxPreviewLength)) + "…" : text
    }

    func recopyLastText() {
        guard let text = lastCopiedText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        lastChangeCount = NSPasteboard.general.changeCount   // don't re-surface our own copy as "new"
        justRecopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.justRecopied = false }
    }

    func addFile(_ url: URL) {
        guard !shelvedFiles.contains(url) else { return }
        shelvedFiles.insert(url, at: 0)
        if shelvedFiles.count > maxShelvedFiles {
            shelvedFiles.removeLast(shelvedFiles.count - maxShelvedFiles)
        }
    }

    func removeFile(_ url: URL) {
        shelvedFiles.removeAll { $0 == url }
    }
}

struct NotchShelfView: View {
    @ObservedObject private var clipboard = ClipboardWatcher.shared
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SHELF")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white.opacity(0.4))

            if let text = clipboard.lastCopiedText {
                Button(action: { clipboard.recopyLastText() }) {
                    HStack(spacing: 6) {
                        Image(systemName: clipboard.justRecopied ? "checkmark" : "doc.on.clipboard")
                            .font(.system(size: 10))
                            .foregroundColor(clipboard.justRecopied ? .green : .white.opacity(0.6))
                        Text(text)
                            .font(.system(size: 10))
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .foregroundColor(.white.opacity(0.85))
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            fileDropZone
        }
        .frame(width: 168)
    }

    private var fileDropZone: some View {
        Group {
            if clipboard.shelvedFiles.isEmpty {
                VStack {
                    Image(systemName: "tray")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.25))
                    Text(String(localized: "Drop files here"))
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.3))
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                VStack(spacing: 5) {
                    ForEach(clipboard.shelvedFiles, id: \.self) { url in
                        HStack(spacing: 6) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable().frame(width: 14, height: 14)
                            Text(url.lastPathComponent)
                                .font(.system(size: 9))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundColor(.white.opacity(0.8))
                            Spacer(minLength: 0)
                            Button(action: { clipboard.removeFile(url) }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.white.opacity(0.35))
                            }
                            .buttonStyle(.plain)
                        }
                        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                    }
                }
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(isDropTargeted ? 0.5 : 0.15), style: StrokeStyle(lineWidth: 1, dash: [4]))
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in ClipboardWatcher.shared.addFile(url) }
                }
            }
            return true
        }
    }
}
