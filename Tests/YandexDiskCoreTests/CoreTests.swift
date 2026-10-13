import Foundation
@testable import YandexDiskCore
#if canImport(XCTest)
import XCTest
#else
import Testing
#endif

private struct CheckFailure: Error { let message: String }
private func check(_ condition: Bool, _ message: String = "Assertion failed") throws { if !condition { throw CheckFailure(message: message) } }
private func mustThrow(_ action: () throws -> Void) throws { do { try action() } catch { return }; throw CheckFailure(message: "Expected error") }

final class MockProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
            let (status, headers, data) = try handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func configure(_ handler: @escaping (URLRequest) throws -> (Int, [String: String], Data)) -> URLSessionConfiguration {
        lock.lock(); self.handler = handler; lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [MockProtocol.self]; return configuration
    }
}

final class HangingProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

enum Scenarios {
    static let root = #"{"name":"Music","type":"dir","_embedded":{"offset":0,"total":3,"items":[{"name":"nested","type":"dir","path":"/nested"},{"name":"one.mp3","type":"file","path":"/one.mp3","size":3}]}}"#
    static let second = #"{"name":"Music","type":"dir","_embedded":{"offset":2,"total":3,"items":[{"name":"two.mp3","type":"file","path":"/two.mp3","size":4}]}}"#
    static let nested = #"{"name":"nested","type":"dir","_embedded":{"offset":0,"total":1,"items":[{"name":"three.mp3","type":"file","path":"/nested/three.mp3","size":5}]}}"#
    static func links() throws {
        for host in ["disk.yandex.ru", "disk.yandex.com", "yadi.sk"] { for kind in ["d", "i"] { _ = try PublicLink.validate(" https://\(host)/\(kind)/abc \n") } }
        for bad in ["file:///tmp/x", "http://disk.yandex.ru/d/x", "https://disk.yandex.ru.evil.com/d/x", "https://evil.com/d/x", "https://user@disk.yandex.ru/d/x", "https://disk.yandex.ru/d/", "https://disk.yandex.ru:80/d/x"] { try mustThrow { _ = try PublicLink.validate(bad) } }
    }
    static func parsing() throws {
        let r = try JSONDecoder().decode(Resource.self, from: Data(root.utf8))
        try check(r.embedded?.total == 3); try check(r.embedded?.items[1].size == 3)
        let link = try JSONDecoder().decode(DownloadLink.self, from: Data(#"{"href":"https://downloader.disk.yandex.ru/a","method":"GET","templated":false}"#.utf8))
        try check(link.href.scheme == "https")
    }
    static func recursion() async throws {
        let config = MockProtocol.configure { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let path = query.first { $0.name == "path" }?.value
            let offset = query.first { $0.name == "offset" }?.value
            let body = path == "/nested" ? nested : offset == "2" ? second : root
            return (200, [:], Data(body.utf8))
        }
        let manifest = try await FolderScanner(api: DiskAPI(session: URLSession(configuration: config)), pageSize: 2).scan(key: "https://yadi.sk/d/test")
        try check(manifest.files.count == 3); try check(manifest.directories.count == 2); try check(manifest.totalSize == 12)
        try check(manifest.files.last?.components == ["Music", "nested", "three.mp3"])
    }
    static func singleFile() async throws {
        let config = MockProtocol.configure { _ in (200, [:], Data(#"{"name":"track.mp3","type":"file","size":3}"#.utf8)) }
        let manifest = try await FolderScanner(api: DiskAPI(session: URLSession(configuration: config))).scan(key: "x")
        try check(manifest.files.count == 1); try check(!manifest.isDirectory); try check(manifest.files[0].apiPath == nil)
    }
    static func httpAndRetry() async throws {
        var attempts = 0
        let config = MockProtocol.configure { _ in
            attempts += 1
            if attempts == 1 { return (429, ["Retry-After": "0"], Data()) }
            if attempts == 2 { return (503, ["Retry-After": "0"], Data()) }
            return (200, [:], Data(#"{"name":"ok","type":"file"}"#.utf8))
        }
        let r = try await DiskAPI(session: URLSession(configuration: config), retries: 2).resource(key: "x")
        try check(r.name == "ok"); try check(attempts == 3)
        let denied = MockProtocol.configure { _ in (403, [:], Data()) }
        do { _ = try await DiskAPI(session: URLSession(configuration: denied)).resource(key: "x"); throw CheckFailure(message: "403 accepted") }
        catch DiskError.http(let status, _) { try check(status == 403) }
        try check(RetryPolicy.retryAfter("120") == 120)
        let date = Date(timeIntervalSince1970: 0)
        try check(RetryPolicy.retryAfter("Thu, 01 Jan 1970 00:01:00 GMT", now: date) == 60)
        try check(!RetryPolicy.isTransient(DiskError.http(404, nil)))
        try check(RetryPolicy.isTransient(URLError(.networkConnectionLost)))
    }
    static func incompletePage() async throws {
        let config = MockProtocol.configure { _ in (200, [:], Data(#"{"name":"x","type":"dir","_embedded":{"total":2,"items":[]}}"#.utf8)) }
        do { _ = try await FolderScanner(api: DiskAPI(session: URLSession(configuration: config))).scan(key: "x"); throw CheckFailure(message: "Incomplete listing accepted") }
        catch DiskError.incompleteListing {}
    }
    static func unsafeNames() throws {
        for name in ["..", ".", "", "a/b", "a\\b", "a:b", "x\0", "x\n"] { try mustThrow { try SafePath.validate(name) } }
        try SafePath.validate("Музыка 🎵 & more.mp3")
        try mustThrow { try SafePath.validateAPI("/a/../outside") }
    }
    static func fileSystem() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: base, withIntermediateDirectories: true); defer { try? fm.removeItem(at: base) }
        let source = base.appendingPathComponent("source"); try Data("abc".utf8).write(to: source)
        let file = RemoteFile(apiPath: "/nested/a.mp3", components: ["nested", "a.mp3"], size: 3, md5: "900150983cd24fb0d6963f7d28e17f72")
        try FileVerifier.verify(url: source, file: file, size: true, checksum: true)
        try mustThrow { try FileVerifier.verify(url: source, file: RemoteFile(apiPath: nil, components: ["x"], size: 4), size: true, checksum: false) }
        try mustThrow { try FileVerifier.verify(url: source, file: RemoteFile(apiPath: nil, components: ["x"], size: 3, md5: "bad"), size: true, checksum: true) }
        let destination = try SafeDestination(url: base)
        let first = try destination.commit(temp: source, components: file.components)
        let second = try destination.commit(temp: source, components: file.components)
        try check(first == "a.mp3"); try check(second == "a (1).mp3")
        let matches = try destination.existingMatches(file, verifySize: true, verifyChecksum: true); try check(matches)
        try fm.createSymbolicLink(atPath: base.appendingPathComponent("escape").path, withDestinationPath: "/tmp")
        try mustThrow { try destination.makeDirectory(["escape", "outside"]) }
        try mustThrow { _ = try destination.commit(temp: source, components: ["..", "outside"]) }
        try fm.createSymbolicLink(atPath: base.appendingPathComponent("link.mp3").path, withDestinationPath: source.path)
        try mustThrow { _ = try destination.existingMatches(RemoteFile(apiPath: nil, components: ["link.mp3"], size: 3), verifySize: true, verifyChecksum: false) }
    }
    static func download() async throws {
        let config = MockProtocol.configure { _ in (200, ["Content-Length": "3"], Data("abc".utf8)) }
        let transfer = FileTransfer(configuration: config, progress: { _ in })
        let url = try await transfer.download(url: URL(string: "https://example.test/test")!)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url); try check(data == Data("abc".utf8))
    }
    static func concurrentAPI() async throws {
        let config = MockProtocol.configure { _ in (200, [:], Data(#"{"href":"https://downloader.disk.yandex.ru/file","method":"GET"}"#.utf8)) }
        let api = DiskAPI(session: URLSession(configuration: config), retries: 0)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<25 { group.addTask { _ = try await api.downloadURL(key: "x", path: "/file \(i).mp3") } }
            try await group.waitForAll()
        }
    }
    static func pauseBeforeStart() async throws {
        let transfer = FileTransfer(progress: { _ in }); transfer.pause()
        do { _ = try await transfer.download(url: URL(string: "https://example.test/file")!); throw CheckFailure(message: "Pause ignored") }
        catch is TransferPaused {}
    }
    static func downloadHTTPError() async throws {
        let config = MockProtocol.configure { _ in (429, ["Retry-After":"5"], Data("limit".utf8)) }
        let transfer = FileTransfer(configuration: config, progress: { _ in })
        do { _ = try await transfer.download(url: URL(string: "https://example.test/file")!); throw CheckFailure(message: "HTTP error ignored") }
        catch DiskError.http(let code, let delay) { try check(code == 429 && delay == 5) }
    }
    static func streamingDownload() async throws {
        let config = MockProtocol.configure { _ in (200, ["Content-Length":"3"], Data("abc".utf8)) }
        let transfer = FileTransfer(configuration: config, streaming: true, progress: { _ in })
        let file = try await transfer.download(url: URL(string: "https://example.test/stream")!)
        defer { try? FileManager.default.removeItem(at: file) }
        let data = try Data(contentsOf: file); try check(data == Data("abc".utf8))
    }
    static func stalledTransfer() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [HangingProtocol.self]
        let transfer = FileTransfer(configuration: config, idleTimeout: 0.1, progress: { _ in })
        do { _ = try await transfer.download(url: URL(string: "https://example.test/stalled")!); throw CheckFailure(message: "Stalled request accepted") }
        catch let error as TransferFailure { try check((error.underlying as? URLError)?.code == .timedOut) }
    }
    static func nameNormalization() throws {
        try check(SafePath.localName("Album:2026") == "Album_2026")
        try check(SafePath.localName("a\\b.mp3") == "a_b.mp3")
        try check(SafePath.localName("line\nname") == "line_name")
        let long = String(repeating: "я", count: 200) + ".mp3"
        let short = try SafePath.localName(long)
        try check(short.utf8.count <= 255 && short.hasSuffix(".mp3"))
        try check(short == SafePath.localName(long))
        try mustThrow { _ = try SafePath.localName("../escape") }
        try mustThrow { _ = try SafePath.localName("..") }
        try SafePath.validateAPI("/Album:2026/a\\b.mp3")
        try mustThrow { try SafePath.validateAPI("/a//b") }
    }
    static func normalizationScan() async throws {
        let json = #"{"name":"Album:2026","type":"dir","_embedded":{"total":5,"items":[{"name":"A.mp3","type":"file","path":"/encoded-path","size":3},{"name":"a.mp3","type":"file","size":4},{"name":"nested:dir","type":"dir"},{"name":"../evil","type":"file","size":10},{"name":"safe.mp3","type":"file","size":5}]}}"#
        let nested = #"{"name":"nested:dir","type":"dir","_embedded":{"total":1,"items":[{"name":"clip.mp3","type":"file","size":6}]}}"#
        let config = MockProtocol.configure { request in
            let path = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems?.first { $0.name == "path" }?.value
            if path != nil { try check(path == "/nested:dir") }
            return (200, [:], Data((path == nil ? json : nested).utf8))
        }
        let result = try await FolderScanner(api: DiskAPI(session: URLSession(configuration: config))).scan(key: "test")
        try check(result.name == "Album:2026" && result.localName == "Album_2026")
        try check(result.files.count == 4 && result.warnings.count == 4)
        try check(result.files[1].components == ["Album_2026", "a (1).mp3"])
        try check(result.files[3].apiPath == "/nested:dir/clip.mp3")
        try check(result.files[3].components == ["Album_2026", "nested_dir", "clip.mp3"])
    }
    static func prefixedPathsAndMissingFolder() async throws {
        let root = #"{"name":"Shared","path":"/prefix","type":"dir","_embedded":{"total":3,"items":[{"name":"available","path":"/prefix/available","type":"dir"},{"name":"gone","path":"/prefix/gone","type":"dir"},{"name":"direct.mp3","path":"/prefix/direct.mp3","type":"file","size":3}]}}"#
        let nested = #"{"name":"available","type":"dir","_embedded":{"total":1,"items":[{"name":"song.mp3","path":"/prefix/available/song.mp3","type":"file","size":4}]}}"#
        let config = MockProtocol.configure { request in
            let path = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems?.first { $0.name == "path" }?.value
            if path == nil { return (200, [:], Data(root.utf8)) }
            if path == "/prefix/available" { return (200, [:], Data(nested.utf8)) }
            if path == "/prefix/gone" { return (404, [:], Data()) }
            throw CheckFailure(message: "Wrong API path")
        }
        let result = try await FolderScanner(api: DiskAPI(session: URLSession(configuration: config), retries: 0)).scan(key: "test")
        try check(result.files.count == 2 && result.warnings.count == 1)
        try check(result.files[0].apiPath == "/prefix/direct.mp3")
        try check(result.files[1].components == ["Shared", "available", "song.mp3"])
    }
    static func cancelledTransfer() async throws {
        let transfer = FileTransfer(progress: { _ in }); transfer.cancel()
        do { _ = try await transfer.download(url: URL(string: "https://example.test/test")!); throw CheckFailure(message: "Cancellation ignored") } catch is CancellationError {}
    }
}

#if canImport(XCTest)
final class CoreTests: XCTestCase {
    func testLinks() throws { try Scenarios.links() }
    func testJSONParsing() throws { try Scenarios.parsing() }
    func testRecursivePagination() async throws { try await Scenarios.recursion() }
    func testSingleFile() async throws { try await Scenarios.singleFile() }
    func testHTTPAndRetry() async throws { try await Scenarios.httpAndRetry() }
    func testIncompletePage() async throws { try await Scenarios.incompletePage() }
    func testUnsafeNames() throws { try Scenarios.unsafeNames() }
    func testVerificationAndSafeWrites() throws { try Scenarios.fileSystem() }
    func testDownloadFile() async throws { try await Scenarios.download() }
    func testConcurrentAPI() async throws { try await Scenarios.concurrentAPI() }
    func testPauseBeforeStart() async throws { try await Scenarios.pauseBeforeStart() }
    func testDownloadHTTPError() async throws { try await Scenarios.downloadHTTPError() }
    func testStalledTransfer() async throws { try await Scenarios.stalledTransfer() }
    func testStreamingDownload() async throws { try await Scenarios.streamingDownload() }
    func testNameNormalization() throws { try Scenarios.nameNormalization() }
    func testNormalizationScan() async throws { try await Scenarios.normalizationScan() }
    func testPrefixedPathsAndMissingFolder() async throws { try await Scenarios.prefixedPathsAndMissingFolder() }
    func testCancellation() async throws { try await Scenarios.cancelledTransfer() }
}
#else
// The CLT distribution has Swift Testing but no XCTest. Same scenarios, same mocks.
@Suite(.serialized) struct CoreTests {
    @Test func links() throws { try Scenarios.links() }
    @Test func parsing() throws { try Scenarios.parsing() }
    @Test func recursivePagination() async throws { try await Scenarios.recursion() }
    @Test func singleFile() async throws { try await Scenarios.singleFile() }
    @Test func httpAndRetry() async throws { try await Scenarios.httpAndRetry() }
    @Test func incompletePage() async throws { try await Scenarios.incompletePage() }
    @Test func unsafeNames() throws { try Scenarios.unsafeNames() }
    @Test func verificationAndSafeWrites() throws { try Scenarios.fileSystem() }
    @Test func downloadFile() async throws { try await Scenarios.download() }
    @Test func concurrentAPI() async throws { try await Scenarios.concurrentAPI() }
    @Test func pauseBeforeStart() async throws { try await Scenarios.pauseBeforeStart() }
    @Test func downloadHTTPError() async throws { try await Scenarios.downloadHTTPError() }
    @Test func stalledTransfer() async throws { try await Scenarios.stalledTransfer() }
    @Test func streamingDownload() async throws { try await Scenarios.streamingDownload() }
    @Test func nameNormalization() throws { try Scenarios.nameNormalization() }
    @Test func normalizationScan() async throws { try await Scenarios.normalizationScan() }
    @Test func prefixedPathsAndMissingFolder() async throws { try await Scenarios.prefixedPathsAndMissingFolder() }
    @Test func cancellation() async throws { try await Scenarios.cancelledTransfer() }
}
#endif
