import Foundation

public protocol ResourceProviding: Sendable {
    func resource(key: String, path: String?, offset: Int, limit: Int) async throws -> Resource
}

/// Serializes API starts and shares a Retry-After cooldown across every worker.
public actor DiskAPI: ResourceProviding {
    private let session: URLSession
    private let retries: Int
    private let status: @Sendable (String) -> Void
    private var nextRequest = Date.distantPast
    public init(session: URLSession = .shared, retries: Int = 3, status: @escaping @Sendable (String) -> Void = { _ in }) { self.session = session; self.retries = retries; self.status = status }

    public func cooldown(_ seconds: TimeInterval) { nextRequest = max(nextRequest, Date().addingTimeInterval(seconds)) }
    private func throttle() async throws {
        while nextRequest > Date() { try await RetryPolicy.sleep(nextRequest.timeIntervalSinceNow) }
        nextRequest = Date().addingTimeInterval(0.15)
    }
    public func resource(key: String, path: String? = nil, offset: Int = 0, limit: Int = 100) async throws -> Resource {
        try await request(endpoint: "resources", key: key, path: path, extra: [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "sort", value: "name")])
    }
    public func downloadURL(key: String, path: String?) async throws -> URL {
        let result: DownloadLink = try await request(endpoint: "resources/download", key: key, path: path)
        guard result.href.scheme == "https", result.href.host != nil, result.method == nil || result.method == "GET", result.templated != true else { throw DiskError.invalidResponse }
        return result.href
    }
    private func request<T: Decodable>(endpoint: String, key: String, path: String?, extra: [URLQueryItem] = []) async throws -> T {
        if let path { try SafePath.validateAPI(path) }
        var url = URLComponents(string: "https://cloud-api.yandex.net/v1/disk/public/\(endpoint)")!
        url.queryItems = [URLQueryItem(name: "public_key", value: key)] + extra
        if let path { url.queryItems?.append(URLQueryItem(name: "path", value: path)) }
        var request = URLRequest(url: url.url!); request.timeoutInterval = 40
        request.setValue("YandexDiskDownloader/1.0", forHTTPHeaderField: "User-Agent")
        for attempt in 0...retries {
            try Task.checkCancellation()
            do {
                try await throttle()
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw DiskError.invalidResponse }
                guard (200...299).contains(http.statusCode) else { throw DiskError.http(http.statusCode, RetryPolicy.retryAfter(http.value(forHTTPHeaderField: "Retry-After"))) }
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                if case DiskError.http(429, let delay) = error { cooldown(delay ?? 2) }
                guard attempt < retries, RetryPolicy.isTransient(error) else { throw error }
                let delay = RetryPolicy.delay(attempt: attempt, error: error)
                status("API retry \(attempt + 1)/\(retries), waiting \(Int(delay)) s. " + ErrorMessage.safe(error))
                cooldown(delay); try await RetryPolicy.sleep(delay)
            }
        }
        throw DiskError.invalidResponse
    }
}

public struct FolderScanner: Sendable {
    private let api: any ResourceProviding
    private let pageSize: Int
    public init(api: any ResourceProviding, pageSize: Int = 100) { self.api = api; self.pageSize = pageSize }
    public func scan(key: String, progress: @Sendable (Int) -> Void = { _ in }) async throws -> Manifest {
        let root = try await api.resource(key: key, path: nil, offset: 0, limit: pageSize)
        let rootLocalName = try SafePath.localName(root.name)
        var warnings: [String] = rootLocalName == root.name ? [] : ["Renamed locally: \(root.name) → \(rootLocalName)"]
        if root.type == "file" {
            return Manifest(name: root.name, localName: rootLocalName, isDirectory: false, files: [RemoteFile(apiPath: nil, components: [rootLocalName], size: root.size, md5: root.md5, sha256: root.sha256)], directories: [], warnings: warnings)
        }
        guard root.type == "dir" else { throw DiskError.invalidResponse }
        var queue: [(String?, [String], Resource?)] = [(nil, [rootLocalName], root)]
        var directories: [[String]] = [[rootLocalName]], files: [RemoteFile] = []
        var index = 0; var visitedDirectories = Set<String>()
        while index < queue.count {
            try Task.checkCancellation()
            let (path, components, cached) = queue[index]; index += 1
            var offset = 0; var current = cached; var expectedTotal: Int?
            var usedNames = Set<String>(); var seenRemoteNames = Set<String>()
            repeat {
                let page: Resource
                if let current { page = current } else {
                    do { page = try await api.resource(key: key, path: path, offset: offset, limit: pageSize) }
                    catch {
                        if path == nil || Task.isCancelled || error is CancellationError { throw error }
                        warnings.append("Skipped unavailable folder \(components.joined(separator: "/")): \(ErrorMessage.safe(error))")
                        break
                    }
                }
                current = nil
                guard page.type == "dir", let listing = page.embedded else { throw DiskError.invalidResponse }
                if let listedOffset = listing.offset, listedOffset != offset { throw DiskError.incompleteListing }
                if let expectedTotal, let total = listing.total, total != expectedTotal { throw DiskError.incompleteListing }
                expectedTotal = listing.total
                if listing.items.isEmpty {
                    if let total = listing.total, offset < total { throw DiskError.incompleteListing }
                    break
                }
                for child in listing.items {
                    let localName: String
                    do {
                        try SafePath.validateRemoteName(child.name)
                        let remoteIdentity = Data(child.name.utf8).base64EncodedString()
                        guard seenRemoteNames.insert(remoteIdentity).inserted else { throw DiskError.incompleteListing }
                        localName = try SafePath.reserveLocalName(SafePath.localName(child.name), used: &usedNames)
                    } catch DiskError.incompleteListing { throw DiskError.incompleteListing }
                    catch { warnings.append("Skipped unsafe name in \(components.joined(separator: "/")): \(child.name.debugDescription)"); continue }
                    // Yandex can return paths with a prefix different from the
                    // displayed folder hierarchy. Treat them as API-only paths;
                    // never use them for local filesystem writes.
                    let base = path ?? root.path ?? ""
                    let fallback = (base == "/" ? "" : base) + "/" + child.name
                    let apiPath = child.path ?? fallback
                    do { try SafePath.validateAPI(apiPath) }
                    catch { warnings.append("Skipped unsafe API path for \(child.name.debugDescription)"); continue }
                    let childComponents = components + [localName]
                    guard childComponents.count < 256 else { warnings.append("Skipped overly deep path: \(apiPath)"); continue }
                    if localName != child.name { warnings.append("Renamed locally: \(apiPath) → \(childComponents.joined(separator: "/"))") }
                    if child.type == "dir" {
                        let identity = Data(apiPath.utf8).base64EncodedString()
                        guard visitedDirectories.insert(identity).inserted else { warnings.append("Skipped repeated folder: \(components.joined(separator: "/"))/\(child.name)"); continue }
                        directories.append(childComponents); queue.append((apiPath, childComponents, nil))
                    }
                    else if child.type == "file" { files.append(RemoteFile(apiPath: apiPath, components: childComponents, size: child.size, md5: child.md5, sha256: child.sha256)) }
                    else { throw DiskError.invalidResponse }
                }
                offset += listing.items.count; progress(files.count)
                if let total = listing.total {
                    guard offset <= total else { throw DiskError.incompleteListing }
                    if offset == total { break }
                } else if listing.items.count < pageSize { break }
            } while true
        }
        return Manifest(name: root.name, localName: rootLocalName, isDirectory: true, files: files, directories: directories, warnings: warnings)
    }
}
