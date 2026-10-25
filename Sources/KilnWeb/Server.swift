import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket

/// A web worker, independent of the Kiln supervisor. TLS termination and public
/// routing are separate concerns; the initial listener binds only to loopback.
public final class WebServer {
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    public var port: Int { channel.localAddress?.port ?? 0 }
    public init(application: WebApplication, host: String = "127.0.0.1", port: Int) throws {
        guard ["127.0.0.1", "::1"].contains(host), (0...65535).contains(port) else { throw WebError(400) }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        self.group = group
        do {
            channel = try ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let handler = WebHTTPHandler(application)
                        let bound = NIOLoopBound(handler, eventLoop: channel.eventLoop)
                        let upgrade = NIOWebSocketServerUpgrader(maxFrameSize: 16384, shouldUpgrade: { channel, head in
                            channel.eventLoop.makeFutureWithTask {
                                guard head.method == .GET, let headers = try? requestHeaders(head.headers),
                                      (try? await application.upgradeRequest(uri: head.uri, headers: headers)) != nil else { return nil }
                                return HTTPHeaders()
                            }
                        }, upgradePipelineHandler: { channel, head in
                            channel.eventLoop.makeFutureWithTask { try await application.claim(uri: head.uri, headers: requestHeaders(head.headers)) }.flatMap { mount in
                                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(WebLiveHandler(application: application, mount: mount)) }
                            }
                        })
                        let configuration: NIOHTTPServerUpgradeConfiguration = (upgraders: [upgrade], completionHandler: { context in
                            context.pipeline.syncOperations.removeHandler(bound.value, promise: nil)
                        })
                        try channel.pipeline.syncOperations.configureHTTPServerPipeline(withServerUpgrade: configuration)
                        try channel.pipeline.syncOperations.addHandler(handler)
                    }
                }.bind(host: host, port: port).wait()
        } catch { try? group.syncShutdownGracefully(); throw error }
    }
    public func wait() throws { try channel.closeFuture.wait() }
    public func shutdown() throws { try channel.close().wait(); try group.syncShutdownGracefully() }
}
private func requestHeaders(_ headers: HTTPHeaders) throws -> [String: String] {
    var result: [String: String] = [:]
    var bytes = 0
    for (key, value) in headers {
        let name = key.lowercased(); bytes += key.utf8.count + value.utf8.count
        guard result[name] == nil, bytes <= 16384, result.count < 64 else { throw WebError(400) }
        result[name] = value
    }
    return result
}
private final class WebHTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    let application: WebApplication
    var head: HTTPRequestHead?
    var body = Data()
    var processing = false
    var task: Task<Void, Never>?
    var deadline: Scheduled<Void>?
    init(_ application: WebApplication) { self.application = application }
    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        deadline = channel.eventLoop.scheduleTask(in: .seconds(10)) { channel.close(promise: nil) }
    }
    func handlerRemoved(context: ChannelHandlerContext) { deadline?.cancel(); task?.cancel() }
    func channelInactive(context: ChannelHandlerContext) { deadline?.cancel(); task?.cancel(); context.fireChannelInactive() }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let request):
            guard head == nil, !processing else { context.close(promise: nil); return }
            head = request
        case .body(var buffer):
            guard head != nil, !processing, body.count + buffer.readableBytes <= 16384 else {
                reply(.init(status: 413, body: Data()), context: context); return
            }
            if let bytes = buffer.readBytes(length: buffer.readableBytes) { body.append(contentsOf: bytes) }
        case .end:
            guard let head, !processing else { context.close(promise: nil); return }
            processing = true
            let bytes = body; body = Data()
            let bound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
            let loop = context.eventLoop
            let application = application
            task = Task {
                let result: WebResponse
                do { result = await application.respond(method: head.method.rawValue, uri: head.uri, headers: try requestHeaders(head.headers), body: bytes) }
                catch { result = .init(status: 400, body: Data()) }
                loop.execute {
                    guard bound.value.1.channel.isActive else { return }
                    bound.value.0.reply(result, context: bound.value.1)
                }
            }
        }
    }
    func reply(_ result: WebResponse, context: ChannelHandlerContext) {
        deadline?.cancel()
        var result = result
        let invalid = result.headers.contains { name, value in
            !name.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) || value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
        }
        if result.body.count > 1_048_576 || invalid || result.contentType.unicodeScalars.contains(where: { $0.value < 32 || $0.value >= 127 }) || !(200...599).contains(result.status) { result = .init(status: 500, body: Data()) }
        var headers = HTTPHeaders()
        for (name, value) in result.headers where !["content-length", "connection", "transfer-encoding", "content-security-policy", "content-type"].contains(name.lowercased()) { headers.add(name: name, value: value) }
        headers.replaceOrAdd(name: "content-type", value: result.contentType)
        headers.replaceOrAdd(name: "content-length", value: String(result.body.count))
        headers.replaceOrAdd(name: "connection", value: "close")
        headers.replaceOrAdd(name: "cache-control", value: "no-store")
        headers.replaceOrAdd(name: "x-content-type-options", value: "nosniff")
        headers.replaceOrAdd(name: "referrer-policy", value: "no-referrer")
        let socketOrigin = application.origin.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://")
        headers.replaceOrAdd(name: "content-security-policy", value: "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self' \(socketOrigin); img-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'")
        context.write(wrapOutboundOut(.head(.init(version: head?.version ?? .http1_1, status: .init(statusCode: result.status), headers: headers))), promise: nil)
        if head?.method != .HEAD {
            var buffer = context.channel.allocator.buffer(capacity: result.body.count); buffer.writeBytes(result.body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        let channel = context.channel
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in channel.close(promise: nil) }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
private enum LiveInput: Sendable { case refresh, heartbeat, event(Data) }
private final class WebLiveHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame
    let application: WebApplication
    let mount: LiveMount
    var heartbeat: RepeatedTask?
    var continuation: AsyncStream<LiveInput>.Continuation?
    var task: Task<Void, Never>?
    init(application: WebApplication, mount: LiveMount) { self.application = application; self.mount = mount }
    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel, application = application, mount = mount
        let (stream, continuation) = AsyncStream<LiveInput>.makeStream(bufferingPolicy: .bufferingOldest(32))
        self.continuation = continuation
        heartbeat = channel.eventLoop.scheduleRepeatedTask(initialDelay: .seconds(20), delay: .seconds(20)) { _ in
            if case .dropped = continuation.yield(.heartbeat) { continuation.finish(); channel.close(promise: nil) }
        }
        task = Task {
            await application.hub.join(mount.lease, topics: mount.topics) {
                if case .dropped = continuation.yield(.refresh) { continuation.finish(); channel.close(promise: nil) }
            }
            continuation.yield(.refresh)
            do {
                for await input in stream {
                    try Task.checkCancellation()
                    let event: Data?
                    switch input {
                    case .refresh: event = nil
                    case .event(let bytes): event = bytes
                    case .heartbeat:
                        if try await application.router.authorize(mount.request) != nil { throw WebError(403) }
                        _ = try await application.state.validate(mount)
                        guard channel.isActive, channel.isWritable else { throw WebError(503) }
                        try await channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .ping, data: channel.allocator.buffer(capacity: 0))).get()
                        continue
                    }
                    let data = try await application.snapshot(mount, event: event)
                    guard data.count <= 1_048_576, channel.isActive, channel.isWritable else { break }
                    var buffer = channel.allocator.buffer(capacity: data.count); buffer.writeBytes(data)
                    try await channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, data: buffer)).get()
                }
            } catch { /* Fail closed; application errors are never serialized. */ }
            continuation.finish()
            await application.hub.leave(mount.lease)
            await application.state.disconnect(mount)
            channel.close(promise: nil)
        }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard frame.fin, frame.maskKey != nil, !frame.rsv1, !frame.rsv2, !frame.rsv3 else { context.close(promise: nil); return }
        var payload = frame.unmaskedData
        switch frame.opcode {
        case .text:
            guard payload.readableBytes <= 16384, let bytes = payload.readBytes(length: payload.readableBytes) else { context.close(promise: nil); return }
            if case .dropped = continuation?.yield(.event(Data(bytes))) { context.close(promise: nil) }
        case .ping:
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: payload)), promise: nil)
        case .pong: break
        case .connectionClose:
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .connectionClose, data: payload))).whenComplete { _ in channel.close(promise: nil) }
        default: context.close(promise: nil)
        }
    }
    func channelInactive(context: ChannelHandlerContext) { heartbeat?.cancel(); continuation?.finish(); task?.cancel(); context.fireChannelInactive() }
    func handlerRemoved(context: ChannelHandlerContext) { heartbeat?.cancel(); continuation?.finish(); task?.cancel() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
