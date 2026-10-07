import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import KilnHTTP
import KilnWebSocket

@main
struct Backend {
    static func main() throws {
        let args = CommandLine.arguments
        let websocket = args.contains("--websocket")
        let port = args.firstIndex(of: "--port").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? (websocket ? 18081 : 18080)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try? group.syncShutdownGracefully() }
        let channel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let rest = RESTHandler()
                    if websocket {
                        let bound = NIOLoopBound(rest, eventLoop: channel.eventLoop)
                        let upgrade = NIOWebSocketServerUpgrader(maxFrameSize: 65536, shouldUpgrade: { channel, head in
                            channel.eventLoop.makeSucceededFuture(head.uri == "/ws" ? HTTPHeaders() : nil)
                        }, upgradePipelineHandler: { channel, _ in
                            channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(EchoHandler()) }
                        })
                        let configuration: NIOHTTPServerUpgradeConfiguration = (upgraders: [upgrade], completionHandler: { context in
                            context.pipeline.syncOperations.removeHandler(bound.value, promise: nil)
                        })
                        try channel.pipeline.syncOperations.configureHTTPServerPipeline(withServerUpgrade: configuration)
                    } else {
                        try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    }
                    try channel.pipeline.syncOperations.addHandler(rest)
                }
            }.bind(host: "127.0.0.1", port: port).wait()
        print("Kiln example \(websocket ? "WebSocket" : "REST") module listening on 127.0.0.1:\(port)")
        try channel.closeFuture.wait()
    }
}
