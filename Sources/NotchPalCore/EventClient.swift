import Darwin
import Foundation

/// Ships one event to the running app and gets out of the way.
///
/// This runs inside the agent's hook, on the agent's critical path, so every branch
/// here is written to fail fast and silently. If NotchPal is not running, the agent
/// must not notice. There is no retry, no queue, no backoff — a dropped status
/// update is worth far less than a stalled agent.
public enum EventClient {
    @discardableResult
    public static func send(_ event: AgentEvent, path: String = EventSocket.path, timeout: TimeInterval = 0.25) -> Bool {
        guard let payload = try? event.lineEncoded() else { return false }
        return send(payload, path: path, timeout: timeout)
    }

    static func send(_ payload: Data, path: String, timeout: TimeInterval) -> Bool {
        guard let (addr, length) = try? EventSocket.address(for: path) else { return false }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        // Never let a wedged listener hold the agent hostage.
        var tv = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var address = addr
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, length)
            }
        }
        guard connected == 0 else { return false }

        return payload.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(fd, base.advanced(by: sent), raw.count - sent, 0)
                if n > 0 {
                    sent += n
                } else if n < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}
