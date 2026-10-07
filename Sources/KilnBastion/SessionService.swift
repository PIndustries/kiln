import Foundation
import Dispatch
import Crypto
import NIOCore
import NIOPosix
import KilnKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct ServiceRequest: Codable, Sendable {
    var op: String
    var args: [String] = []
    var owner: UUID? = nil
    var width: Int = 80
    var height: Int = 24
    var revision: UInt64? = nil
    var bytes: Data? = nil
}
struct ServiceResponse: Codable, Sendable { var data: Data?; var error: String? }

/// One bounded request per connection. The private directory is the authorization boundary.
private struct ServiceDecoder: ByteToMessageDecoder {
    typealias InboundOut = Data
    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let count: UInt32 = buffer.getInteger(at: buffer.readerIndex) else { return .needMoreData }
        guard count <= 8_388_608 else { throw KilnError.message("IPC frame too large") }
        guard buffer.readableBytes >= Int(count)+4 else { return .needMoreData }
        buffer.moveReaderIndex(forwardBy: 4)
        context.fireChannelRead(wrapInboundOut(Data(buffer.readBytes(length: Int(count))!)))
        return .continue
    }
}
private final class ServiceHandler: ChannelInboundHandler {
    typealias InboundIn = Data
    let bastion: KilnBastion
    var used = false
    init(_ bastion: KilnBastion) { self.bastion = bastion }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !used else { context.close(promise: nil); return }; used = true
        let payload = unwrapInboundIn(data), channel = context.channel, bastion = bastion
        Task {
            let response: ServiceResponse
            do {
                let request = try JSONDecoder().decode(ServiceRequest.self, from: payload)
                response = ServiceResponse(data: try await SessionService.dispatch(request, bastion: bastion), error: nil)
            } catch { response = ServiceResponse(data: nil, error: String(describing: error)) }
            if let encoded = try? JSONEncoder().encode(response), encoded.count <= 8_388_608 {
                var buffer = channel.allocator.buffer(capacity: encoded.count+4)
                buffer.writeInteger(UInt32(encoded.count)); buffer.writeBytes(encoded)
                try? await channel.writeAndFlush(buffer).get()
            }
            try? await channel.close().get()
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

public enum SessionService {
    public static func socketPath(directory: URL) -> String {
        let path = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let hash = SHA256.hash(data: Data(path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "/tmp/kiln-\(getuid())-\(hash)/session.sock"
    }
    public static func run(directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(directory.appendingPathComponent("session-service.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw KilnError.message("Session service already running") }
        defer { close(lock) }
        let path = socketPath(directory: directory), folder = URL(fileURLWithPath: path).deletingLastPathComponent().path
        if mkdir(folder, 0o700) != 0 && errno != EEXIST { throw KilnError.message("Cannot create private IPC directory") }
        var info = stat()
        guard lstat(folder, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o170000 == 0o040000, info.st_mode & 0o777 == 0o700 else {
            throw KilnError.message("Unsafe IPC directory ownership or permissions")
        }
        unlink(path)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2), bastion = KilnBastion(directory: directory)
        let listener = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandlers(ByteToMessageHandler(ServiceDecoder()), ServiceHandler(bastion)) }
        }.bind(unixDomainSocketPath: path).get()
        chmod(path, 0o600)
        try String(getpid()).write(to: directory.appendingPathComponent("session-service.pid"), atomically: true, encoding: .utf8)
        signal(SIGINT, SIG_IGN); signal(SIGHUP, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let signals = AsyncStream<Void> { continuation in
            let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            source.setEventHandler { continuation.yield(()); continuation.finish() }
            continuation.onTermination = { _ in source.cancel() }; source.resume()
        }
        for await _ in signals { break }
        try? await listener.close().get(); await bastion.shutdownSessions()
        try? await group.shutdownGracefully(); unlink(path)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("session-service.pid"))
    }
    static func dispatch(_ request: ServiceRequest, bastion: KilnBastion) async throws -> Data {
        func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
        let a = request.args
        let arity: [String: Int] = ["ping":0,"stop":0,"servers":0,"keys":0,"list":0,"add":4,"edit":4,"remove":1,"profile":1,"allow":2,"createKey":1,"publicKey":1,"deleteKey":1,"assign":2,"generateKey":2,"scan":1,"trust":2,"execute":2,"sessions":0,"new":2,"rename":2,"close":1,"attach":1,"detach":1,"send":1,"resize":1,"frame":1]
        guard arity[request.op] == a.count else { throw KilnError.message("Unsupported session-service request") }
        switch request.op {
        case "ping": return try encode("kiln-session-service/1")
        case "stop":
            Task { try? await Task.sleep(for: .milliseconds(200)); kill(getpid(), SIGTERM) }
            return try encode("Session service stopping; remote sessions will end")
        case "servers": return try encode(await bastion.serverSnapshots())
        case "keys": return try encode(await bastion.keys())
        case "list": return try encode(await bastion.list())
        case "add", "edit":
            guard let port = Int(a[3]) else { throw KilnError.message("Invalid port") }
            if request.op == "add" { return try encode(await bastion.add(name:a[0],host:a[1],user:a[2],port:port)) }
            return try encode(await bastion.edit(name:a[0],host:a[1],user:a[2],port:port))
        case "remove": return try encode(await bastion.remove(a[0]))
        case "profile": return try encode(await bastion.profile(a[0]))
        case "allow": return try encode(await bastion.allowForward(host:a[0],port:Int(a[1]) ?? 0))
        case "createKey": return try encode(await bastion.createKey(a[0]))
        case "publicKey": return try encode(await bastion.publicKey(a[0]))
        case "deleteKey": return try encode(await bastion.deleteKey(a[0]))
        case "assign": return try encode(await bastion.assign(server:a[0],key:a[1]))
        case "generateKey": return try encode(await bastion.generateKey(server:a[0],name:a[1]))
        case "scan": return try encode(await bastion.scan(a[0]))
        case "trust": return try encode(await bastion.trust(a[0],fingerprint:a[1]))
        case "execute": return try encode(await bastion.execute(a[0],command:a[1]))
        case "sessions": return try encode(await bastion.sessionSnapshots())
        case "new": return try encode(await bastion.createSession(name:a[0],server:a[1]))
        case "rename": return try encode(await bastion.renameSession(a[0],to:a[1]))
        case "close": return try encode(await bastion.closeSession(a[0]))
        default:
            guard let owner = request.owner else { throw KilnError.message("Missing viewer identity") }
            let terminal = try await bastion.session(a[0])
            switch request.op {
            case "attach": try await terminal.attach(owner:owner,width:request.width,height:request.height)
            case "detach": terminal.detach(owner:owner)
            case "send":
                guard let bytes = request.bytes, bytes.count <= 65536 else { throw KilnError.message("Invalid input packet") }
                terminal.send(Array(bytes),owner:owner)
            case "resize": terminal.resize(width:request.width,height:request.height,owner:owner)
            case "frame": return try encode(await terminal.frame(owner:owner,after:request.revision))
            default: throw KilnError.message("Unknown request")
            }
            return try encode("")
        }
    }
}

/// Serial per-client queue preserves input/resize ordering. No secrets cross IPC.
private final class ConnectionFailure: @unchecked Sendable { var text: String? }
final class ServiceConnection: Sendable {
    private let failure = ConnectionFailure() // Accessed only on queue.
    let path: String
    let queue = DispatchQueue(label: "industries.p.kiln.session-ipc")
    init(path: String) { self.path = path }
    func exchange(_ request: ServiceRequest) throws -> Data {
        #if os(Linux)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw KilnError.message("Cannot open session-service socket") }; defer { close(fd) }
        var timeout = timeval(tv_sec: 25, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #if canImport(Darwin)
        var yes: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, 4)
        #endif
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)+[0]
        guard bytes.count <= MemoryLayout.size(ofValue:address.sun_path) else { throw KilnError.message("IPC path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from:bytes) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw KilnError.message("Session service unavailable; existing remote session state is unknown") }
        let payload = try JSONEncoder().encode(request)
        var length = UInt32(payload.count).bigEndian
        var packet = withUnsafeBytes(of:&length) { Data($0) }; packet.append(payload)
        try packet.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                #if os(Linux)
                let count = send(fd, bytes.baseAddress!.advanced(by:offset), bytes.count-offset, Int32(MSG_NOSIGNAL))
                #else
                let count = send(fd, bytes.baseAddress!.advanced(by:offset), bytes.count-offset, 0)
                #endif
                guard count > 0 else { throw KilnError.message("IPC write failed; operation outcome unknown") }; offset += count
            }
        }
        func readBytes(_ length: Int) throws -> Data {
            var data = Data(count:length)
            try data.withUnsafeMutableBytes { bytes in
                var offset = 0
                while offset < length {
                    let count = recv(fd,bytes.baseAddress!.advanced(by:offset),length-offset,0)
                    guard count > 0 else { throw KilnError.message("IPC response lost; operation outcome unknown") }; offset += count
                }
            }
            return data
        }
        let header = try readBytes(4), size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard size <= 8_388_608 else { throw KilnError.message("IPC response too large") }
        let response = try JSONDecoder().decode(ServiceResponse.self,from:readBytes(Int(size)))
        if let error = response.error { throw KilnError.message(error) }
        guard let data = response.data else { throw KilnError.message("Empty IPC response") }; return data
    }
    func request<T: Decodable & Sendable>(_ request: ServiceRequest, as: T.Type = T.self) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { do { if let error = self.failure.text { throw KilnError.message(error) }; continuation.resume(returning:try JSONDecoder().decode(T.self,from:self.exchange(request))) } catch { continuation.resume(throwing:error) } }
        }
    }
    func fire(_ request: ServiceRequest) { queue.async { do { _ = try self.exchange(request) } catch { self.failure.text = "Session input/control failed; outcome unknown: \(error)" } } }
}
