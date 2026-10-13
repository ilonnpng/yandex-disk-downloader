import Foundation
import CryptoKit
import Darwin

public enum FileVerifier {
    public static func verify(url: URL, file: RemoteFile, size: Bool, checksum: Bool) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw DiskError.fileSystem("Cannot read file for verification: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        try verify(fd: fd, file: file, size: size, checksum: checksum)
    }
    static func verify(fd: Int32, file: RemoteFile, size: Bool, checksum: Bool) throws {
        var info = stat(); guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw DiskError.unsafePath }
        if size, let expected = file.size, info.st_size != expected { throw DiskError.sizeMismatch }
        guard checksum, file.sha256 != nil || file.md5 != nil else { return }
        var sha = SHA256(); var md5 = Insecure.MD5()
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.seek(toOffset: 0)
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            if file.sha256 != nil { sha.update(data: data) } else { md5.update(data: data) }
        }
        let digest = file.sha256 != nil ? sha.finalize().map { String(format: "%02x", $0) }.joined() : md5.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == (file.sha256 ?? file.md5)?.lowercased() else { throw DiskError.checksumMismatch }
    }
}

/// Pinned directory descriptors + openat(O_NOFOLLOW) prevent symlink traversal.
/// linkat publishes a verified staging file atomically without overwriting anything.
public final class SafeDestination: @unchecked Sendable {
    public let url: URL
    private let root: Int32
    public init(url: URL) throws {
        self.url = url.standardizedFileURL
        root = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard root >= 0 else { throw DiskError.fileSystem("Cannot open destination: \(String(cString: strerror(errno)))") }
    }
    deinit { close(root) }
    private func directory(_ components: [String], create: Bool) throws -> Int32 {
        var fd = dup(root)
        guard fd >= 0 else { throw DiskError.fileSystem("Cannot access destination.") }
        do {
            for name in components {
                try SafePath.validate(name)
                if create, mkdirat(fd, name, 0o755) != 0, errno != EEXIST { throw fsError() }
                let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard next >= 0 else { throw fsError() }
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }
    public func makeDirectory(_ components: [String]) throws { let fd = try directory(components, create: true); close(fd) }
    public func existingMatches(_ file: RemoteFile, verifySize: Bool, verifyChecksum: Bool) throws -> Bool {
        guard let name = file.components.last else { throw DiskError.unsafePath }; try SafePath.validate(name)
        let parent = try directory(Array(file.components.dropLast()), create: true); defer { close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 { if errno == ENOENT { return false }; throw fsError() }
        defer { close(fd) }
        do { try FileVerifier.verify(fd: fd, file: file, size: verifySize, checksum: verifyChecksum); return true }
        catch DiskError.sizeMismatch { return false }
        catch DiskError.checksumMismatch { return false }
    }
    @discardableResult public func commit(temp: URL, components: [String]) throws -> String {
        guard let name = components.last else { throw DiskError.unsafePath }; try SafePath.validate(name)
        let parent = try directory(Array(components.dropLast()), create: true); defer { close(parent) }
        let staging = ".ydd-\(UUID().uuidString).partial"
        let output = openat(parent, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard output >= 0 else { throw fsError() }
        defer { close(output); unlinkat(parent, staging, 0) }
        let input = try FileHandle(forReadingFrom: temp); defer { try? input.close() }
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 { if errno == EINTR { continue }; throw fsError() }; offset += count
                }
            }
        }
        guard fsync(output) == 0 else { throw fsError() }
        let ns = name as NSString; let ext = ns.pathExtension; let stem = ns.deletingPathExtension
        for suffix in 0...10000 {
            let candidate = suffix == 0 ? name : "\(stem) (\(suffix))" + (ext.isEmpty ? "" : ".\(ext)")
            try SafePath.validate(candidate)
            if linkat(parent, staging, parent, candidate, 0) == 0 { return candidate }
            if errno != EEXIST { throw fsError() }
        }
        throw DiskError.fileSystem("Too many files with the same name.")
    }
    private func fsError() -> DiskError { .fileSystem("Destination error: \(String(cString: strerror(errno))). Check free disk space and write permission.") }
}
