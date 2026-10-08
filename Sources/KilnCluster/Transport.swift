import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import KilnKit

private final class AuthenticationState { var peer: String?; var childOpened = false; var attempts = 0 }
private final class PeerAuthentication: NIOSSHServerUserAuthenticationDelegate {
    let cluster: KilnCluster
    let state: NIOLoopBound<AuthenticationState>
    init(cluster: KilnCluster, state: NIOLoopBound<AuthenticationState>) { self.cluster = cluster; self.state = state }
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .publicKey }
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        state.value.attempts += 1
        guard state.value.attempts <= 4, request.username == "kiln-node", case .publicKey(let offer) = request.request else { responsePromise.succeed(.failure); return }
        let publicKey = String(openSSHPublicKey: offer.publicKey), cluster = cluster, state = state
        let loop = responsePromise.futureResult.eventLoop
        Task {
            let peer = await cluster.authorized(publicKey)
            loop.execute { state.value.peer = peer; responsePromise.succeed(peer == nil ? .failure : .success) }
        }
    }
}
private final class PeerRequestHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    let cluster: KilnCluster
    let state: NIOLoopBound<AuthenticationState>
    var started = false
    init(cluster: KilnCluster, state: NIOLoopBound<AuthenticationState>) { self.cluster = cluster; self.state = state }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { context.close(promise: nil) }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        guard let request = event as? SSHChannelRequestEvent.ExecRequest else {
            context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil); context.close(promise: nil); return
        }
        let channel = context.channel
        guard !started, let peer = state.value.peer, request.command.utf8.count <= 4096,
              request.command.hasPrefix("kiln-peer-v1:"), let bytes = Data(base64Encoded: String(request.command.dropFirst(13))),
              let operation = try? JSONDecoder().decode(ClusterRequest.self, from: bytes) else {
            channel.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil); channel.close(promise: nil); return
        }
        started = true
        if request.wantReply { channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
        let cluster = cluster
        // Accepted mutations keep their durable receipt even if the client leaves.
        Task {
            let result: ClusterResponse
            do { result = try await cluster.receive(operation, from: peer) }
            catch { result = ClusterResponse(id: operation.id, state: "rejected", output: String(describing: error)) }
            let encoded = (try? JSONEncoder().encode(result)) ?? Data()
            let data = encoded.count <= 65536 ? encoded : ((try? JSONEncoder().encode(ClusterResponse(id: operation.id, state: "response-too-large", output: "Response exceeded 64 KiB. Inspect this node locally; an accepted mutation may already have completed. Do not blindly repeat it."))) ?? Data())
            channel.eventLoop.execute {
                var buffer = channel.allocator.buffer(capacity: data.count); buffer.writeBytes(data)
                channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))).whenComplete { _ in
                    channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: 0), promise: nil)
                    channel.close(promise: nil)
                }
            }
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
private final class PeerErrors: ChannelInboundHandler, Sendable {
    typealias InboundIn = Any
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
private final class PeerChannels: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: Channel] = [:]
    func add(_ channel: Channel) -> Bool { lock.withLock { guard channels.count < 64 else { return false }; channels[ObjectIdentifier(channel)] = channel; return true } }
    func remove(_ channel: Channel) { _ = lock.withLock { channels.removeValue(forKey: ObjectIdentifier(channel)) } }
    func all() -> [Channel] { lock.withLock { Array(channels.values) } }
}
final class ClusterListener: Sendable {
    let group: MultiThreadedEventLoopGroup
    let channel: Channel
    private let channels: PeerChannels
    private init(group: MultiThreadedEventLoopGroup, channel: Channel, channels: PeerChannels) { self.group = group; self.channel = channel; self.channels = channels }
    static func start(host: String, port: Int, key: NIOSSHPrivateKey, cluster: KilnCluster) async throws -> ClusterListener {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2), channels = PeerChannels()
        do {
            let server = try await ServerBootstrap(group: group).serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        guard channels.add(channel) else { throw KilnError.message("Peer connection limit reached") }
                        channel.closeFuture.whenComplete { _ in channels.remove(channel) }
                        // Bounds idle handshakes and authenticated-but-idle connections.
                        let timeout = channel.eventLoop.scheduleTask(in: .seconds(20)) { channel.close(promise: nil) }
                        channel.closeFuture.whenComplete { _ in timeout.cancel() }
                        let state = NIOLoopBound(AuthenticationState(), eventLoop: channel.eventLoop)
                        try channel.pipeline.syncOperations.addHandlers([
                            NIOSSHHandler(role: .server(.init(hostKeys: [key], userAuthDelegate: PeerAuthentication(cluster: cluster, state: state))), allocator: channel.allocator, inboundChildChannelInitializer: { child, type in
                                guard type == .session, !state.value.childOpened else { return child.eventLoop.makeFailedFuture(KilnError.message("Only typed peer sessions are supported")) }
                                state.value.childOpened = true
                                return child.eventLoop.makeCompletedFuture { try child.pipeline.syncOperations.addHandler(PeerRequestHandler(cluster: cluster, state: state)) }
                            }), PeerErrors()])
                    }
                }.bind(host: host, port: port).get()
            return ClusterListener(group: group, channel: server, channels: channels)
        } catch { try? await group.shutdownGracefully(); throw error }
    }
    func stop() async { try? await channel.close().get(); for child in channels.all() { try? await child.close().get() }; try? await group.shutdownGracefully() }
}

