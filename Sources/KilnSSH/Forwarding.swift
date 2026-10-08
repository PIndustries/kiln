import NIOCore
import NIOPosix
import NIOSSH
import KilnCommands

private struct ForwardDenied: Error {}
private final class TunnelCodec: ChannelDuplexHandler {
    let commands: KilnCommands
    var permissionTimer: RepeatedTask?
    init(commands: KilnCommands) { self.commands = commands }
    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel, commands = commands
        permissionTimer = context.eventLoop.scheduleRepeatedTask(initialDelay: .seconds(1), delay: .seconds(1)) { task in
            if (try? commands.authorizeAdmin()) == nil { task.cancel(); channel.close(promise: nil) }
        }
    }
    func handlerRemoved(context: ChannelHandlerContext) { permissionTimer?.cancel() }

    typealias InboundIn=SSHChannelData
    typealias InboundOut=ByteBuffer
    typealias OutboundIn=ByteBuffer
    typealias OutboundOut=SSHChannelData
    func channelRead(context:ChannelHandlerContext,data:NIOAny){
        let packet=unwrapInboundIn(data)
        guard packet.type == .channel,case .byteBuffer(let bytes)=packet.data else {context.close(promise:nil);return}
        context.fireChannelRead(wrapInboundOut(bytes))
    }
    func write(context:ChannelHandlerContext,data:NIOAny,promise:EventLoopPromise<Void>?){
        context.write(wrapOutboundOut(SSHChannelData(type:.channel,data:.byteBuffer(unwrapOutboundIn(data)))),promise:promise)
    }
    func userInboundEventTriggered(context:ChannelHandlerContext,event:Any){
        if event is ServerShutdown {context.close(promise:nil)}
        else {context.fireUserInboundEventTriggered(event)}
    }
}

func openTunnel(channel:Channel,host:String,port:Int,commands:KilnCommands)->EventLoopFuture<Void>{
    let permission=channel.eventLoop.makePromise(of:Bool.self)
    Task {permission.succeed(await commands.allowForward(host:host,port:port))}
    return permission.futureResult.flatMap{allowed in
        guard allowed else{return channel.eventLoop.makeFailedFuture(ForwardDenied())}
        let pair=TunnelRelay.matchedPair()
        let local=NIOLoopBound(pair.0,eventLoop:channel.eventLoop)
        let remote=NIOLoopBound(pair.1,eventLoop:channel.eventLoop)
        return channel.setOption(ChannelOptions.allowRemoteHalfClosure,value:true).flatMap {
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandlers(TunnelCodec(commands:commands),local.value)
            }
        }.flatMap {
            ClientBootstrap(group:channel.eventLoop)
                .connectTimeout(.seconds(5))
                .channelOption(ChannelOptions.allowRemoteHalfClosure,value:true)
                .channelInitializer{outbound in
                    outbound.eventLoop.makeCompletedFuture{try outbound.pipeline.syncOperations.addHandler(remote.value)}
                }.connect(host:host,port:port)
                .map{_ in ()}
        }.flatMapError { error in channel.close(promise:nil);return channel.eventLoop.makeFailedFuture(error) }
    }
}
