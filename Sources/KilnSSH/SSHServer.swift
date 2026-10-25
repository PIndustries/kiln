import Foundation
import Crypto
import NIOCore
import NIOPosix
import NIOSSH
import KilnKit
import KilnCommands
import KilnTerminal
import KilnBastion

private enum SSHError: Error { case unsupportedChannel, capacity }
struct ServerShutdown: Sendable {}
/// Lock protects only the registry; session state stays on its event loop.
private final class Sessions: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: Channel] = [:]
    private var closing = false
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    func insert(_ channel: Channel) -> Bool {
        lock.withLock {
            guard !closing, channels.count < limit else { return false }
            channels[ObjectIdentifier(channel)] = channel
            return true
        }
    }
    func remove(_ channel: Channel) { _ = lock.withLock { channels.removeValue(forKey: ObjectIdentifier(channel)) } }
    func drain() -> [Channel] { lock.withLock { closing = true; return Array(channels.values) } }
}


private final class KeyAuthentication: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
    private let commands: KilnCommands
    private let lock = NSLock()
    private var authenticated: KilnCommands?
    private var attempts = 0
    let diagnostics: SSHAdmissionDiagnostics
    let connectionID: UUID
    private let channel: Channel
    init(commands: KilnCommands, channel: Channel, diagnostics: SSHAdmissionDiagnostics, connectionID: UUID) { self.commands = commands; self.channel = channel; self.diagnostics = diagnostics; self.connectionID = connectionID }
    var sessionCommands: KilnCommands? { lock.withLock { authenticated } }
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .publicKey }
    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        let allowed = lock.withLock { attempts += 1; return attempts <= 6 }
        guard allowed else { diagnostics.record(.authenticationBudget, connection: connectionID); responsePromise.succeed(.failure); channel.close(promise: nil); return }
        guard case .publicKey(let supplied) = request.request else { diagnostics.record(.methodRejected, connection: connectionID); responsePromise.succeed(.failure); return }
        let bound = commands.forIdentity(name: request.username, publicKey: String(openSSHPublicKey: supplied.publicKey))
        guard bound.isAuthorized() else { diagnostics.record(.identityRejected, connection: connectionID); responsePromise.succeed(.failure); return }
        lock.withLock { authenticated = bound }
        responsePromise.succeed(.success)
    }
}

/// Bound pre-authentication occupancy and parser input independently of SSH keys.
private final class AuthenticationDeadline: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let authentication: KeyAuthentication
    private var deadline: Scheduled<Void>?
    private var received = 0
    init(_ authentication: KeyAuthentication) { self.authentication = authentication }
    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel, authentication = authentication
        deadline = context.eventLoop.scheduleTask(in: .seconds(15)) {
            if authentication.sessionCommands == nil { authentication.diagnostics.record(.authenticationTimeout, connection: authentication.connectionID); channel.close(promise: nil) }
        }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if authentication.sessionCommands == nil {
            received += unwrapInboundIn(data).readableBytes
            guard received <= 131_072 else { authentication.diagnostics.record(.preauthenticationBytes, connection: authentication.connectionID); context.close(promise: nil); return }
        } else { deadline?.cancel(); deadline = nil }
        context.fireChannelRead(data)
    }
    func channelInactive(context: ChannelHandlerContext) { deadline?.cancel(); context.fireChannelInactive() }
    func handlerRemoved(context: ChannelHandlerContext) { deadline?.cancel() }
}

private final class CloseOnError: ChannelInboundHandler, Sendable {
    typealias InboundIn = Any
    let diagnostics: SSHAdmissionDiagnostics
    let connectionID: UUID
    init(_ diagnostics: SSHAdmissionDiagnostics, _ connectionID: UUID) { self.diagnostics = diagnostics; self.connectionID = connectionID }
    func errorCaught(context: ChannelHandlerContext, error: Error) { diagnostics.record(.protocolError, connection: connectionID); context.close(promise: nil) }
}

