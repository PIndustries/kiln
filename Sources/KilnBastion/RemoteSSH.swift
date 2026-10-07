import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import KilnKit

public struct RemoteResult: Codable, Sendable { public let output:String; public let status:Int }
final class Authentication: NIOSSHClientUserAuthenticationDelegate {
    let user:String;let key:NIOSSHPrivateKey;var offered=false
    init(user:String,key:NIOSSHPrivateKey){self.user=user;self.key=key}
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !offered,availableMethods.contains(.publicKey) else {nextChallengePromise.succeed(nil);return}
        offered=true
        nextChallengePromise.succeed(.init(username:user,serviceName:"ssh-connection",offer:.privateKey(.init(privateKey:key))))
    }
}
final class HostPin: NIOSSHClientServerAuthenticationDelegate {
    let key:NIOSSHPublicKey
    init(_ key:NIOSSHPublicKey){self.key=key}
    func validateHostKey(hostKey:NIOSSHPublicKey,validationCompletePromise:EventLoopPromise<Void>){
        if hostKey == key {validationCompletePromise.succeed(())}
        else {validationCompletePromise.fail(KilnError.message("Destination host key mismatch; connection refused"))}
    }
}
private final class Completion {
    let promise:EventLoopPromise<RemoteResult>;var finished=false;var data=[UInt8]();var status:Int?
    init(_ promise:EventLoopPromise<RemoteResult>){self.promise=promise}
    func fail(_ error:Error){guard !finished else{return};finished=true;promise.fail(error)}
    func finish(){guard !finished else{return};guard let status else {fail(KilnError.message("Remote session closed without an exit status"));return};finished=true;promise.succeed(RemoteResult(output:String(decoding:data,as:UTF8.self),status:status))}
}
private final class ParentErrors: ChannelInboundHandler {
    typealias InboundIn=Any
    let completion:Completion
    init(_ completion:Completion){self.completion=completion}
    func errorCaught(context:ChannelHandlerContext,error:Error){completion.fail(error);context.close(promise:nil)}
    func channelInactive(context:ChannelHandlerContext){completion.finish();context.fireChannelInactive()}
}
private final class Exec: ChannelInboundHandler {
    typealias InboundIn=SSHChannelData
    let command:String;let completion:Completion
    init(command:String,completion:Completion){self.command=command;self.completion=completion}
    func handlerAdded(context:ChannelHandlerContext){
        let channel=context.channel
        channel.setOption(ChannelOptions.allowRemoteHalfClosure,value:true).whenFailure{_ in channel.close(promise:nil)}
    }
    func channelActive(context:ChannelHandlerContext){
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command:command,wantReply:true),promise:nil)
    }
    func userInboundEventTriggered(context:ChannelHandlerContext,event:Any){
        if let exit=event as? SSHChannelRequestEvent.ExitStatus {completion.status=exit.exitStatus}
        else if event is ChannelFailureEvent {completion.fail(KilnError.message("Destination rejected the command"));context.close(promise:nil)}
        else {context.fireUserInboundEventTriggered(event)}
    }
    func channelRead(context:ChannelHandlerContext,data:NIOAny){
        guard case .byteBuffer(let bytes)=unwrapInboundIn(data).data else {return}
        guard completion.data.count+bytes.readableBytes <= 65536 else {
            completion.fail(KilnError.message("Remote output exceeded 64 KiB; session closed"));context.close(promise:nil);return
        }
        completion.data.append(contentsOf:bytes.readableBytesView)
    }
    func channelInactive(context:ChannelHandlerContext){completion.finish();context.fireChannelInactive()}
    func errorCaught(context:ChannelHandlerContext,error:Error){completion.fail(error);context.close(promise:nil)}
}

enum RemoteSSH {
    static func execute(server:ServerProfile,key:NIOSSHPrivateKey,hostKey:NIOSSHPublicKey,command:String) async throws -> RemoteResult {
        guard !command.isEmpty, command.utf8.count <= 4096 else {throw KilnError.message("Command must be 1–4096 bytes")}
        let group=MultiThreadedEventLoopGroup(numberOfThreads:1)
        let loop=group.next()
        let promise=loop.makePromise(of:RemoteResult.self)
        let completion=try await loop.submit { NIOLoopBound(Completion(promise),eventLoop:loop) }.get()
        let timeout=loop.scheduleTask(in:.seconds(15)){completion.value.fail(KilnError.message("Remote command timed out after 15 seconds"))}
        var channel:Channel?
        do {
            let connected=try await ClientBootstrap(group:loop).connectTimeout(.seconds(5)).channelInitializer{channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        NIOSSHHandler(role:.client(.init(userAuthDelegate:Authentication(user:server.user,key:key),serverAuthDelegate:HostPin(hostKey))),allocator:channel.allocator,inboundChildChannelInitializer:nil),
                        ParentErrors(completion.value)])
                }
            }.connect(host:server.host,port:server.port).get()
            channel=connected
            connected.eventLoop.execute {
                do {
                    let handler=try connected.pipeline.syncOperations.handler(type:NIOSSHHandler.self)
                    let child=connected.eventLoop.makePromise(of:Channel.self)
                    child.futureResult.whenFailure{completion.value.fail($0)}
                    handler.createChannel(child){channel,type in
                        guard type == .session else {return channel.eventLoop.makeFailedFuture(KilnError.message("Unexpected channel type"))}
                        return channel.eventLoop.makeCompletedFuture{try channel.pipeline.syncOperations.addHandler(Exec(command:command,completion:completion.value))}
                    }
                }catch{completion.value.fail(error)}
            }
            let result=try await promise.futureResult.get()
            timeout.cancel();try? await connected.close().get();try? await group.shutdownGracefully();return result
        }catch{
            timeout.cancel();if let channel{try? await channel.close().get()}
            // Always resolve the promise, including failures before a channel exists.
            await loop.submit{completion.value.fail(error)}.getIgnoringFailure()
            try? await group.shutdownGracefully();throw error
        }
    }
}
private extension EventLoopFuture where Value == Void {
    func getIgnoringFailure() async { _ = try? await get() }
}
