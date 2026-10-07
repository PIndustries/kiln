import Foundation
import NIOCore
import NIOHTTP1

/// Example REST module: replace these routes with domain-specific handlers.
public final class RESTHandler: ChannelInboundHandler, RemovableChannelHandler {
    public typealias InboundIn = HTTPServerRequestPart
    public typealias OutboundOut = HTTPServerResponsePart
    private var head: HTTPRequestHead?
    public init() {}
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): self.head = head
        case .body: break
        case .end:
            guard let head else { return }
            let status: HTTPResponseStatus
            let body: String
            if head.method != .GET { status = .methodNotAllowed; body = "{\"error\":\"method not allowed\"}" }
            else {
                switch head.uri {
                case "/api/version": status = .ok; body = String(decoding: try! JSONEncoder().encode(["version": ProcessInfo.processInfo.environment["KILN_RELEASE_VERSION"] ?? "development"]), as: UTF8.self)
                case "/health": status = .ok; body = "{\"status\":\"ok\"}"
                case "/api/hello": status = .ok; body = "{\"message\":\"Hello from a Kiln REST module\"}"
                default: status = .notFound; body = "{\"error\":\"not found\"}"
                }
            }
            var headers = HTTPHeaders(); headers.add(name: "content-type", value: "application/json")
            headers.add(name: "content-length", value: String(body.utf8.count))
            headers.add(name: "connection", value: "close")
            context.write(wrapOutboundOut(.head(.init(version: head.version, status: status, headers: headers))), promise: nil)
            var buffer = context.channel.allocator.buffer(capacity: body.utf8.count); buffer.writeString(body)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in channel.close(promise: nil) }
            self.head = nil
        }
    }
    public func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