/// Mutable session state is confined to the channel event loop.
private final class ShellHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    let commands: KilnCommands
    var input: [UInt8] = []
    var secretName: String?
    var secretValue = ""
    var secretSaving = false
    var secretInputRejected = false
    var started = false
    var interactive = false
    var pty = false
    var busy = false
    var commandTask: Task<Void, Never>?
    var workspaceTask: Task<Void, Never>?
    var pending: [String] = []
    var lastCR = false
    var terminal: KilnTerminal?
    var keys = TerminalKeys()
    var refreshTask: Task<Void, Never>?
    var escapeTask: Scheduled<Void>?
    var refreshing = false
    var lastFrame = ""
    var selectingText = false
    var progressPaint: Scheduled<Void>?
    var chatAnimation: RepeatedTask?
    var panes: [RemoteTerminalClient] = []
    var focusedPane = 0
    var stacked = false
    var splitRatio = 0.5
    var paneGeneration = 0
    var remoteEscape: [UInt8] = []
    var remote: RemoteTerminalClient? { panes.indices.contains(focusedPane) ? panes[focusedPane] : nil }
    var remoteTask: Task<Void, Never>?
    let owner = UUID()
    var remotePrefix = false
    var columns = 80
    var rows = 24
    var attaching = false

    init(commands: KilnCommands) { self.commands = commands }
    func handlerAdded(context: ChannelHandlerContext) {
        let channel = context.channel
        channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in channel.close(promise: nil) }
    }
    func channelInactive(context: ChannelHandlerContext) {
        workspaceTask?.cancel(); commandTask?.cancel(); progressPaint?.cancel(); chatAnimation?.cancel()
        secretValue = ""; secretName = nil
        refreshTask?.cancel(); escapeTask?.cancel(); remoteTask?.cancel()
        releasePanes()
        context.fireChannelInactive()
    }
    func output(_ text: String, channel: Channel) {
        var bytes = channel.allocator.buffer(capacity: text.utf8.count)
        bytes.writeString(text)
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(bytes)), promise: nil)
    }
    func paint(channel: Channel) {
        guard !selectingText, remote == nil, !attaching, let terminal, interactive, channel.isWritable else { return }
        let frame: String
        if secretName != nil || secretSaving {
            frame = "\u{1B}[0m" + terminal.theme.backgroundCode + terminal.theme.accentCode + "\u{1B}[2J\u{1B}[HKILN VAULT\u{1B}[0m\r\n\r\n" + (secretSaving ? "Saving credential..." : "Secret: \(secretName!)\r\nValue: [hidden]\r\n\r\nEnter saves. Escape/Ctrl-C cancels. Backspace edits. Maximum 16 KiB." + (secretInputRejected ? "\r\nInput rejected (size or newline). Ctrl-U clears the field; enter it again." : ""))
        } else { frame = terminal.render() }
        if frame != lastFrame {
            // Chat frames have fixed rows and no overlay cursor escapes. Patch changed
            // rows instead of repainting the entire transcript for every token.
            let old = lastFrame.components(separatedBy: "\r\n")
            let new = frame.components(separatedBy: "\r\n")
            if terminal.chatVisible, secretName == nil, !secretSaving,
               old.count == rows, new.count == rows, lastFrame.contains("KILN AI CHAT") {
                var patch = "\u{1b}[?25l"
                for index in new.indices where old[index] != new[index] {
                    let content = index == 0 ? new[index].replacingOccurrences(of: "\u{1b}[?25l\u{1b}[H", with: "") : new[index]
                    patch += "\u{1b}[\(index+1);1H" + content
                }
                // Restore the composer cursor even when its row did not change.
                if frame.hasSuffix("\u{1b}[?25h"), let tail = new.last, let cursor = tail.range(of: "\u{1b}[", options: .backwards, range: tail.startIndex..<tail.index(tail.endIndex, offsetBy: -6)) {
                    patch += String(tail[cursor.lowerBound...])
                }
                output(patch, channel: channel)
            } else { output(frame, channel: channel) }
            lastFrame = frame
        }
    }
    func refresh(channel: Channel) {
        guard !refreshing, channel.isActive else { return }
        refreshing = true
        let bound = NIOLoopBound(self, eventLoop: channel.eventLoop)
        let commands = commands
        let sessionID = owner.uuidString
        Task {
            let modules = await commands.snapshot()
            let management = await commands.management()
            let workspace = await commands.aiWorkspace(sessionID: sessionID)
            channel.eventLoop.execute {
                let shell = bound.value; shell.refreshing = false
                guard channel.isActive else { return }
                shell.terminal?.update(modules); shell.terminal?.updateManagement(management); shell.terminal?.updateAIWorkspace(workspace); shell.paint(channel: channel)
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
                columns = max(10, request.terminalCharacterWidth); rows = max(3, request.terminalRowHeight)
                if request.term != "dumb" {
                    terminal = KilnTerminal()
                    do { terminal?.applyTheme(try commands.terminalTheme()) }
                    catch { terminal?.finish(text: "Saved theme unavailable. Using black and green; theme default can reset it.", status: 1) }
                    terminal?.resize(width: request.terminalCharacterWidth, height: request.terminalRowHeight)
                }
            }
            reply(request.wantReply, accepted: !started, channel: context.channel)
        case let request as SSHChannelRequestEvent.WindowChangeRequest:
            if request.terminalCharacterWidth > 0 { columns = request.terminalCharacterWidth }
            if request.terminalRowHeight > 0 { rows = request.terminalRowHeight }
            if remote != nil {
                resizePanes()
                terminal?.resize(width: columns, height: rows)
                return
            }
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
                let sessionID = owner.uuidString
                refreshTask = Task {
                    for await observation in commands.observations() {
                        guard !Task.isCancelled else { break }
                        guard commands.isAuthorized() else { channel.close(promise: nil); break }
                        let management = await commands.management()
                        let workspace = await commands.aiWorkspace(sessionID: sessionID)
                        channel.eventLoop.execute {
                            guard channel.isActive else { return }
                            bound.value.terminal?.observe(observation)
                            bound.value.terminal?.updateManagement(management)
                            bound.value.terminal?.updateAIWorkspace(workspace)
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
        guard commands.isAuthorized() else { channel.close(promise: nil); return }
        if key == .interrupt, busy, secretName == nil, !secretSaving { commandTask?.cancel(); return }
        if secretSaving { return }
        if let name = secretName {
            switch key {
            case .text(let value), .paste(let value):
                if !value.contains("\n"), !value.contains("\r"), !value.utf8.contains(0), secretValue.utf8.count + value.utf8.count <= 16384 { secretValue += value } else { secretInputRejected = true }
            case .backspace: if !secretValue.isEmpty { secretValue.removeLast() }
            case .clearBefore: secretValue = ""; secretInputRejected = false
            case .escape, .interrupt, .eof:
                secretName = nil; secretValue = ""; secretSaving = true
                let bound = NIOLoopBound(self, eventLoop: channel.eventLoop)
                channel.eventLoop.execute {
                    bound.value.secretSaving = false
                    bound.value.terminal?.finish(text: "Vault entry cancelled.", status: 0)
                    bound.value.paint(channel: channel)
                }
            case .enter:
                guard !secretInputRejected else { return }
                let value = secretValue; secretValue = ""; secretName = nil; secretSaving = true
                let bound = NIOLoopBound(self, eventLoop: channel.eventLoop); let commands = commands
                Task {
                    let result = commands.putSecret(name: name, value: value)
                    channel.eventLoop.execute {
                        let shell = bound.value; shell.secretSaving = false
                        shell.terminal?.finish(text: result.text, status: result.status)
                        shell.paint(channel: channel)
                    }
                }
            default: break
            }
            return
        }
        for effect in terminal?.handle(key) ?? [] {
            switch effect {
            case .command(let command): submit(command, channel: channel)
            case .workspaceRead(let command): readWorkspace(command, channel: channel)
            case .disconnect: close(channel: channel, status: 0)
            case .selectText(let enabled):
                selectingText = false; lastFrame = ""; paint(channel: channel)
                selectingText = enabled
                output(enabled ? "\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1006l" : "\u{1b}[?1000h\u{1b}[?1006h", channel: channel)
            }
        }
    }
    func close(channel: Channel, status: Int) {
        workspaceTask?.cancel(); commandTask?.cancel(); progressPaint?.cancel(); chatAnimation?.cancel()
        remoteTask?.cancel(); releasePanes()
        refreshTask?.cancel(); escapeTask?.cancel()
        if terminal != nil { output(KilnTerminal.leaveScreen, channel: channel); terminal = nil }
        interactive = false
        channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: status)).whenComplete { _ in channel.close(promise: nil) }
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard interactive else { return }
        let packet = unwrapInboundIn(data)
        guard packet.type == .channel, case .byteBuffer(let bytes) = packet.data else { return }
        if remote != nil {
            remoteInput(Array(bytes.readableBytesView), channel: context.channel); return
        }
        if attaching { return }
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
    func readWorkspace(_ line: String, channel: Channel) {
        guard workspaceTask == nil else { return }
        // A separate lane is deliberately restricted to registered source reads.
        guard let parts = try? KilnCommands.tokenize(line), parts.count >= 4,
              parts[0] == "web", ["browse", "file"].contains(parts[1]) else { return }
        let bound = NIOLoopBound(self, eventLoop: channel.eventLoop)
        let commands = self.commands, sessionID = owner.uuidString
        workspaceTask = Task {
            let result = await commands.execute(line, sessionID: sessionID)
            channel.eventLoop.execute {
                let shell = bound.value
                shell.workspaceTask = nil
                guard channel.isActive else { return }
                if (try? commands.authorizeAdmin()) != nil {
                    shell.terminal?.finishWorkspace(text: result.text, status: result.status)
                } else {
                    shell.terminal?.updateAIWorkspace(AIWorkspaceSnapshot(error: "Identity revoked or unauthorized"))
                }
                shell.paint(channel: channel)
            }
        }
    }
    func submit(_ line: String, channel: Channel) {
        if interactive, terminal != nil, !busy,
           let parsed = try? KilnCommands.tokenize(line) {
            let parts = parsed.first == "kiln" ? Array(parsed.dropFirst()) : parsed
            if parts.count == 3, parts[0] == "vault", parts[1] == "put", (try? commands.authorizeAdmin()) != nil {
                let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
                if !parts[2].isEmpty, parts[2].count <= 80, parts[2] != ".", parts[2] != "..", parts[2].unicodeScalars.allSatisfy({ allowed.contains($0) }) {
                    secretName = parts[2]; secretValue = ""; secretInputRejected = false
                    terminal?.finish(text: "Vault secret entry opened.", status: 0)
                    paint(channel: channel); return
                }
            }
        }
        if busy {
            guard pending.count < 16 else { close(channel: channel, status: 2); return }
            pending.append(line); return
        }
        busy = true
        let bound = NIOLoopBound(self, eventLoop: channel.eventLoop)
        let commands = self.commands
        let sessionID = owner.uuidString
        chatAnimation?.cancel()
        chatAnimation = channel.eventLoop.scheduleRepeatedTask(initialDelay: .milliseconds(100), delay: .milliseconds(100)) { _ in
            let shell = bound.value
            guard shell.busy, channel.isActive else { shell.chatAnimation?.cancel(); shell.chatAnimation = nil; return }
            if shell.terminal?.chatVisible == true { shell.terminal?.tick(); shell.paint(channel: channel) }
        }
        commandTask = Task {
            let result = await commands.execute(line, sessionID: sessionID) { event in
                channel.eventLoop.execute {
                    let shell = bound.value
                    guard channel.isActive else { return }
                    shell.terminal?.progress(event)
                    if shell.progressPaint == nil {
                        shell.progressPaint = channel.eventLoop.scheduleTask(in: .milliseconds(50)) {
                            let shell = bound.value
                            shell.progressPaint = nil; shell.paint(channel: channel)
                        }
                    }
                }
            }
            let modules = await commands.snapshot()
            let management = await commands.management()
            let workspace = await commands.aiWorkspace(sessionID: sessionID)
            channel.eventLoop.execute {
                let shell = bound.value
                shell.terminal?.updateManagement(management)
                shell.terminal?.updateAIWorkspace(workspace)
                guard channel.isActive else { return }
                shell.busy = false
                if let name = result.attachSession, shell.interactive, shell.terminal != nil {
                    shell.terminal?.finish(text: result.text, status: 0)
                    shell.attach(name, channel: channel); return
                }
                if result.attachSession != nil {
                    shell.output("Attach requires the interactive Kiln dashboard (TERM other than dumb).\r\n", channel: channel)
                    if !shell.interactive { shell.close(channel: channel, status: 2); return }
                }
                if shell.terminal != nil {
                    shell.terminal?.update(modules)
                    if let theme = result.terminalTheme { shell.terminal?.applyTheme(theme) }
                    shell.terminal?.finish(text: result.text, status: result.status)
                    if case .workspaceRead(let read) = shell.terminal?.refreshCodeWorkspace() { shell.readWorkspace(read, channel: channel) }
                    if let conversation = result.conversation { shell.terminal?.restoreConversation(conversation) }
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

    struct PaneRect: Sendable { let x: Int; let y: Int; let width: Int; let height: Int }
    func paneRects() -> [PaneRect] {
        guard panes.count == 2 else { return [PaneRect(x:1,y:1,width:columns,height:rows)] }
        if stacked {
            let first = max(3,min(rows-4,Int(Double(rows-1)*splitRatio)))
            return [PaneRect(x:1,y:1,width:columns,height:first),PaneRect(x:1,y:first+2,width:columns,height:max(3,rows-first-1))]
        }
        let first = max(10,min(columns-11,Int(Double(columns-1)*splitRatio)))
        return [PaneRect(x:1,y:1,width:first,height:rows),PaneRect(x:first+2,y:1,width:max(10,columns-first-1),height:rows)]
    }
    func resizePanes() {
        paneGeneration += 1
        for (pane, rect) in zip(panes,paneRects()) { pane.resize(width:rect.width,height:rect.height,owner:owner) }
    }
    func releasePanes() {
        for pane in panes { pane.detach(owner:owner) }
        panes = []; focusedPane = 0; paneGeneration += 1
    }
    func detach(channel: Channel) {
        remoteTask?.cancel(); remoteTask = nil; escapeTask?.cancel()
        releasePanes(); remotePrefix = false; remoteEscape = []
        keys = TerminalKeys(); lastFrame = ""
        output("\u{1b}[?1l\u{1b}[?7h" + KilnTerminal.enterScreen, channel:channel)
        terminal?.showSessions(); terminal?.finish(text:"Detached. Terminals remain in the session service.",status:0)
        paint(channel:channel); refresh(channel:channel)
    }
    func attach(_ name:String, channel:Channel, split:Bool = false, replaceFocused:Bool = false) {
        guard !attaching else { return }; attaching = true
        let bound = NIOLoopBound(self,eventLoop:channel.eventLoop)
        let commands = commands, owner = owner, width = columns, height = rows
        Task {
            do {
                let next = try await commands.session(name)
                try await next.attach(owner:owner,width:width,height:height)
                channel.eventLoop.execute {
                    let shell = bound.value; shell.attaching = false
                    guard channel.isActive else { next.detach(owner:owner); return }
                    if split, shell.panes.count == 1, shell.panes[0].name != name {
                        shell.panes.append(next); shell.focusedPane = 1
                    } else if replaceFocused, shell.panes.indices.contains(shell.focusedPane) {
                        let old = shell.panes[shell.focusedPane]; if old.name != name { old.detach(owner:owner) }
                        shell.panes[shell.focusedPane] = next
                    } else {
                        for old in shell.panes where old.name != name { old.detach(owner:owner) }
                        shell.panes = [next]; shell.focusedPane = 0
                    }
                    shell.remotePrefix = false; shell.remoteEscape = []; shell.resizePanes()
                    shell.output("\u{1b}[?1000h\u{1b}[?1006h\u{1b}[?2004l\u{1b}[0m\u{1b}[2J\u{1b}[H",channel:channel)
                    shell.startPanePump(channel:channel)
                }
            } catch {
                let message = "Error: \(error)"
                channel.eventLoop.execute {
                    let shell = bound.value; shell.attaching = false
                    guard channel.isActive else { return }
                    shell.terminal?.finish(text:message,status:1)
                    if shell.remote == nil { shell.paint(channel:channel) }
                    else { shell.detach(channel:channel); shell.terminal?.finish(text:message,status:1); shell.paint(channel:channel) }
                }
            }
        }
    }
    static func offsetFrame(_ text:String,rect:PaneRect) -> String {
        guard let regex = try? NSRegularExpression(pattern:"\\u001B\\[([0-9]+);([0-9]+)H") else { return text }
        let matches = regex.matches(in:text,range:NSRange(text.startIndex...,in:text))
        var result = text
        for match in matches.reversed() {
            guard let r = Range(match.range,in:result), let ry = Range(match.range(at:1),in:result), let rx = Range(match.range(at:2),in:result), let y = Int(result[ry]), let x = Int(result[rx]) else { continue }
            result.replaceSubrange(r,with:"\u{1b}[\(rect.y+y-1);\(rect.x+x-1)H")
        }
        return result
    }
    func startPanePump(channel:Channel) {
        remoteTask?.cancel()
        let bound = NIOLoopBound(self,eventLoop:channel.eventLoop), owner = owner
        let commands = self.commands
        remoteTask = Task { @Sendable [bound, owner, channel] in
            var frames: [String:RemoteTerminalFrame] = [:], generation = -1
            while !Task.isCancelled {
                guard (try? commands.authorizeAdmin()) != nil else { channel.close(promise:nil); break }
                guard let snapshot = try? await channel.eventLoop.submit({ (bound.value.panes,bound.value.paneRects(),bound.value.paneGeneration,bound.value.focusedPane) }).get(), !snapshot.0.isEmpty else { break }
                var changed = generation != snapshot.2
                if changed { frames = [:] }; generation = snapshot.2
                var ended: String?
                for pane in snapshot.0 {
                    if let frame = await pane.frame(owner:owner,after:frames[pane.name]?.revision) {
                        if frame.revision == .max { ended = frame.text; break }
                        frames[pane.name] = frame; changed = true
                    }
                }
                if let ended {
                    let message = ended
                    try? await channel.eventLoop.submit {
                        guard channel.isActive, bound.value.paneGeneration == snapshot.2 else { return }
                        bound.value.detach(channel:channel); bound.value.terminal?.finish(text:message,status:1); bound.value.paint(channel:channel)
                    }.get(); break
                }
                if changed {
                    var output = "\u{1b}[?25l"
                    for (pane,rect) in zip(snapshot.0,snapshot.1) { if let frame = frames[pane.name] { output += Self.offsetFrame(frame.text,rect:rect) } }
                    if snapshot.0.count == 2 {
                        let first = snapshot.1[0]
                        output += "\u{1b}[0;38;5;215m"
                        if snapshot.1[1].y > 1 {
                            output += "\u{1b}[\(first.height+1);1H" + String(repeating:"=",count:first.width)
                        } else {
                            for row in 1...first.height { output += "\u{1b}[\(row);\(first.width+1)H|" }
                        }
                    }
                    if snapshot.0.indices.contains(snapshot.3), let frame = frames[snapshot.0[snapshot.3].name] {
                        let rect = snapshot.1[snapshot.3]
                        let title = " \(snapshot.3+1):\(snapshot.0[snapshot.3].name) | ^B d/w picker o focus %/\" split x unsplit h/l size"
                        output += "\u{1b}[?7l\u{1b}[\(rect.y+rect.height-1);\(rect.x)H\u{1b}[0;48;5;24;38;5;231m" + String(title.prefix(rect.width)).padding(toLength:rect.width,withPad:" ",startingAt:0) + "\u{1b}[0m\u{1b}[?7h"
                        output += "\u{1b}[\(rect.y+(frame.cursorRow ?? 1)-1);\(rect.x+(frame.cursorColumn ?? 1)-1)H"
                        output += frame.cursorVisible == false ? "\u{1b}[?25l" : "\u{1b}[?25h"
                        output += frame.applicationCursor == true ? "\u{1b}[?1h" : "\u{1b}[?1l"
                        output += frame.bracketedPaste == true ? "\u{1b}[?2004h" : "\u{1b}[?2004l"
                    }
                    let rendered = output
                    let painted = try? await channel.eventLoop.submit {
                        guard channel.isActive,channel.isWritable,bound.value.paneGeneration == snapshot.2 else { return false }
                        bound.value.output(rendered,channel:channel); return true
                    }.get()
                    if painted != true { generation = -1 }
                }
                do { try await Task.sleep(for:.milliseconds(100)) } catch { break }
            }
        }
    }
    func cycleRemote(channel:Channel,backwards:Bool = false,split:Bool = false) {
        let current = remote?.name, commands = commands, namesInView = panes.map(\.name)
        let bound = NIOLoopBound(self,eventLoop:channel.eventLoop)
        Task {
            let sessions = await commands.sessions()
            let names = sessions.filter { (!$0.attached && !namesInView.contains($0.name)) || $0.name == current }.map(\.name)
            guard let current, let index = names.firstIndex(of:current), names.count > 1 else { return }
            let next = names[(index+(backwards ? names.count-1 : 1)) % names.count]
            channel.eventLoop.execute { if channel.isActive { bound.value.attach(next,channel:channel,split:split,replaceFocused:!split) } }
        }
    }
    func remoteInput(_ bytes:[UInt8],channel:Channel) {
        guard (try? commands.authorizeAdmin()) != nil else { releasePanes(); channel.close(promise:nil); return }
        escapeTask?.cancel()
        var forwarded: [UInt8] = []
        for byte in bytes {
            if !remoteEscape.isEmpty {
                remoteEscape.append(byte)
                let prefix = Array("\u{1b}[<".utf8)
                if remoteEscape.count <= 3, prefix.starts(with:remoteEscape) { continue }
                if remoteEscape.starts(with:prefix) {
                    if byte == 77 || byte == 109 {
                        let fields = String(decoding:remoteEscape.dropFirst(3).dropLast(),as:UTF8.self).split(separator:";").compactMap { Int($0) }
                        if byte == 77, fields.count == 3, fields[0] == 0 {
                            for (index,rect) in paneRects().enumerated() where fields[1] >= rect.x && fields[1] < rect.x+rect.width && fields[2] >= rect.y && fields[2] < rect.y+rect.height { focusedPane = index; paneGeneration += 1 }
                        }
                        remoteEscape = []; continue
                    }
                    if remoteEscape.count < 32 { continue }
                }
                forwarded += remoteEscape; remoteEscape = []; continue
            }
            if remotePrefix {
                remotePrefix = false
                if !forwarded.isEmpty { remote?.send(forwarded,owner:owner); forwarded = [] }
                switch byte {
                case 100,119: detach(channel:channel); return
                case 110,112: cycleRemote(channel:channel,backwards:byte == 112); return
                case 37,34:
                    stacked = byte == 34
                    if panes.count == 2 { resizePanes() } else { cycleRemote(channel:channel,split:true) }; return
                case 111: focusedPane = (focusedPane+1) % max(1,panes.count); paneGeneration += 1; return
                case 104,108: splitRatio = min(0.75,max(0.25,splitRatio+(byte == 108 ? 0.05 : -0.05))); resizePanes(); return
                case 120:
                    if let keep = remote { for pane in panes where pane !== keep { pane.detach(owner:owner) }; panes = [keep]; focusedPane = 0; resizePanes(); output("\u{1b}[2J",channel:channel) }; return
                case 2: forwarded.append(2)
                default: forwarded += [2,byte]
                }
            } else if byte == 2 { remotePrefix = true }
            else if byte == 27 { remoteEscape = [27] }
            else { forwarded.append(byte) }
        }
        if !forwarded.isEmpty { remote?.send(forwarded,owner:owner) }
        if !remoteEscape.isEmpty {
            let bound = NIOLoopBound(self,eventLoop:channel.eventLoop)
            escapeTask = channel.eventLoop.scheduleTask(in:.milliseconds(150)) {
                let shell = bound.value; shell.remote?.send(shell.remoteEscape,owner:shell.owner); shell.remoteEscape = []
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
    private let connections: Sessions
    private init(group: MultiThreadedEventLoopGroup, channel: Channel, sessions: Sessions, connections: Sessions) { self.group = group; self.channel = channel; self.sessions = sessions; self.connections = connections }

    public static func start(host: String, port: Int, username: String, authorizedKeys: URL, stateDirectory: URL, commands: KilnCommands) async throws -> KilnSSHServer {
        // Bootstrap keys seed the first policy only. Persisted policy remains the
        // authority on restart even if that original provisioning file is removed.
        if FileManager.default.fileExists(atPath: stateDirectory.appendingPathComponent("identities.json").path)
            || FileManager.default.fileExists(atPath: stateDirectory.appendingPathComponent("identities.initialized").path) {
            try commands.bootstrapIdentity(username: username, keys: [])
        } else {
            let lines = try String(contentsOf: authorizedKeys, encoding: .utf8).split(separator: "\n")
            let keys = try lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { try NIOSSHPublicKey(openSSHPublicKey: String($0)) }
            guard !keys.isEmpty else { throw NSError(domain: "KilnSSH", code: 1, userInfo: [NSLocalizedDescriptionKey: "No authorized keys"]) }
            try commands.bootstrapIdentity(username: username, keys: keys.map { String(openSSHPublicKey: $0) })
        }
        let keyURL = stateDirectory.appendingPathComponent("ssh-host-ed25519")
        let privateKey: Curve25519.Signing.PrivateKey
        if FileManager.default.fileExists(atPath: keyURL.path) {
            privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: keyURL))
        } else {
            privateKey = Curve25519.Signing.PrivateKey()
            try KilnStateFile.write(privateKey.rawRepresentation, to: keyURL)
        }
        let hostKey = NIOSSHPrivateKey(ed25519Key: privateKey)
        try KilnStateFile.write(Data((String(openSSHPublicKey: hostKey.publicKey) + "\n").utf8), to: stateDirectory.appendingPathComponent("ssh-host-ed25519.pub"))
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let sessions = Sessions(limit: 256)
        let connections = Sessions(limit: 128)
        let diagnostics = SSHAdmissionDiagnostics()
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    let connectionID = UUID()
                    guard connections.insert(channel) else { diagnostics.record(.connectionCapacity, connection: connectionID); return channel.close() }
                    channel.closeFuture.whenComplete { _ in connections.remove(channel) }
                    let children = Sessions(limit: 16)
                    return channel.eventLoop.makeCompletedFuture {
                        let authentication = KeyAuthentication(commands: commands, channel: channel, diagnostics: diagnostics, connectionID: connectionID)
                        try channel.pipeline.syncOperations.addHandlers([
                            AuthenticationDeadline(authentication),
                            NIOSSHHandler(role: .server(.init(hostKeys: [hostKey], userAuthDelegate: authentication)), allocator: channel.allocator, inboundChildChannelInitializer: { child, type in
                                guard let commands = authentication.sessionCommands, commands.isAuthorized() else { diagnostics.record(.authorizationRevoked, connection: connectionID); return child.eventLoop.makeFailedFuture(SSHError.unsupportedChannel) }
                                guard children.insert(child) else { diagnostics.record(.channelCapacity, connection: connectionID); return child.eventLoop.makeFailedFuture(SSHError.capacity) }
                                guard sessions.insert(child) else { diagnostics.record(.sessionCapacity, connection: connectionID); children.remove(child); return child.eventLoop.makeFailedFuture(SSHError.capacity) }
                                child.closeFuture.whenComplete { _ in sessions.remove(child); children.remove(child) }
                                if case .directTCPIP(let destination) = type {
                                    return openTunnel(channel: child, host: destination.targetHost, port: destination.targetPort, commands: commands)
                                }
                                guard case .session = type else { diagnostics.record(.unsupportedChannel, connection: connectionID); return child.eventLoop.makeFailedFuture(SSHError.unsupportedChannel) }
                                return child.eventLoop.makeCompletedFuture {
                                    try child.pipeline.syncOperations.addHandler(ShellHandler(commands: commands))
                                }
                            }),
                            CloseOnError(diagnostics, connectionID),
                        ])
                    }
                }.bind(host: host, port: port).get()
            return KilnSSHServer(group: group, channel: channel, sessions: sessions, connections: connections)
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
        for connection in connections.drain() { try? await connection.close().get() }
        try? await group.shutdownGracefully()
    }
}
