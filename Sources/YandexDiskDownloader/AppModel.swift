import SwiftUI
import AppKit
import UserNotifications
import YandexDiskCore

struct Preferences: Codable {
    var concurrent = 3
    var retries = 3
    var skipExisting = true
    var verifySize = true
    var verifyChecksum = true
    var openAfter = false
    var notifications = false
    var appearance = "system"
    var language = "en"
    var destinationPath = ""
    var bookmark: Data?
}
struct HistoryItem: Codable, Identifiable {
    var id = UUID()
    var name: String
    var date = Date()
    var files: Int
    var bytes: Int64
    var status: String
    var destination: String
    var publicLink: String
    var bookmark: Data?
}
struct FailureItem: Identifiable { var id: String { file.id }; let file: RemoteFile; let message: String }
enum Phase { case idle, scanning, ready, downloading, paused, cancelling, completed, cancelled }

@MainActor final class AppModel: ObservableObject {
    @Published var preferences: Preferences { didSet { persist(preferences, key: "preferences") } }
    @Published var history: [HistoryItem] { didSet { persist(history, key: "history") } }
    @Published var link = ""
    @Published var manifest: Manifest?
    @Published var phase: Phase = .idle
    @Published var error: String?
    @Published var scanned = 0
    @Published var completed = 0
    @Published var skipped = 0
    @Published var downloadedBytes: Int64 = 0
    @Published var speed: Double = 0
    @Published var elapsed: TimeInterval = 0
    @Published var currentFiles: [String: String] = [:]
    @Published var activeBytes: [String: Int64] = [:]
    @Published var failures: [FailureItem] = []
    @Published var notice = ""
    private var work: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var transfers: [String: FileTransfer] = [:]
    private var startDate: Date?
    private var pausedAt: Date?
    private var pausedTime: TimeInterval = 0
    private var networkBytes: Int64 = 0
    private var lastTransferBytes: [String: Int64] = [:]
    private var inspectedKey = ""
    private var savedDestination: URL?
    private var runPreferences = Preferences()
    private var runBookmark: Data?
    private var preferStreaming = false
    private var isSandboxed: Bool { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil }
    var busy: Bool { [.scanning, .downloading, .paused, .cancelling].contains(phase) }
    var totalBytes: Int64 { manifest?.totalSize ?? 0 }
    var progressBytes: Int64 { downloadedBytes + activeBytes.values.reduce(0, +) }
    var fraction: Double {
        if totalBytes > 0 { return min(1, Double(progressBytes) / Double(totalBytes)) }
        return Double(completed) / Double(max(1, manifest?.files.count ?? 0))
    }
    var outputURL: URL? {
        guard let savedDestination else { return nil }
        return manifest?.isDirectory == true ? savedDestination.appendingPathComponent(manifest!.localName) : savedDestination
    }
    var colorScheme: ColorScheme? { preferences.appearance == "dark" ? .dark : preferences.appearance == "light" ? .light : nil }
    init() {
        preferences = Self.restore(Preferences.self, key: "preferences") ?? Preferences()
        history = Self.restore([HistoryItem].self, key: "history") ?? []
    }
    func t(_ en: String, _ ru: String) -> String { preferences.language == "ru" ? ru : en }
    private func persist<T: Encodable>(_ value: T, key: String) { if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: "ydd.\(key)") } }
    private static func restore<T: Decodable>(_ type: T.Type, key: String) -> T? { UserDefaults.standard.data(forKey: "ydd.\(key)").flatMap { try? JSONDecoder().decode(type, from: $0) } }

    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = t("Choose Folder", "Выбрать папку")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.destinationPath = url.path
        preferences.bookmark = isSandboxed ? try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) : nil
    }
    private func resolveDestination() throws -> URL {
        if isSandboxed, let bookmark = preferences.bookmark {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
            if stale { preferences.bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) }
            return url
        }
        guard !preferences.destinationPath.isEmpty else { throw DiskError.fileSystem(t("Choose a destination folder first.", "Сначала выберите папку назначения.")) }
        return URL(fileURLWithPath: preferences.destinationPath, isDirectory: true)
    }
    func inspect() {
        guard !busy else { return }
        error = nil; manifest = nil; scanned = 0; failures = []; completed = 0; skipped = 0; downloadedBytes = 0; activeBytes = [:]; notice = ""
        do { inspectedKey = try PublicLink.validate(link) } catch { self.error = ErrorMessage.safe(error); return }
        phase = .scanning
        let api = DiskAPI(retries: preferences.retries); let key = inspectedKey
        work = Task {
            do {
                let result = try await FolderScanner(api: api).scan(key: key) { count in Task { @MainActor in self.scanned = count } }
                try Task.checkCancellation(); self.manifest = result; self.phase = .ready
            } catch { if Task.isCancelled { self.phase = .cancelled } else { self.error = ErrorMessage.safe(error); self.phase = .idle } }
        }
    }
    func download(retryFailed: Bool = false) {
        guard !busy, let manifest else { return }
        guard (try? PublicLink.validate(link)) == inspectedKey else { self.error = t("The link changed. Inspect it again.", "Ссылка изменилась. Проверьте её снова."); return }
        let files = retryFailed ? failures.map(\.file) : manifest.files
        do {
            let destination = try resolveDestination(); savedDestination = destination
            let scoped = destination.startAccessingSecurityScopedResource()
            let target: SafeDestination
            do { target = try SafeDestination(url: destination) } catch { if scoped { destination.stopAccessingSecurityScopedResource() }; throw error }
            runPreferences = preferences; runBookmark = preferences.bookmark
            if !retryFailed { completed = 0; skipped = 0; downloadedBytes = 0 }
            failures = []; error = nil; activeBytes = [:]; currentFiles = [:]; notice = ""
            phase = .downloading; startDate = Date(); pausedAt = nil; pausedTime = 0; elapsed = 0; networkBytes = 0; lastTransferBytes = [:]; startTicker()
            let options = runPreferences
            let api = DiskAPI(retries: 0) { message in Task { @MainActor in self.notice = message } }
            work = Task {
                let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Downloading user-selected files")
                defer { ProcessInfo.processInfo.endActivity(activity); if scoped { destination.stopAccessingSecurityScopedResource() }; self.ticker?.cancel(); self.speed = 0 }
                do {
                    try await Task.detached { for directory in manifest.directories { try Task.checkCancellation(); try target.makeDirectory(directory) } }.value
                    try Task.checkCancellation()
                    await withTaskGroup(of: Void.self) { group in
                        var next = 0
                        for _ in 0..<min(options.concurrent, files.count) {
                            let file = files[next]; next += 1
                            group.addTask { await self.downloadOne(file, target: target, api: api, options: options) }
                        }
                        while await group.next() != nil {
                            if Task.isCancelled { group.cancelAll(); continue }
                            if next < files.count { let file = files[next]; next += 1; group.addTask { await self.downloadOne(file, target: target, api: api, options: options) } }
                        }
                    }
                    self.phase = Task.isCancelled ? .cancelled : .completed
                } catch { self.error = ErrorMessage.safe(error); self.phase = Task.isCancelled ? .cancelled : .completed }
                self.activeBytes = [:]; self.currentFiles = [:]; self.recordHistory()
                if self.phase == .completed, self.failures.isEmpty, self.error == nil {
                    if options.openAfter { self.openOutput() }
                    if options.notifications { self.notifyCompletion() }
                }
            }
        } catch { self.error = ErrorMessage.safe(error) }
    }
    private func gate() async throws {
        while phase == .paused { try await Task.sleep(nanoseconds: 150_000_000) }
        try Task.checkCancellation()
    }
    private func downloadOne(_ file: RemoteFile, target: SafeDestination, api: DiskAPI, options: Preferences) async {
        var resumeData: Data?
        let useStreaming = preferStreaming
        defer { transfers[file.id] = nil; activeBytes[file.id] = nil; currentFiles[file.id] = nil; lastTransferBytes[file.id] = nil }
        do {
            try await gate()
            if options.skipExisting {
                let matched = try await Task.detached { try target.existingMatches(file, verifySize: options.verifySize, verifyChecksum: options.verifyChecksum) }.value
                try await gate()
                if matched { completed += 1; skipped += 1; downloadedBytes += file.size ?? 0; return }
            }
            while true {
                try await gate()
                currentFiles[file.id] = t("Getting link: ", "Получение ссылки: ") + (file.components.last ?? file.id)
                do {
                    let url = try await api.downloadURL(key: inspectedKey, path: file.apiPath)
                    try await gate()
                    currentFiles[file.id] = t("Downloading: ", "Скачивание: ") + (file.components.last ?? file.id)
                    let transfer = FileTransfer(streaming: useStreaming) { bytes in Task { @MainActor in
                        guard self.transfers[file.id] != nil else { return }
                        let previous = self.lastTransferBytes[file.id] ?? 0
                        self.networkBytes += max(0, bytes - previous); self.lastTransferBytes[file.id] = bytes
                        self.activeBytes[file.id] = min(bytes, file.size ?? bytes)
                    } }
                    transfers[file.id] = transfer; lastTransferBytes[file.id] = 0
                    let temp = try await transfer.download(url: url, resumeData: resumeData)
                    defer { try? FileManager.default.removeItem(at: temp) }
                    transfers[file.id] = nil
                    try await gate()
                    currentFiles[file.id] = t("Verifying: ", "Проверка: ") + (file.components.last ?? file.id)
                    let savedName = try await Task.detached {
                        try FileVerifier.verify(url: temp, file: file, size: options.verifySize, checksum: options.verifyChecksum)
                        return try target.commit(temp: temp, components: file.components)
                    }.value
                    if savedName != file.components.last { notice = t("Existing files were preserved; new copies received numbered names.", "Существующие файлы сохранены, новым копиям добавлены номера.") }
                    let size = (try? temp.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? file.size ?? 0
                    downloadedBytes += size; completed += 1; activeBytes[file.id] = nil
                    return
                } catch {
                    transfers[file.id] = nil
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    if let paused = error as? TransferPaused {
                        resumeData = paused.resumeData
                        try await gate()
                        continue
                    }
                    let underlying = (error as? TransferFailure)?.underlying ?? error
                    if (underlying as? URLError)?.code == .timedOut { preferStreaming = true }
                    if case DiskError.http(429, let delay) = underlying { await api.cooldown(delay ?? 2) }
                    // File errors never occupy the queue with automatic retries.
                    // The user can retry only failed files once this pass finishes.
                    throw underlying
                }
            }
        } catch { if !Task.isCancelled, !(error is CancellationError) { failures.append(FailureItem(file: file, message: ErrorMessage.safe(error))) } }
    }
    func pause() { guard phase == .downloading else { return }; phase = .paused; pausedAt = Date(); speed = 0; transfers.values.forEach { $0.pause() } }
    func resume() { guard phase == .paused else { return }; if let pausedAt { pausedTime += Date().timeIntervalSince(pausedAt) }; pausedAt = nil; phase = .downloading }
    func cancel() { guard busy else { return }; phase = .cancelling; work?.cancel(); transfers.values.forEach { $0.cancel() } }
    func reset() { guard !busy else { return }; manifest = nil; phase = .idle; error = nil; failures = []; link = ""; notice = "" }
    func openOutput() { if let outputURL { NSWorkspace.shared.open(outputURL) } }
    func repeatHistory(_ item: HistoryItem) { guard !busy else { return }; link = item.publicLink; preferences.destinationPath = item.destination; preferences.bookmark = item.bookmark; inspect() }
    func openHistory(_ item: HistoryItem) {
        var stale = false
        let resolved = isSandboxed ? item.bookmark.flatMap { try? URL(resolvingBookmarkData: $0, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) } : nil
        let url = resolved ?? URL(fileURLWithPath: item.destination)
        let scoped = url.startAccessingSecurityScopedResource(); NSWorkspace.shared.open(url); if scoped { url.stopAccessingSecurityScopedResource() }
    }
    private func recordHistory() {
        guard let manifest, let savedDestination else { return }
        let status = phase == .cancelled ? "cancelled" : (failures.isEmpty && error == nil && manifest.skippedItems == 0 ? "completed" : "errors")
        history.insert(HistoryItem(name: manifest.name, files: completed, bytes: downloadedBytes, status: status, destination: savedDestination.path, publicLink: inspectedKey, bookmark: runBookmark), at: 0)
        history = Array(history.prefix(200))
    }
    private func startTicker() {
        ticker?.cancel()
        ticker = Task {
            var previous: Int64 = 0
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
                let delta = Double(max(0, networkBytes - previous)); previous = networkBytes
                speed = phase == .downloading ? delta : 0
                if let startDate { elapsed = (pausedAt ?? Date()).timeIntervalSince(startDate) - pausedTime }
            }
        }
    }
    private func notifyCompletion() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent(); content.title = "Yandex Disk Downloader"; content.body = "Download completed"; content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
