import Foundation
import Crypto
import NIOCore
import NIOPosix
import NIOSSH
import KilnCommands
import KilnTerminal

private enum SSHError: Error { case unsupportedChannel }
private struct ServerShutdown: Sendable {}
/// Lock protects only the registry; session state stays on its event loop.
private final class Sessions: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: Channel] = [:]
    private var closing = false
    func insert(_ channel: Channel) -> Bool {
        lock.withLock {
            guard !closing else { return false }
            channels[ObjectIdentifier(channel)] = channel
            return true
        }
    }
    func remove(_ channel: Channel) { _ = lock.withLock { channels.removeValue(forKey: ObjectIdentifier(channel)) } }
    func drain() -> [Channel] { lock.withLock { closing = true; return Array(channels.values) } }
}


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

/// Mutable session state is confined to the channel event loop.
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
    var terminal: KilnTerminal?
    var keys = TerminalKeys()
    var refreshTask: Task<Void, Never>?
    var escapeTask: Scheduled<Void>?
    var refreshing = false
    var lastFrame = ""

    init(commands: KilnCommands) { self.commands = commands }
    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in channel.close(promise: nil) }
    }
    func channelInactive(context: ChannelHandlerContext) {
        refreshTask?.cancel(); escapeTask?.cancel()
        context.fireChannelInactive()
    }
    func output(_ text: String, channel: Channel) {
        var bytes = channel.allocator.buffer(capacity: text.utf8.count)
        bytes.writeString(text)
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(bytes)), promise: nil)
    }
    func paint(channel: Channel) {
        guard let terminal, interactive, channel.isWritable else { return }
        let frame = terminal.render()
        if frame != lastFrame { output(frame, channel: channel); lastFrame = frame }
    }
    func refresh(channel: Channel) {
        guard !refreshing, channel.isActive else { return }
        refreshing = true
        let bound = NIOLoopBound(self, eventLoop: channel.eventLoop)
        let commands = commands
        Task {
            let modules = await commands.snapshot()
            channel.eventLoop.execute {
                let shell = bound.value; shell.refreshing = false
                guard channel.isActive else { return }
                shell.terminal?.update(modules); shell.paint(channel: channel)
            }
        }
    }
    func reply(_ wanted: Bool, accepted: Bool, channel: Channel) {
        if wanted {
            if accepted { channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
            else { channel.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil) }
        }
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ServerShutdown: close(channel: context.channel, status: 0)
        case let request as SSHChannelRequestEvent.PseudoTerminalRequest:
            if !started {
                pty = true
                if request.term != "dumb" {
                    terminal = KilnTerminal()
                    terminal?.resize(width: request.terminalCharacterWidth, height: request.terminalRowHeight)
                }
            }
            reply(request.wantReply, accepted: !started, channel: context.channel)
        case let request as SSHChannelRequestEvent.WindowChangeRequest:
            if terminal != nil {
                terminal?.resize(width: request.terminalCharacterWidth, height: request.terminalRowHeight)
                lastFrame = ""; output("\u{1b}[2J", channel: context.channel); paint(channel: context.channel)
            }
        case let request as SSHChannelRequestEvent.ShellRequest:
            guard !started else { reply(request.wantReply, accepted: false, channel: context.channel); return }
            started = true; interactive = true
            reply(request.wantReply, accepted: true, channel: context.channel)
            if terminal != nil {
                output(KilnTerminal.enterScreen, channel: context.channel); paint(channel: context.channel)
                refresh(channel: context.channel)
                let bound = NIOLoopBound(self, eventLoop: context.eventLoop)
                let channel = context.channel
                let commands = self.commands
                refreshTask = Task {
                    for await observation in commands.observations() {
                        guard !Task.isCancelled else { break }
                        channel.eventLoop.execute {
                            guard channel.isActive else { return }
                            bound.value.terminal?.observe(observation)
                            bound.value.paint(channel: channel)
                        }
                    }
                }
            } else { output("Welcome to Kiln\r\nType help for commands.\r\nkiln> ", channel: context.channel) }
        case let request as SSHChannelRequestEvent.ExecRequest:
            guard !started, request.command.utf8.count <= 4096 else { reply(request.wantReply, accepted: false, channel: context.channel); return }
            started = true; terminal = nil
            reply(request.wantReply, accepted: true, channel: context.channel)
            submit(request.command, channel: context.channel)
        case let request as SSHChannelRequestEvent.EnvironmentRequest:
            reply(request.wantReply, accepted: false, channel: context.channel)
        case let request as SSHChannelRequestEvent.SubsystemRequest:
            reply(request.wantReply, accepted: false, channel: context.channel)
        default: context.fireUserInboundEventTriggered(event)
        }
    }
    func apply(_ key: TerminalKey, channel: Channel) {
        for effect in terminal?.handle(key) ?? [] {
            switch effect {
            case .command(let command): submit(command, channel: channel)
            case .disconnect: close(channel: channel, status: 0)
            }
        }
    }
    func close(channel: Channel, status: Int) {
        refreshTask?.cancel(); escapeTask?.cancel()
        if terminal != nil { output(KilnTerminal.leaveScreen, channel: channel); terminal = nil }
        interactive = false
        channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: status)).whenComplete { _ in channel.close(promise: nil) }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard interactive else { return }
        let packet = unwrapInboundIn(data)
        guard packet.type == .channel, case .byteBuffer(let bytes) = packet.data else { return }
        if terminal != nil {
            escapeTask?.cancel()
            for key in keys.feed(Array(bytes.readableBytesView)) { apply(key, channel: context.channel) }
            if keys.awaitingEscape {
                let bound = NIOLoopBound(self, eventLoop: context.eventLoop)
                let channel = context.channel
                escapeTask = context.eventLoop.scheduleTask(in: .milliseconds(150)) {
                    for key in bound.value.keys.expireEscape() { bound.value.apply(key, channel: channel) }
                    bound.value.paint(channel: channel)
                }
            }
            paint(channel: context.channel); return
        }
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
            case 3: input.removeAll(); output("^C\r\nkiln> ", channel: context.channel)
            case 4: if input.isEmpty { close(channel: context.channel, status: 0); return }
            case 32...126, 128...255:
                guard input.count < 4096 else { close(channel: context.channel, status: 2); return }
                input.append(byte)
                if pty { output(String(decoding: [byte], as: UTF8.self), channel: context.channel) }
            default: break
            }
        }
    }
    func submit(_ line: String, channel: Channel) {
        if busy {
            guard pending.count < 16 else { close(channel: channel, status: 2); return }
            pending.append(line); return
        }
        busy = true
        let bound = NIOLoopBound(self, eventLoop: channel.eventLoop)
        let commands = self.commands
        Task {
            let result = await commands.execute(line)
            let modules = await commands.snapshot()
            channel.eventLoop.execute {
                let shell = bound.value
                guard channel.isActive else { return }
                shell.busy = false
                if shell.terminal != nil {
                    shell.terminal?.update(modules)
                    shell.terminal?.finish(text: result.text, status: result.status)
                    if result.disconnect { shell.close(channel: channel, status: result.status) }
                    else { shell.paint(channel: channel) }
                } else {
                    shell.output(result.text.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n", channel: channel)
                    if result.disconnect || !shell.interactive { shell.close(channel: channel, status: result.status) }
                    else {
                        shell.output("kiln> ", channel: channel)
                        if !shell.pending.isEmpty { let next = shell.pending.removeFirst(); shell.submit(next, channel: channel) }
                    }
                }
            }
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { close(channel: context.channel, status: 1) }
}

/// Optional transport. The runtime and command engine do not depend on this target.
public final class KilnSSHServer: Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    private let sessions: Sessions
    private init(group: MultiThreadedEventLoopGroup, channel: Channel, sessions: Sessions) { self.group = group; self.channel = channel; self.sessions = sessions }

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
        let sessions = Sessions()
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandlers([
                            NIOSSHHandler(role: .server(.init(hostKeys: [hostKey], userAuthDelegate: KeyAuthentication(username: username, keys: keys))), allocator: channel.allocator, inboundChildChannelInitializer: { child, type in
                                guard case .session = type else { return child.eventLoop.makeFailedFuture(SSHError.unsupportedChannel) }
                                return child.eventLoop.makeCompletedFuture {
                                    guard sessions.insert(child) else { throw SSHError.unsupportedChannel }
                                    child.closeFuture.whenComplete { _ in sessions.remove(child) }
                                    try child.pipeline.syncOperations.addHandler(ShellHandler(commands: commands))
                                }
                            }),
                            CloseOnError(),
                        ])
                    }
                }.bind(host: host, port: port).get()
            return KilnSSHServer(group: group, channel: channel, sessions: sessions)
        } catch { try? await group.shutdownGracefully(); throw error }
    }

    public func stop() async {
        try? await channel.close().get()
        let active = sessions.drain()
        for session in active {
            session.eventLoop.execute { session.pipeline.fireUserInboundEventTriggered(ServerShutdown()) }
        }
        // Give terminal reset/exit packets time to flush, without allowing a stalled
        // client to hold up runtime shutdown indefinitely.
        try? await Task.sleep(for: .milliseconds(100))
        try? await group.shutdownGracefully()
    }
}
