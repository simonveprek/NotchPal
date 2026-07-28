import Darwin
import Foundation

/// Listens on the NotchPal socket and hands decoded events to the app.
///
/// Connections are short-lived: a reporter connects, writes one line, and closes.
/// Each connection is drained on a background queue and events are delivered on
/// the queue the caller asks for.
public final class EventServer: @unchecked Sendable {
    public typealias Handler = @Sendable (AgentEvent) -> Void

    private let path: String
    private let handler: Handler
    private let deliveryQueue: DispatchQueue
    private let acceptQueue = DispatchQueue(label: "app.notchpal.server.accept")
    private let readQueue = DispatchQueue(label: "app.notchpal.server.read", attributes: .concurrent)

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    public init(path: String = EventSocket.path, deliverOn: DispatchQueue = .main, handler: @escaping Handler) {
        self.path = path
        self.deliveryQueue = deliverOn
        self.handler = handler
    }

    deinit { stop() }

    public func start() throws {
        try FileManager.default.createDirectory(
            at: URL(filePath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // A socket file left behind by a crash would block bind(); it is ours to clear.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.syscall("socket", errno) }

        var (addr, length) = try EventSocket.address(for: path)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, length)
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw SocketError.syscall("bind", code)
        }

        // Only this user may talk to the notch.
        chmod(path, 0o600)

        guard Darwin.listen(fd, 32) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw SocketError.syscall("listen", code)
        }

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            listenFD = -1
            unlink(path)
        }
    }

    private func acceptOne() {
        let client = Darwin.accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        readQueue.async { [weak self] in
            self?.drain(client)
            close(client)
        }
    }

    /// Reads until EOF, splitting on newlines. A reporter writes a single line, but
    /// framing the stream properly means a future batching client costs nothing.
    private func drain(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)

        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0 ..< n])
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex ..< newline]
                    buffer = buffer[buffer.index(after: newline)...]
                    deliver(Data(line))
                }
                // Guard against a client that never sends a newline.
                if buffer.count > 1 << 20 { return }
            } else if n == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                return
            }
        }

        if !buffer.isEmpty { deliver(buffer) }
    }

    private func deliver(_ line: Data) {
        guard !line.isEmpty, let event = try? AgentEvent.decoder.decode(AgentEvent.self, from: line) else { return }
        deliveryQueue.async { self.handler(event) }
    }
}
