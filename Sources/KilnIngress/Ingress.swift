import Foundation
import NIOCore
import NIOPosix
import NIOConcurrencyHelpers

/// Connection-level switching preserves WebSockets and in-flight HTTP streams.
/// Only loopback is exposed; use an authenticated SSH tunnel or a TLS edge for remote access.
public final class KilnIngress: @unchecked Sendable {
    private struct State {
        var target: Int?
        var clients: [UUID: (Int, Channel)] = [:]
    }
    private let state = NIOLockedValueBox(State())
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var listener: Channel?
    public init() {}

    public func start(port: Int) async throws {
        listener = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { [self] channel in
                let id = UUID()
                let target = state.withLockedValue { state -> Int? in
                    guard let target = state.target else { return nil }
                    state.clients[id] = (target, channel)
                    return target
                }
                guard let target else { return channel.close() }
                channel.closeFuture.whenComplete { [self] _ in
                    state.withLockedValue { _ = $0.clients.removeValue(forKey: id) }
                }
                let pair = TunnelRelay.matchedPair()
                let local = NIOLoopBound(pair.0, eventLoop: channel.eventLoop)
                let remote = NIOLoopBound(pair.1, eventLoop: channel.eventLoop)
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(local.value)
                }.flatMap {
                    ClientBootstrap(group: channel.eventLoop)
                        .connectTimeout(.seconds(3))
                        .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                        .channelInitializer { outbound in
                            outbound.eventLoop.makeCompletedFuture {
                                try outbound.pipeline.syncOperations.addHandler(remote.value)
                            }
                        }.connect(host: "127.0.0.1", port: target).map { _ in () }
                }.flatMapError { error in
                    channel.close(promise: nil)
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }.bind(host: "127.0.0.1", port: port).get()
    }
    public func switchTo(_ port: Int?) { state.withLockedValue { $0.target = port } }
    public func drain(_ port: Int, seconds: Int = 30) async {
        for _ in 0..<(seconds * 10) {
            if state.withLockedValue({ !$0.clients.values.contains { $0.0 == port } }) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let channels = state.withLockedValue { $0.clients.values.filter { $0.0 == port }.map { $0.1 } }
        for channel in channels { try? await channel.close().get() }
    }
    public func stop() async {
        switchTo(nil)
        try? await listener?.close().get()
        let channels = state.withLockedValue { $0.clients.values.map { $0.1 } }
        for channel in channels { try? await channel.close().get() }
        try? await group.shutdownGracefully()
    }
}