private final class ClientAuthentication: NIOSSHClientUserAuthenticationDelegate {
    let key: NIOSSHPrivateKey?
    var offered = false
    init(_ key: NIOSSHPrivateKey?) { self.key = key }
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !offered, let key, availableMethods.contains(.publicKey) else { nextChallengePromise.succeed(nil); return }
        offered = true
        nextChallengePromise.succeed(.init(username: "kiln-node", serviceName: "ssh-connection", offer: .privateKey(.init(privateKey: key))))
    }
}
private final class Completion {
    let promise: EventLoopPromise<Data>
    var finished = false, output = Data()
    var exitStatus: Int?
    init(_ promise: EventLoopPromise<Data>) { self.promise = promise }
    func succeed(_ data: Data) { guard !finished else { return }; finished = true; promise.succeed(data) }
    func fail(_ error: Error) { guard !finished else { return }; finished = true; promise.fail(error) }
    func end() { if exitStatus == 0 { succeed(output) } else { fail(KilnError.message("Peer connection closed without a successful response")) } }
}
private final class ServerAuthentication: NIOSSHClientServerAuthenticationDelegate {
    let pin: NIOSSHPublicKey?
    let completion: Completion
    init(pin: NIOSSHPublicKey?, completion: Completion) { self.pin = pin; self.completion = completion }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        if let pin {
            if pin == hostKey { validationCompletePromise.succeed(()) }
            else { validationCompletePromise.fail(KilnError.message("Peer host key differs from the explicitly adopted fingerprint")) }
        } else {
            completion.succeed(Data(String(openSSHPublicKey: hostKey).utf8))
            validationCompletePromise.fail(KilnError.message("Discovery complete; no authentication attempted"))
        }
    }
}
private final class ClientErrors: ChannelInboundHandler {
    typealias InboundIn = Any
    let completion: Completion
    init(_ completion: Completion) { self.completion = completion }
    func errorCaught(context: ChannelHandlerContext, error: Error) { completion.fail(error); context.close(promise: nil) }
    func channelInactive(context: ChannelHandlerContext) { completion.end(); context.fireChannelInactive() }
}
private final class ClientRequest: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    let command: String
    let completion: Completion
    init(command: String, completion: Completion) { self.command = command; self.completion = completion }
    func handlerAdded(context: ChannelHandlerContext) { let channel = context.channel; channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in channel.close(promise: nil) } }
    func channelActive(context: ChannelHandlerContext) { context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true), promise: nil) }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .byteBuffer(let buffer) = unwrapInboundIn(data).data else { return }
        guard completion.output.count + buffer.readableBytes <= 65536 else { completion.fail(KilnError.message("Peer response exceeded 64 KiB")); context.close(promise: nil); return }
        completion.output.append(contentsOf: buffer.readableBytesView)
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let status = event as? SSHChannelRequestEvent.ExitStatus { completion.exitStatus = status.exitStatus }
        else if event is ChannelFailureEvent { completion.fail(KilnError.message("Peer rejected request")); context.close(promise: nil) }
        else { context.fireUserInboundEventTriggered(event) }
    }
    func channelInactive(context: ChannelHandlerContext) { completion.end(); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { completion.fail(error); context.close(promise: nil) }
}
enum ClusterTransport {
    static func scan(host: String, port: Int) async throws -> String { String(decoding: try await connect(host: host, port: port, key: nil, pin: nil, request: nil), as: UTF8.self) }
    static func execute(peer: ClusterPeer, key: NIOSSHPrivateKey, request: ClusterRequest) async throws -> ClusterResponse {
        let data = try await connect(host: peer.host, port: peer.port, key: key, pin: NIOSSHPublicKey(openSSHPublicKey: peer.publicKey), request: request)
        let response = try JSONDecoder().decode(ClusterResponse.self, from: data)
        guard response.id == request.id else { throw KilnError.message("Peer response ID mismatch") }
        return response
    }
    private static func connect(host: String, port: Int, key: NIOSSHPrivateKey?, pin: NIOSSHPublicKey?, request: ClusterRequest?) async throws -> Data {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1), loop = group.next()
        let promise = loop.makePromise(of: Data.self)
        let completion = try await loop.submit { NIOLoopBound(Completion(promise), eventLoop: loop) }.get()
        let timeout = loop.scheduleTask(in: .seconds(request == nil ? 3 : request?.operation == .status ? 5 : 15)) { completion.value.fail(KilnError.message("Peer request timed out; inspect a mutation receipt before retrying with a new ID")) }
        var connection: Channel?
        do {
            let channel = try await ClientBootstrap(group: loop).connectTimeout(.seconds(3)).channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        NIOSSHHandler(role: .client(.init(userAuthDelegate: ClientAuthentication(key), serverAuthDelegate: ServerAuthentication(pin: pin, completion: completion.value))), allocator: channel.allocator, inboundChildChannelInitializer: nil), ClientErrors(completion.value)])
                }
            }.connect(host: host, port: port).get()
            connection = channel
            if let request {
                let command = "kiln-peer-v1:" + (try JSONEncoder().encode(request)).base64EncodedString()
                channel.eventLoop.execute {
                    do {
                        let handler = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                        let child = loop.makePromise(of: Channel.self)
                        child.futureResult.whenFailure { completion.value.fail($0) }
                        handler.createChannel(child) { child, type in
                            guard type == .session else { return child.eventLoop.makeFailedFuture(KilnError.message("Unexpected peer channel")) }
                            return child.eventLoop.makeCompletedFuture { try child.pipeline.syncOperations.addHandler(ClientRequest(command: command, completion: completion.value)) }
                        }
                    } catch { completion.value.fail(error) }
                }
            }
            let result = try await promise.futureResult.get()
            timeout.cancel(); try? await channel.close().get(); try? await group.shutdownGracefully(); return result
        } catch {
            timeout.cancel(); if let connection { try? await connection.close().get() }
            _ = try? await loop.submit { completion.value.fail(error) }.get()
            try? await group.shutdownGracefully(); throw error
        }
    }
}
