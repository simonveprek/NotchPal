import Darwin
import Foundation

/// Where NotchPal listens and the reporter connects.
///
/// A Unix domain socket rather than a TCP port: no port to collide with, nothing
/// exposed to the network, and file permissions do the access control for us.
public enum EventSocket {
    /// `sockaddr_un.sun_path` is 104 bytes on Darwin. Application Support fits for
    /// virtually every user, but fall back to the per-user temp directory rather
    /// than failing on an unusually long home path.
    public static let maxPathLength = 100

    public static var supportDirectory: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/NotchPal", directoryHint: .isDirectory)
    }

    public static var path: String {
        if let override = ProcessInfo.processInfo.environment["NOTCHPAL_SOCKET"], !override.isEmpty {
            return override
        }
        // Keep accepting the original variable for scripts written before the rename.
        if let legacy = ProcessInfo.processInfo.environment["NOTCHPAL_SOCKET"], !legacy.isEmpty {
            return legacy
        }
        let preferred = supportDirectory.appending(path: "notchpal.sock").path(percentEncoded: false)
        if preferred.utf8.count <= maxPathLength { return preferred }
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("notchpal.sock")
    }

    static func address(for path: String) throws -> (sockaddr_un, socklen_t) {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw SocketError.pathTooLong(path) }

        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return (addr, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}

public enum SocketError: Error, CustomStringConvertible {
    case pathTooLong(String)
    case syscall(String, Int32)

    public var description: String {
        switch self {
        case let .pathTooLong(path): "Socket path is too long for a Unix domain socket: \(path)"
        case let .syscall(name, code): "\(name) failed: \(String(cString: strerror(code)))"
        }
    }
}
