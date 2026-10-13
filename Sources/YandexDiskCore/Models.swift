import Foundation
import CryptoKit

public enum DiskError: Error, LocalizedError {
    case invalidLink, unsafePath, invalidResponse, incompleteListing
    case http(Int, TimeInterval?), sizeMismatch, checksumMismatch, fileSystem(String)
    public var errorDescription: String? {
        switch self {
        case .invalidLink: return "Use a public HTTPS link from disk.yandex.ru, disk.yandex.com or yadi.sk."
        case .unsafePath: return "An unsafe or conflicting file path was rejected."
        case .invalidResponse: return "The server returned an invalid response."
        case .incompleteListing: return "The folder changed or returned an incomplete listing. Inspect it again."
        case .http(let code, _):
            switch code {
            case 403: return "Access denied (403). The owner or Yandex may have restricted downloads."
            case 404: return "Resource not found (404). The public link may have been removed."
            case 429: return "Yandex request limit reached (429). Please try again later."
            default: return "Server request failed (HTTP \(code))."
            }
        case .sizeMismatch: return "The downloaded size does not match the source."
        case .checksumMismatch: return "The downloaded checksum does not match the source."
        case .fileSystem(let message): return message
        }
    }
}

public enum PublicLink {
    public static func validate(_ input: String) throws -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: text), parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(),
              ["disk.yandex.ru", "disk.yandex.com", "disk.yandex.kz", "disk.yandex.by", "disk.yandex.com.tr", "yadi.sk"].contains(host),
              parts.user == nil, parts.password == nil, parts.port == nil else { throw DiskError.invalidLink }
        let path = parts.path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.count >= 2, ["d", "i", "public"].contains(String(path[0])), !path[1].isEmpty else { throw DiskError.invalidLink }
        parts.fragment = nil
        guard let url = parts.url else { throw DiskError.invalidLink }
        return url.absoluteString
    }
}

public struct Resource: Codable, Sendable {
    public let name: String
    public let type: String
    public let path: String?
    public let size: Int64?
    public let md5: String?
    public let sha256: String?
    public let embedded: Listing?
    enum CodingKeys: String, CodingKey { case name, type, path, size, md5, sha256; case embedded = "_embedded" }
}
public struct Listing: Codable, Sendable {
    public let items: [Resource]
    public let total: Int?
    public let offset: Int?
    public let limit: Int?
}
public struct DownloadLink: Decodable { public let href: URL; public let method: String?; public let templated: Bool? }

public struct RemoteFile: Identifiable, Codable, Sendable {
    public var id: String { components.joined(separator: "/") }
    public let apiPath: String?
    public let components: [String]
    public let size: Int64?
    public let md5: String?
    public let sha256: String?
    public init(apiPath: String?, components: [String], size: Int64?, md5: String? = nil, sha256: String? = nil) {
        self.apiPath = apiPath; self.components = components; self.size = size; self.md5 = md5; self.sha256 = sha256
    }
}
public struct Manifest: Sendable {
    public let name: String
    public let localName: String
    public let isDirectory: Bool
    public let files: [RemoteFile]
    public let directories: [[String]]
    public let warnings: [String]
    public var skippedItems: Int { warnings.filter { $0.hasPrefix("Skipped ") }.count }
    public var totalSize: Int64 { files.reduce(0) { $0 + max(0, $1.size ?? 0) } }
    public var hasKnownSize: Bool { files.allSatisfy { $0.size != nil } }
}

public enum SafePath {
    /// API names and local names have different constraints. A colon or backslash
    /// can be a legitimate remote name and must not invalidate an entire folder.
    public static func validateRemoteName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw DiskError.unsafePath }
    }
    public static func localName(_ remote: String) throws -> String {
        try validateRemoteName(remote)
        var name = String(remote.unicodeScalars.map { scalar -> Character in
            if scalar == ":" || scalar == "\\" || CharacterSet.controlCharacters.contains(scalar) { return "_" }
            return Character(String(scalar))
        })
        if name.utf8.count > 220 {
            let suffix = SHA256.hash(data: Data(remote.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
            let ext = (name as NSString).pathExtension
            let extensionSuffix = ext.utf8.count <= 24 && !ext.isEmpty ? "." + ext : ""
            if !extensionSuffix.isEmpty { name = (name as NSString).deletingPathExtension }
            while name.utf8.count > 200 { name.removeLast() }
            name += "-" + suffix + extensionSuffix
        }
        try validate(name); return name
    }
    /// Stable per-folder naming also resolves case-insensitive / Unicode collisions.
    public static func reserveLocalName(_ candidate: String, used: inout Set<String>) throws -> String {
        let ns = candidate as NSString; let ext = ns.pathExtension; let stem = ns.deletingPathExtension
        for suffix in 0...10000 {
            let name = suffix == 0 ? candidate : "\(stem) (\(suffix))" + (ext.isEmpty ? "" : ".\(ext)")
            try validate(name)
            let folded = name.precomposedStringWithCanonicalMapping.lowercased()
            if used.insert(folded).inserted { return name }
        }
        throw DiskError.unsafePath
    }
    public static func validate(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              !name.contains(":"), name.utf8.count <= 255,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw DiskError.unsafePath }
    }
    public static func validateAPI(_ path: String) throws {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw DiskError.unsafePath }
        if path == "/" { return }
        for component in path.dropFirst().split(separator: "/", omittingEmptySubsequences: false) { try validateRemoteName(String(component)) }
    }
}

public enum RetryPolicy {
    public static func isTransient(_ error: Error) -> Bool {
        if case DiskError.http(let status, _) = error { return status == 429 || (500...599).contains(status) || status == 408 }
        if let e = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(e.code)
        }
        return false
    }
    public static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = Double(value), seconds.isFinite { return max(0, seconds) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }
    public static func delay(attempt: Int, error: Error) -> TimeInterval {
        if case DiskError.http(_, let delay?) = error { return delay }
        return min(30, pow(2, Double(attempt))) + Double.random(in: 0...0.3)
    }
    public static func sleep(_ delay: TimeInterval) async throws {
        var remaining = delay
        while remaining > 0 { try Task.checkCancellation(); let part = min(remaining, 30); try await Task.sleep(nanoseconds: UInt64(part * 1_000_000_000)); remaining -= part }
    }
}
