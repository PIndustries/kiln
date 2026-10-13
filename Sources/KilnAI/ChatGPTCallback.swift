import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

/// Loopback-only HTTP callback. No query values are rendered or logged.
final class ChatGPTCallbackListener: @unchecked Sendable {
    let port: Int
    private let channel: Channel
    private let group: MultiThreadedEventLoopGroup
    private init(channel: Channel, group: MultiThreadedEventLoopGroup, port: Int) { self.channel = channel; self.group = group; self.port = port }
    static func start(port: Int, receive: @escaping @Sendable (String) async -> Void) async throws -> ChatGPTCallbackListener {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let channel = try await ServerBootstrap(group: group).serverChannelOption(ChannelOptions.backlog, value: 8)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                        channel.pipeline.addHandlers(IdleStateHandler(readTimeout: .seconds(15)), ChatGPTCallbackHandler(receive: receive))
                    }
                }.bind(host: "127.0.0.1", port: port).get()
            guard let boundPort = channel.localAddress?.port else { throw AIError.message("Cannot determine ChatGPT callback port") }
            return ChatGPTCallbackListener(channel: channel, group: group, port: boundPort)
        } catch { try? await group.shutdownGracefully(); throw AIError.message("Cannot start ChatGPT loopback callback") }
    }
    func close() async { try? await channel.close().get(); try? await group.shutdownGracefully() }
}
private final class ChatGPTCallbackHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let receive: @Sendable (String) async -> Void
    private var target: String?
    private var responded = false
    init(receive: @escaping @Sendable (String) async -> Void) { self.receive = receive }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !responded else { return }
        switch unwrapInboundIn(data) {
        case .head(let head):
            guard head.method == .GET, head.uri.hasPrefix("/auth/callback?"), head.uri.utf8.count <= 16384 else {
                respond(context, status: .badRequest); return
            }
            target = head.uri
        case .body: respond(context, status: .badRequest)
        case .end:
            guard let target else { respond(context, status: .badRequest); return }
            let receive = self.receive
            respond(context, status: .ok)
            Task { await receive(target) }
        }
    }
    private func respond(_ context: ChannelHandlerContext, status: HTTPResponseStatus) {
        responded = true
        let text = status == .ok ? "Authorization callback received. Return to Kiln to check sign-in status. You may close this tab." : "Invalid authorization callback. Return to Kiln."
        var buffer = context.channel.allocator.buffer(capacity: text.utf8.count); buffer.writeString(text)
        let headers = HTTPHeaders([("Content-Type", "text/plain; charset=utf-8"), ("Cache-Control", "no-store"), ("Referrer-Policy", "no-referrer"), ("Content-Length", String(buffer.readableBytes)), ("Connection", "close")])
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent { context.close(promise: nil) }
        else { context.fireUserInboundEventTriggered(event) }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
