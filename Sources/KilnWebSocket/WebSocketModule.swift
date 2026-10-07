import NIOCore
import NIOWebSocket

/// An independently deployable example uses this module for bounded echo messages.
public final class EchoHandler: ChannelInboundHandler {
    public typealias InboundIn = WebSocketFrame
    public typealias OutboundOut = WebSocketFrame
    public init() {}
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard frame.fin else { context.close(promise: nil); return }
        let payload = frame.unmaskedData
        switch frame.opcode {
        case .text, .binary:
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: frame.opcode, data: payload)), promise: nil)
        case .ping:
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .pong, data: payload)), promise: nil)
        case .connectionClose:
            let channel = context.channel
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .connectionClose, data: payload))).whenComplete { _ in channel.close(promise: nil) }
        case .pong: break
        default: context.close(promise: nil)
        }
    }
    public func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
