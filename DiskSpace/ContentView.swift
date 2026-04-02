import AppKit
import SwiftUI

@MainActor
final class ScanViewModel: ObservableObject {
    @Published var rootNode: FolderNode?
    @Published var rootURL: URL?
    @Published var isScanning = false
    @Published var statusText = "Choose a folder to analyze."
    @Published var itemsScanned: Int64 = 0
    @Published var lastError: String?

    private var scanTask: Task<Void, Never>?

    /// Holds a weak ref so the scan progress closure stays `@Sendable` without capturing `self`.
    private final class ProgressBridge: @unchecked Sendable {
        weak var viewModel: ScanViewModel?
        func push(path: String, count: Int64) {
            DispatchQueue.main.async { [weak viewModel] in
                viewModel?.statusText = "Scanning… \(path)"
                viewModel?.itemsScanned = count
            }
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        panel.title = "Select folder to analyze"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        rootURL = url
        lastError = nil
        startScan(url: url)
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        if isScanning {
            isScanning = false
            statusText = "Stopped."
        }
    }

    func revealInFinder() {
        guard let url = rootURL else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    private func startScan(url: URL) {
        stopScan()
        rootNode = nil
        itemsScanned = 0
        isScanning = true
        statusText = "Scanning…"

        // Security-scoped access is tied to the calling thread; run the whole scan on one
        // detached task so `stat` / directory enumeration stay under the same scope and
        // macOS does not re-prompt for the same tree on every thread hop.
        let progressBridge = ProgressBridge()
        progressBridge.viewModel = self

        scanTask = Task.detached(priority: .userInitiated) { [url, progressBridge] in
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let tree = try FolderScanner.scan(root: url) { path, count in
                    progressBridge.push(path: path, count: count)
                }
                await MainActor.run {
                    guard let vm = progressBridge.viewModel else { return }
                    vm.rootNode = tree
                    vm.lastError = nil
                    vm.statusText = "Done."
                    vm.isScanning = false
                }
            } catch is CancellationError {
                await MainActor.run {
                    progressBridge.viewModel?.isScanning = false
                }
            } catch {
                await MainActor.run {
                    guard let vm = progressBridge.viewModel else { return }
                    vm.lastError = error.localizedDescription
                    vm.statusText = "Failed."
                    vm.isScanning = false
                }
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var model = ScanViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button("Choose folder…") {
                    model.chooseFolder()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Stop") {
                    model.stopScan()
                }
                .disabled(!model.isScanning)

                Button("Show in Finder") {
                    model.revealInFinder()
                }
                .disabled(model.rootURL == nil)

                Spacer()

                if model.isScanning {
                    ProgressView()
                        .scaleEffect(0.75)
                }

                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding([.horizontal, .top])

            if let err = model.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Divider()

            List {
                if let root = model.rootNode {
                    OutlineGroup([root], children: \.children) { node in
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: node.children == nil ? "doc" : "folder")
                                .foregroundStyle(.secondary)
                                .frame(width: 16, alignment: .center)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(node.name)
                                if let msg = node.errorMessage {
                                    Text(msg)
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            Spacer(minLength: 8)
                            Text(ByteCountFormatter.string(fromByteCount: node.totalBytes, countStyle: .file))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minWidth: 480, minHeight: 360)
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 640, height: 480)
}
