import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import SwiftTerm
import KilnKit

/// All mutable terminal and connection state lives on its dedicated NIO event loop.
private final class TerminalState: TerminalDelegate {
    var emulator: SwiftTerm.Terminal!
    var child: Channel?
    var parent: Channel?
    var lastViewer = Date()
    func expireViewer() { if Date().timeIntervalSince(lastViewer) > 6 { owner = nil } }
    var owner: UUID?
    var state = "connecting"
    var closed = false
    var displayName: String?
    var revision: UInt64 = 0
    var cursorVisible = true
    let ready: EventLoopPromise<Void>
    var readyResolved = false
    init(ready: EventLoopPromise<Void>, width: Int, height: Int) {
        self.ready = ready
        var options = TerminalOptions.default
        options.cols = width; options.rows = height; options.scrollback = 1000
        options.enableSixelReported = false; options.kittyImageCacheLimitBytes = 0
        emulator = SwiftTerm.Terminal(delegate: self, options: options)
    }
    func resolve(_ error: Error? = nil) {
        guard !readyResolved else { return }; readyResolved = true
        if let error { ready.fail(error) } else { state = "running"; ready.succeed(()) }
    }
    func end(_ description: String) {
        state = description; revision &+= 1
        resolve(KilnError.message(description))
    }
    func showCursor(source: SwiftTerm.Terminal) { cursorVisible = true }
    func hideCursor(source: SwiftTerm.Terminal) { cursorVisible = false }
    func send(source: SwiftTerm.Terminal, data: ArraySlice<UInt8>) { write(Array(data)) }
    func isProcessTrusted(source: SwiftTerm.Terminal) -> Bool { false }
    func write(_ bytes: [UInt8]) {
        guard let child, child.isActive, state == "running" else { return }
        guard child.isWritable else { end("failed: remote input stalled"); parent?.close(promise: nil); return }
        var buffer = child.allocator.buffer(capacity: bytes.count); buffer.writeBytes(bytes)
        child.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: nil)
    }
    func frame(name: String) -> String {
        let dims = emulator.getDims()
        var output = "\u{1b}[?25l\u{1b}[0m\u{1b}[?7l"
        var previous: Attribute?
        for y in 0..<dims.rows {
            output += "\u{1b}[\(y+1);1H"
            guard let line = emulator.getLine(row: y) else { continue }
            for x in 0..<dims.cols {
                if line.getWidth(index: x) == 0 { continue }
                let cell = line[x]
                if previous != cell.attribute { output += Self.sgr(cell.attribute); previous = cell.attribute }
                let character = emulator.getCharacter(for: cell)
                output += character.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) ? " " : String(character)
            }
        }
        let label = " KILN | \(name) | \(state) | ^B d detach / w sessions / n next / p previous"
        output += "\u{1b}[\(dims.rows+1);1H\u{1b}[0;48;5;238;38;5;215m" + String(label.unicodeScalars.map { $0.value >= 32 && $0.value < 127 ? Character(String($0)) : "?" }.prefix(dims.cols)).padding(toLength: dims.cols, withPad: " ", startingAt: 0)
        let cursor = emulator.getCursorLocation()
        output += "\u{1b}[0m\u{1b}[?7h\u{1b}[\(min(dims.rows,max(1,cursor.y+1)));\(min(dims.cols,max(1,cursor.x+1)))H"
        output += cursorVisible ? "\u{1b}[?25h" : "\u{1b}[?25l"
        output += emulator.applicationCursor ? "\u{1b}[?1h" : "\u{1b}[?1l"
        output += emulator.bracketedPasteMode ? "\u{1b}[?2004h" : "\u{1b}[?2004l"
        return output
    }
    static func sgr(_ attribute: Attribute) -> String {
        var values = ["0"]
        for (style, code): (CharacterStyle, String) in [(.bold,"1"),(.dim,"2"),(.italic,"3"),(.underline,"4"),(.blink,"5"),(.inverse,"7"),(.invisible,"8"),(.crossedOut,"9")] {
            if attribute.style.contains(style) { values.append(code) }
        }
        func color(_ color: Attribute.Color, foreground: Bool) -> String {
            switch color {
            case .ansi256(let code): return "\(foreground ? 38 : 48);5;\(code)"
            case .trueColor(let r, let g, let b): return "\(foreground ? 38 : 48);2;\(r);\(g);\(b)"
            default: return foreground ? "39" : "49"
            }
        }
        values += [color(attribute.fg, foreground: true), color(attribute.bg, foreground: false)]
        return "\u{1b}[" + values.joined(separator: ";") + "m"
    }
}
private final class TerminalParent: ChannelInboundHandler {
    typealias InboundIn = Any
    let state: TerminalState
    init(_ state: TerminalState) { self.state = state }
    func errorCaught(context: ChannelHandlerContext, error: Error) { state.end("failed: \(error)"); context.close(promise: nil) }
    func channelInactive(context: ChannelHandlerContext) {
        if state.state == "running" || state.state == "connecting" { state.end("disconnected") }
        context.fireChannelInactive()
    }
}
private final class TerminalChild: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    let state: TerminalState
    var acceptedPTY = false
    init(_ state: TerminalState) { self.state = state }
    func channelActive(context: ChannelHandlerContext) {
        state.child = context.channel
        let dims = state.emulator.getDims()
        context.triggerUserOutboundEvent(SSHChannelRequestEvent.PseudoTerminalRequest(wantReply: true, term: "xterm-256color", terminalCharacterWidth: dims.cols, terminalRowHeight: dims.rows, terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: .init([:])), promise: nil)
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is ChannelSuccessEvent {
            if !acceptedPTY {
                acceptedPTY = true
                context.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true), promise: nil)
            } else { state.resolve() }
        } else if event is ChannelFailureEvent {
            state.end("failed: destination rejected PTY/shell"); state.parent?.close(promise: nil)
        } else if let exit = event as? SSHChannelRequestEvent.ExitStatus {
            state.end("exited \(exit.exitStatus)")
        } else { context.fireUserInboundEventTriggered(event) }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .byteBuffer(let bytes) = unwrapInboundIn(data).data else { return }
        state.emulator.feed(buffer: Array(bytes.readableBytesView)[...]); state.revision &+= 1
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { state.end("failed: \(error)"); state.parent?.close(promise: nil) }
    func channelInactive(context: ChannelHandlerContext) {
        if state.state == "running" { state.end("closed") }
        state.parent?.close(promise: nil); context.fireChannelInactive()
    }
}

