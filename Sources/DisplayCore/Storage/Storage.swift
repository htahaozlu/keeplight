import Darwin
import Foundation

/// Product constants shared by the app and the CLI.
public enum Keeplight {
    public static let version = "0.3.0"
    public static let bundleIdentifier = "io.github.htahaozlu.Keeplight"

    /// `~/Library/Application Support/Keeplight`, or `$KEEPLIGHT_SUPPORT_DIR` when set.
    /// Holds `journal.jsonl`, `pending.json`, `known-good.json`, `disconnected.json`, `mirrors.json`.
    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["KEEPLIGHT_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Keeplight", isDirectory: true)
    }
}

/// File primitives for state shared between the app and the CLI.
enum FileStore {
    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Runs `body` holding an exclusive `flock` on `lockURL` (created on demand). A separate
    /// lock file keeps the lock valid across atomic replaces of the data file.
    static func withLock<T>(_ lockURL: URL, _ body: () throws -> T) throws -> T {
        try ensureDirectory(lockURL.deletingLastPathComponent())
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw posixError("open \(lockURL.lastPathComponent)") }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw posixError("flock \(lockURL.lastPathComponent)") }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    /// Writes `data` to a temporary file, `fsync`s it and renames it over `url`.
    static func atomicWrite(_ data: Data, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        let fd = open(tmp.path, O_CREAT | O_TRUNC | O_WRONLY | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw posixError("open \(tmp.lastPathComponent)") }
        do {
            try writeAll(fd, data)
            guard fsync(fd) == 0 else { throw posixError("fsync \(tmp.lastPathComponent)") }
            close(fd)
        } catch {
            close(fd)
            unlink(tmp.path)
            throw error
        }
        guard rename(tmp.path, url.path) == 0 else {
            let error = posixError("rename \(url.lastPathComponent)")
            unlink(tmp.path)
            throw error
        }
        let dir = open(url.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
        if dir >= 0 {
            fsync(dir)
            close(dir)
        }
    }

    /// Appends `data` with `O_APPEND`.
    static func append(_ data: Data, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        let fd = open(url.path, O_CREAT | O_WRONLY | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw posixError("open \(url.lastPathComponent)") }
        defer { close(fd) }
        try writeAll(fd, data)
    }

    static func remove(_ url: URL) {
        unlink(url.path)
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw posixError("write")
                }
                offset += n
            }
        }
    }

    static func posixError(_ op: String) -> DisplayError {
        .unavailable("\(op): \(String(cString: strerror(errno)))")
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// A Codable value persisted as one JSON file, read and replaced under a `flock`.
struct JSONFile<Value: Codable & Sendable>: Sendable {
    let url: URL
    let empty: Value

    var lockURL: URL { url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).lock") }

    func load() -> Value {
        guard let data = try? Data(contentsOf: url) else { return empty }
        return (try? FileStore.decoder.decode(Value.self, from: data)) ?? empty
    }

    @discardableResult
    func update<T>(_ body: (inout Value) throws -> T) throws -> T {
        try FileStore.withLock(lockURL) {
            var value = load()
            let result = try body(&value)
            try FileStore.atomicWrite(try FileStore.encoder.encode(value), to: url)
            return result
        }
    }
}
