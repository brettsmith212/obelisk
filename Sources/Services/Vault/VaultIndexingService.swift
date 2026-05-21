import Foundation
import Observation

/// Glue layer between `VaultAccessService` (which vault?), `VaultScanner`
/// (do the work), and the UI (status + "Re-index now").
///
/// Reasons it exists separately:
/// - `VaultAccessService` is the I/O mediator and shouldn't know what
///   the scanner is doing.
/// - The scanner is a stateless actor — it has no concept of a
///   "current" status that views can observe.
/// - Both the empty state and the (future) Settings sheet need the
///   same status, so it lives at app scope.
@MainActor
@Observable
final class VaultIndexingService {
    enum Status: Equatable, Sendable {
        case idle
        case scanning(processed: Int, total: Int, mode: VaultScanner.Mode)
        case ready(noteCount: Int, lastScan: Date, lastSummary: VaultScanner.Summary)
        case failed(message: String)
    }

    private(set) var status: Status = .idle

    private let index: VaultIndex
    private let scanner: VaultScanner
    private var currentScanTask: Task<Void, Never>?

    init(index: VaultIndex, scanner: VaultScanner) {
        self.index = index
        self.scanner = scanner
    }

    /// Run a scan if none is in flight. Called by `RootView.task` once a
    /// vault has been bound. Safe to invoke repeatedly — back-to-back
    /// calls are coalesced.
    func ensureIndexed(handle: VaultHandle, mode: VaultScanner.Mode = .incremental) {
        guard currentScanTask == nil else { return }
        currentScanTask = Task { [weak self] in
            await self?.runScan(handle: handle, mode: mode)
        }
    }

    /// Force a re-index. Used by the (future) "Re-index now" button.
    func reindex(handle: VaultHandle) {
        currentScanTask?.cancel()
        currentScanTask = Task { [weak self] in
            await self?.runScan(handle: handle, mode: .full)
        }
    }

    /// Drop status back to idle when the user disconnects a vault.
    func reset() {
        currentScanTask?.cancel()
        currentScanTask = nil
        status = .idle
    }

    // MARK: - Private

    private func runScan(handle: VaultHandle, mode: VaultScanner.Mode) async {
        defer { currentScanTask = nil }

        status = .scanning(processed: 0, total: 0, mode: mode)
        let stream = scanner.scan(handle: handle, mode: mode)
        var lastSummary: VaultScanner.Summary?

        for await event in stream {
            switch event {
            case .started(let total, _):
                #if DEBUG
                VaultIndexingService.debugAppend("[VaultIndexing] started total=\(total) mode=\(mode)")
                #endif
                status = .scanning(processed: 0, total: total, mode: mode)
            case .parsing(let processed, let total):
                status = .scanning(processed: processed, total: total, mode: mode)
            case .resolvingLinks:
                #if DEBUG
                VaultIndexingService.debugAppend("[VaultIndexing] resolving links")
                #endif
                break
            case .finished(let summary):
                lastSummary = summary
            case .failed(let message):
                #if DEBUG
                VaultIndexingService.debugAppend("[VaultIndexing] FAILED: \(message)")
                #endif
                status = .failed(message: message)
                return
            }
        }

        guard let summary = lastSummary else {
            status = .failed(message: "Scan finished without a summary.")
            return
        }

        let count = (try? index.noteCount()) ?? 0
        status = .ready(noteCount: count, lastScan: Date(), lastSummary: summary)

        #if DEBUG
        let msg = "[VaultIndexing] \(summary.mode) scan finished — " +
            "files=\(summary.totalFiles), parsed=\(summary.parsed), " +
            "skipped=\(summary.skipped), deleted=\(summary.deleted), " +
            "icloud=\(summary.iCloudPlaceholders), " +
            "indexed_total=\(count), duration=\(String(format: "%.2f", summary.durationSeconds))s"
        print(msg)
        VaultIndexingService.debugAppend(msg)
        #endif
    }

    #if DEBUG
    /// Tail-able log file: `Documents/scan.log`. Beats hunting through
    /// `xcrun simctl log` for a single line.
    ///
    /// `nonisolated` so the scanner actor / detached tasks can call it
    /// without hopping to the main actor for every line.
    nonisolated static func debugAppend(_ line: String) {
        let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first!
            .appending(path: "scan.log", directoryHint: .notDirectory)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(stamp) \(line)\n"
        if let data = entry.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
    #endif
}