public struct RemoteTerminalFrame: Codable, Sendable { public let revision: UInt64; public let text: String
    public var cursorRow: Int? = nil
    public var cursorColumn: Int? = nil
    public var cursorVisible: Bool? = nil
    public var applicationCursor: Bool? = nil
    public var bracketedPaste: Bool? = nil
}
public final class RemoteTerminal: Sendable {
    public let name: String
    public let server: String
    private let group: MultiThreadedEventLoopGroup
    private let loop: EventLoop
    private let state: NIOLoopBound<TerminalState>
    private init(name: String, server: String, group: MultiThreadedEventLoopGroup, loop: EventLoop, state: NIOLoopBound<TerminalState>) {
        self.name = name; self.server = server; self.group = group; self.loop = loop; self.state = state
    }
    deinit { group.shutdownGracefully { _ in } }
    static func open(name: String, server: ServerProfile, key: NIOSSHPrivateKey, hostKey: NIOSSHPublicKey) async throws -> RemoteTerminal {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1), width = 80, height = 23
        let loop = group.next(), ready = group.next().makePromise(of: Void.self)
        let state = try await loop.submit { NIOLoopBound(TerminalState(ready: ready, width: width, height: height), eventLoop: loop) }.get()
        let timeout = loop.scheduleTask(in: .seconds(15)) { state.value.end("failed: SSH connection timed out"); state.value.parent?.close(promise: nil) }
        do {
            let parent = try await ClientBootstrap(group: loop).connectTimeout(.seconds(5)).channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    state.value.parent = channel
                    try channel.pipeline.syncOperations.addHandlers(NIOSSHHandler(role: .client(.init(userAuthDelegate: Authentication(user: server.user, key: key), serverAuthDelegate: HostPin(hostKey))), allocator: channel.allocator, inboundChildChannelInitializer: nil), TerminalParent(state.value))
                }
            }.connect(host: server.host, port: server.port).get()
            loop.execute {
                do {
                    let handler = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                    let child = loop.makePromise(of: Channel.self)
                    child.futureResult.whenFailure { state.value.end("failed: \($0)") }
                    handler.createChannel(child) { channel, type in
                        guard type == .session else { return loop.makeFailedFuture(KilnError.message("Unexpected channel")) }
                        return loop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(TerminalChild(state.value)) }
                    }
                } catch { state.value.end("failed: \(error)") }
            }
            try await ready.futureResult.get(); timeout.cancel()
            return RemoteTerminal(name: name, server: server.name, group: group, loop: loop, state: state)
        } catch {
            timeout.cancel()
            try? await loop.submit { state.value.resolve(error); state.value.parent?.close(promise: nil) }.get()
            try? await group.shutdownGracefully(); throw error
        }
    }
    public func snapshot() async -> TerminalSessionSnapshot {
        (try? await loop.submit { self.state.value.expireViewer(); return TerminalSessionSnapshot(name: self.state.value.displayName ?? self.name, server: self.server, state: self.state.value.state, attached: self.state.value.owner != nil) }.get()) ?? TerminalSessionSnapshot(name: name, server: server, state: "closed", attached: false)
    }
    public func attach(owner: UUID, width: Int, height: Int) async throws {
        try await loop.submit {
            self.state.value.expireViewer()
            guard self.state.value.owner == nil || self.state.value.owner == owner else { throw KilnError.message("Session is already attached; detach its other viewer first") }
            self.state.value.owner = owner; self.state.value.lastViewer = Date()
            self.resizeOnLoop(width: width, height: height)
        }.get()
    }
    public func detach(owner: UUID) {
        loop.execute { if self.state.value.owner == owner { self.state.value.owner = nil } }
    }
    public func send(_ bytes: [UInt8], owner: UUID) {
        loop.execute { if self.state.value.owner == owner { self.state.value.write(bytes) } }
    }
    public func resize(width: Int, height: Int, owner: UUID) {
        loop.execute { if self.state.value.owner == owner { self.resizeOnLoop(width: width, height: height) } }
    }
    private func resizeOnLoop(width: Int, height: Int) {
        guard width >= 10, height >= 3, width <= 200_000 / height else { return }
        let rows = height - 1, state = state.value
        if state.emulator.getDims() != (width, rows) {
            state.emulator.changeHistorySize(max(0, min(1000, 200_000 / width - rows)))
            state.emulator.resize(cols: width, rows: rows)
            state.child?.triggerUserOutboundEvent(SSHChannelRequestEvent.WindowChangeRequest(terminalCharacterWidth: width, terminalRowHeight: rows, terminalPixelWidth: 0, terminalPixelHeight: 0), promise: nil)
        }
        state.revision &+= 1
    }
    public func frame(owner: UUID, after revision: UInt64?) async -> RemoteTerminalFrame? {
        try? await loop.submit {
            let state = self.state.value
            state.expireViewer()
            if state.owner == owner { state.lastViewer = Date() }
            if state.closed { return RemoteTerminalFrame(revision: .max, text: "Session closed") }
            guard state.owner == owner else { return RemoteTerminalFrame(revision:.max,text:"Viewer lease expired; reattach the session") }
            guard revision != state.revision else { return nil as RemoteTerminalFrame? }
            let cursor = state.emulator.getCursorLocation()
            let dims = state.emulator.getDims()
            return RemoteTerminalFrame(revision: state.revision, text: state.frame(name: state.displayName ?? self.name),cursorRow:min(dims.rows,max(1,cursor.y+1)),cursorColumn:min(dims.cols,max(1,cursor.x+1)),cursorVisible:state.cursorVisible,applicationCursor:state.emulator.applicationCursor,bracketedPaste:state.emulator.bracketedPasteMode)
        }.get()
    }
    public func rename(_ name: String) async throws {
        try await loop.submit {
            self.state.value.expireViewer()
            guard self.state.value.owner == nil else { throw KilnError.message("Detach the session before renaming it") }
            self.state.value.displayName = name; self.state.value.revision &+= 1
        }.get()
    }
    public func close() async {
        try? await loop.submit { self.state.value.closed = true; self.state.value.end("closed"); self.state.value.parent?.close(promise: nil); self.state.value.owner = nil }.get()
    }
}
