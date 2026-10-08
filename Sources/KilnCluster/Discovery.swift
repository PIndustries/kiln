import Foundation
import NIOCore
import NIOPosix
import KilnKit

private struct Advertisement: Codable, Sendable {
    let protocolVersion: Int
    let publicKey: String
    let port: Int
}
private final class DiscoveryHandler: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    let cluster: KilnCluster
    var window = Date(), received = 0
    init(_ cluster: KilnCluster) { self.cluster = cluster }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let packet = unwrapInboundIn(data)
        if Date().timeIntervalSince(window) >= 1 { window = Date(); received = 0 }
        guard received < 8 else { return }
        received += 1
        guard packet.data.readableBytes <= 512,
              let host = packet.remoteAddress.ipAddress,
              let advertisement = try? JSONDecoder().decode(Advertisement.self, from: Data(packet.data.readableBytesView)),
              advertisement.protocolVersion == 1 else { return }
        let cluster = cluster
        Task { _ = try? await cluster.candidate(host: host, port: advertisement.port, publicKey: advertisement.publicKey) }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { /* Malformed discovery traffic never activates a peer. */ }
}
final class ClusterDiscovery: Sendable {
    let channel: Channel
    let group: MultiThreadedEventLoopGroup
    let timer: RepeatedTask
    init(channel: Channel, group: MultiThreadedEventLoopGroup, timer: RepeatedTask) { self.channel = channel; self.group = group; self.timer = timer }
    static func start(cluster: KilnCluster, publicKey: String, peerPort: Int, discoveryPort: Int) async throws -> ClusterDiscovery {
        guard (1...65535).contains(discoveryPort) else { throw KilnError.message("Invalid discovery port") }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var opened: Channel?
        do {
            let destination = try SocketAddress(ipAddress: "239.255.75.76", port: discoveryPort)
            let channel = try await DatagramBootstrap(group: group)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelOption(ChannelOptions.socketOption(.so_reuseport), value: 1)
                .channelInitializer { channel in channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(DiscoveryHandler(cluster)) } }
                .bind(host: "0.0.0.0", port: discoveryPort).get()
            opened = channel
            guard let multicast = channel as? MulticastChannel, let options = channel as? SocketOptionProvider else { throw KilnError.message("Multicast is unavailable; use explicit node discover") }
            try await options.setIPMulticastTTL(1).get()
            try await multicast.joinGroup(destination).get()
            let advertisement = try JSONEncoder().encode(Advertisement(protocolVersion: 1, publicKey: publicKey, port: peerPort))
            let timer = channel.eventLoop.scheduleRepeatedTask(initialDelay: .milliseconds(10), delay: .seconds(10)) { _ in
                var bytes = channel.allocator.buffer(capacity: advertisement.count); bytes.writeBytes(advertisement)
                channel.writeAndFlush(AddressedEnvelope(remoteAddress: destination, data: bytes), promise: nil)
            }
            return ClusterDiscovery(channel: channel, group: group, timer: timer)
        } catch { if let opened { try? await opened.close().get() }; try? await group.shutdownGracefully(); throw error }
    }
    func stop() async { timer.cancel(); try? await channel.close().get(); try? await group.shutdownGracefully() }
}
