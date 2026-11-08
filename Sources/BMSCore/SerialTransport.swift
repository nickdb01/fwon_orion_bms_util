import Foundation
import Darwin
import IOKit
import CSerial

public struct SerialPortInfo: Identifiable, Hashable, Sendable {
    public var path: String
    public var name: String
    public var id: String { path }
    public static func available() -> [SerialPortInfo] {
        var iterator: io_iterator_t = 0
        var ports: [SerialPortInfo] = []
        let match = IOServiceMatching("IOSerialBSDClient")
        if IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            var service = IOIteratorNext(iterator)
            while service != 0 {
                let path = IORegistryEntryCreateCFProperty(service, "IOCalloutDevice" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
                let label = IORegistryEntryCreateCFProperty(service, "IOTTYDevice" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
                if let path { ports.append(.init(path: path, name: label ?? URL(fileURLWithPath: path).lastPathComponent)) }
                IOObjectRelease(service); service = IOIteratorNext(iterator)
            }
        }
        // Some third-party drivers publish only the BSD node.
        if let names = try? FileManager.default.contentsOfDirectory(atPath: "/dev") {
            for name in names where name.hasPrefix("cu.") {
                let path = "/dev/" + name
                if !ports.contains(where: { $0.path == path }) { ports.append(.init(path: path, name: String(name.dropFirst(3)))) }
            }
        }
        return ports.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

protocol DiagnosticTransport: AnyObject {
    var trace: [TraceEntry] { get }
    func exchange(_ request: ReadRequest) throws -> WireReply
    func close()
}

final class SerialTransport: DiagnosticTransport {
    private var fd: Int32 = -1
    private(set) var trace: [TraceEntry] = []
    private let timeout: TimeInterval
    init(path: String, timeout: TimeInterval = 2.0, requireRTS: Bool = true) throws {
        self.timeout = timeout
        fd = path.withCString { orion_serial_open($0) }
        guard fd >= 0 else { throw Self.systemError("Open \(path)") }
        guard orion_serial_configure(fd, requireRTS ? 1 : 0) == 0 else {
            let error = Self.systemError("Configure 9600 8E1 and RTS")
            close(); throw error
        }
    }
    deinit { close() }
    func close() { if fd >= 0 { _ = orion_serial_close(fd); fd = -1 } }
    private static func systemError(_ operation: String) -> BMSError {
        let code = errno
        if code == ENXIO || code == ENODEV || code == EIO { return .disconnected }
        return .io("\(operation): \(String(cString: strerror(code))).")
    }
    private func record(_ entry: TraceEntry) {
        trace.append(entry)
        if trace.count > 8000 { trace.removeFirst(1000) }
    }
    func exchange(_ request: ReadRequest) throws -> WireReply {
        guard fd >= 0 else { throw BMSError.disconnected }
        var lastError: Error = BMSError.timeout
        // Only idempotent diagnostic reads can reach this bounded retry path.
        for attempt in 0..<2 {
            try Task.checkCancellation()
            if attempt > 0 { record(.init(direction: "NOTE", text: "Retrying \(request.body.hex)")) }
            guard orion_serial_flush(fd) == 0 else { throw Self.systemError("Flush input") }
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            let bytes = Array(request.frame)
            var offset = 0
            record(.init(direction: "TX", text: ":" + request.body.hex))
            while offset < bytes.count {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw BMSError.timeout }
                let ready = orion_serial_wait(fd, 1, 50)
                if ready < 0 { if errno == EINTR { continue }; throw Self.systemError("Wait to write") }
                if ready == 0 { continue }
                let written = bytes.withUnsafeBufferPointer { p in orion_serial_write(fd, p.baseAddress!.advanced(by: offset), bytes.count - offset) }
                if written < 0 { if errno == EAGAIN || errno == EINTR { continue }; throw Self.systemError("Write") }
                offset += written
            }
            var parser = FrameParser()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                let ready = orion_serial_wait(fd, 0, 50)
                if ready < 0 { if errno == EINTR { continue }; throw Self.systemError("Wait for reply") }
                if ready == 0 { continue }
                let n = buffer.withUnsafeMutableBufferPointer { orion_serial_read(fd, $0.baseAddress!, $0.count) }
                if n < 0 { if errno == EAGAIN || errno == EINTR { continue }; throw Self.systemError("Read") }
                if n == 0 { continue }
                record(.init(direction: "RX", text: Data(buffer.prefix(n)).map { String(format: "%02X", $0) }.joined()))
                for result in parser.feed(Data(buffer.prefix(n))) {
                    switch result {
                    case .failure(let error):
                        lastError = error
                        record(.init(direction: "PARSE", text: error.localizedDescription))
                    case .success(let reply):
                        if reply.service == 0x7F && reply.pid == request.service {
                            let reason = reply.payload[0]
                            if reason == 0x78 { continue } // bounded wait for response pending
                            if [0x11, 0x12, 0x31].contains(reason) { throw BMSError.unsupported(reason) }
                            throw BMSError.rejected(reason)
                        }
                        if request.matches(reply) { return reply }
                        record(.init(direction: "SKIP", text: "Unmatched reply :" + reply.bytes.hex))
                    }
                }
            }
        }
        throw lastError
    }
}
