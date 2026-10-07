import Foundation
import Crypto
import NIOCore
import NIOPosix
import NIOSSH
import KilnCommands

private enum SSHError: Error { case unsupportedChannel }

private final class KeyAuthentication: NIOSSHServerUserAuthenticationDelegate {
    let username: String
    let keys: [NIOSSHPublicKey]
    init(username: String, keys: [NIOSSHPublicKey]) { self.username = username; self.keys = keys }
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .publicKey }
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        guard request.username == username, case .publicKey(let supplied) = request.request,
              keys.contains(supplied.publicKey) else { responsePromise.succeed(.failure); return }
        responsePromise.succeed(.success)
    }
}

private final class CloseOnError: ChannelInboundHandler, Sendable {
    typealias InboundIn = Any
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

/// All mutable shell state is confined to the channel's event loop.
private final class ShellHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    let commands: KilnCommands
    var input: [UInt8] = []
    var started = false
    var interactive = false
    var pty = false
    var busy = false
    var pending: [String] = []
    var lastCR = false

    init(commands: KilnCommands) { self.commands = commands }
    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in channel.close(promise: nil) }
    }
    func output(_ text: String, channel: Channel) {
        var bytes = channel.allocator.buffer(capacity: text.utf8.count)
        bytes.writeString(text)
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(bytes)), promise: nil)
    }
    func reply(_ wanted: Bool, accepted: Bool, channel: Channel) {
        if wanted {
            if accepted { channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
            else { channel.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil) }
        }
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let request as SSHChannelRequestEvent.PseudoTerminalRequest:
            pty = !started
            reply(request.wantReply, accepted: !started, channel: context.channel)
        case let request as SSHChannelRequestEvent.ShellRequest:
            guard !started else { reply(request.wantReply, accepted: false, channel: context.channel); return }
            started = true; interactive = true
            reply(request.wantReply, accepted: true, channel: context.channel)
            output("Welcome to Kiln\r\nP.Industries | development runtime\r\nType help for commands.\r\n\r\nkiln> ", channel: context.channel)
        case let request as SSHChannelRequestEvent.ExecRequest:
            guard !started, request.command.utf8.count <= 4096 else { reply(request.wantReply, accepted: false, channel: context.channel); return }
            started = true
            reply(request.wantReply, accepted: true, channel: context.channel)
            submit(request.command, channel: context.channel)
        case let request as SSHChannelRequestEvent.EnvironmentRequest:
            reply(request.wantReply, accepted: false, channel: context.channel)
        case let request as SSHChannelRequestEvent.SubsystemRequest:
            reply(request.wantReply, accepted: false, channel: context.channel)
        default: context.fireUserInboundEventTriggered(event)
        }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard interactive else { return }
        let packet = unwrapInboundIn(data)
        guard packet.type == .channel, case .byteBuffer(let bytes) = packet.data else { return }
        for byte in bytes.readableBytesView {
            if byte == 10 && lastCR { lastCR = false; continue }
            lastCR = byte == 13
            switch byte {
            case 10, 13:
                if pty { output("\r\n", channel: context.channel) }
                let line = String(decoding: input, as: UTF8.self); input.removeAll(keepingCapacity: true)
                submit(line, channel: context.channel)
            case 127, 8:
                if !input.isEmpty { input.removeLast(); if pty { output("\u{8} \u{8}", channel: context.channel) } }
            case 3:
                input.removeAll(); output("^C\r\nkiln> ", channel: context.channel)
            case 4:
                if input.isEmpty { context.close(promise: nil); return }
            case 32...126, 128...255:
                guard input.count < 4096 else { context.close(promise: nil); return }
                input.append(byte)
                if pty { output(String(decoding: [byte], as: UTF8.self), channel: context.channel) }
            default: break
            }
        }
    }
    func submit(_ line: String, channel: Channel) {
        if busy {
            guard pending.count < 16 else { channel.close(promise: nil); return }
            pending.append(line); return
        }
        busy = true
        let bound = NIOLoopBound(self, eventLoop: channel.eventLoop)
        let commands = self.commands
        Task {
            let result = await commands.execute(line)
            channel.eventLoop.execute {
                let shell = bound.value
                guard channel.isActive else { return }
                shell.output(result.text.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n", channel: channel)
                if result.disconnect || !shell.interactive {
                    channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: result.status)).whenComplete { _ in channel.close(promise: nil) }
                } else {
                    shell.busy = false
                    shell.output("kiln> ", channel: channel)
                    if !shell.pending.isEmpty { let next = shell.pending.removeFirst(); shell.submit(next, channel: channel) }
                }
            }
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

/// Optional transport. The runtime and command engine do not depend on this target.
public final class KilnSSHServer: Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    private init(group: MultiThreadedEventLoopGroup, channel: Channel) { self.group = group; self.channel = channel }

    public static func start(host: String, port: Int, username: String, authorizedKeys: URL, stateDirectory: URL, commands: KilnCommands) async throws -> KilnSSHServer {
        let lines = try String(contentsOf: authorizedKeys, encoding: .utf8).split(separator: "\n")
        let keys = try lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { try NIOSSHPublicKey(openSSHPublicKey: String($0)) }
        guard !keys.isEmpty else { throw NSError(domain: "KilnSSH", code: 1, userInfo: [NSLocalizedDescriptionKey: "No authorized keys"]) }
        let keyURL = stateDirectory.appendingPathComponent("ssh-host-ed25519")
        let privateKey: Curve25519.Signing.PrivateKey
        if FileManager.default.fileExists(atPath: keyURL.path) {
            privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: keyURL))
        } else {
            privateKey = Curve25519.Signing.PrivateKey()
            guard FileManager.default.createFile(atPath: keyURL.path, contents: privateKey.rawRepresentation, attributes: [.posixPermissions: 0o600]) else {
                throw NSError(domain: "KilnSSH", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot persist host key"])
            }
        }
        let hostKey = NIOSSHPrivateKey(ed25519Key: privateKey)
        try (String(openSSHPublicKey: hostKey.publicKey) + "\n").write(to: stateDirectory.appendingPathComponent("ssh-host-ed25519.pub"), atomically: true, encoding: .utf8)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandlers([
                            NIOSSHHandler(role: .server(.init(hostKeys: [hostKey], userAuthDelegate: KeyAuthentication(username: username, keys: keys))), allocator: channel.allocator, inboundChildChannelInitializer: { child, type in
                                guard case .session = type else { return child.eventLoop.makeFailedFuture(SSHError.unsupportedChannel) }
                                return child.eventLoop.makeCompletedFuture { try child.pipeline.syncOperations.addHandler(ShellHandler(commands: commands)) }
                            }),
                            CloseOnError(),
                        ])
                    }
                }.bind(host: host, port: port).get()
            return KilnSSHServer(group: group, channel: channel)
        } catch { try? await group.shutdownGracefully(); throw error }
    }

    public func stop() async {
        try? await channel.close().get()
        try? await group.shutdownGracefully()
    }
}
