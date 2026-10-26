import Foundation
import KilnKit

/// File tree and editor share the same registered-project commands as the AI.
struct WorkspaceUI {
    let module: String
    let change: String?
    var active = true
    private var proposalReview: AgentReviewUI?
    private var agentFile: AISourcePreview?
    private var followingAgent = true
    private var agentOffset = 0, agentHorizontal = 0
    mutating func showAgentFile(_ file: AISourcePreview) {
        guard file.module == module else { return }
        if agentFile?.path != file.path { agentOffset = 0; agentHorizontal = 0 }
        agentFile = file
    }
    mutating func clearAgentFile() { agentFile = nil }
    mutating func endAgent() { agentFile = nil; followingAgent = true }

    private struct Entry: Decodable { let path: String; let sha256: String; let bytes: Int }
    private struct Tree: Decodable { let version: String; let editable: Bool; let projectRoot: Bool; let files: [Entry] }
    private struct File: Decodable { let file: String; let sha256: String; let source: String; let version: String }
    private struct Browse: Decodable { let tree: Tree; let file: File; let workspace: CodeWorkspaceRecord?; let worker: AIWorkSnapshot?; let recoveryNotice: String? }
    private var entries: [Entry] = []
    private var selected = 0
    private var path = "App.swift", hash = "", source = "", version = ""
    private var editable = false, projectRoot = false, treeFocus = true, waiting = true
    private var mode = "browse", pending = "browse", error = "", receipt = "", newPath = "", draft = "", isNew = false
    private var confirmation = "", accepted = false
    private var refactorChoice = 2
    private var publishingDraft = false, recoverableDraft = false
    private var refactorFailed = false, returnToSource = false
    private var sourceOffset = 0
    private var offset = 0, horizontal = 0, cursor = 0
    private var wrapping = false
    private var vim = VimEditor()
    private var queuedLanguageRead: SwiftIDERequest?
    private var publishAfterLanguageRead = false
    private var idePending: SwiftIDERequest?
    private var ideResult: SwiftIDEResult?
    private var autoCompletionReady = false
    private var automaticCompletion = false
    private var automaticDiagnostics = false
    private var diagnosticsReady = false
    private var diagnostics: [SwiftIDELocation] = []
    private var renameName = ""
    private var toolbar: [(String,TerminalKey)] {
        [("[Build]",.build),("[Run]",.run),("[Def]",.definition),("[Fmt F2]",.format),("[Fix F3]",.codeActions),("[Wrap]",.wrap),("[Complete]",.complete),("["+vim.label+"]",.vim),("[Refs F9]",.references),("[Rename F10]",.rename),("[Issues F4]",.diagnostics),("[Proposals Ctrl-P]",.agentReview)]
    }
    private var ideIndex = 0
    private var jump: SwiftIDELocation?
    private struct Buffer { var source: String; var draft: String; var hash: String; var cursor: Int; var offset: Int; var horizontal: Int; var isNew: Bool }
    private var buffers: [String:Buffer] = [:]
    private var savedWorkspace: CodeWorkspaceRecord?
    private var sentCheckpoint: CodeWorkspaceState?
    var checkpointPending: Bool { sentCheckpoint != nil }
    private var recoveryFailure = ""
    private var restoredDivider: Int?
    mutating func takeRestoredDivider() -> Int? { defer { restoredDivider = nil }; return restoredDivider }
    private(set) var reattachWorker: AIWorkSnapshot?
    mutating func takeWorkerToAttach() -> AIWorkSnapshot? { defer { reattachWorker = nil }; return reattachWorker }
    mutating func checkpoint(dividerShare: Int) -> String? {
        guard change == nil, let saved = savedWorkspace, sentCheckpoint == nil, recoveryFailure.isEmpty else { return nil }
        var value = CodeWorkspaceState()
        value.path = path; value.cursor = cursor; value.offset = offset; value.horizontal = horizontal
        value.wrapping = wrapping; value.vim = vim.enabled; value.treeFocus = treeFocus; value.dividerShare = dividerShare
        value.buffers = buffers.mapValues { CodeWorkspaceBuffer(source:$0.source,draft:$0.draft,sha256:$0.hash,cursor:$0.cursor,offset:$0.offset,horizontal:$0.horizontal,isNew:$0.isNew) }
        if (mode == "edit" || mode == "rename" || recoverableDraft || publishingDraft), isNew || draft != source {
            value.buffers[path] = CodeWorkspaceBuffer(source:source,draft:draft,sha256:hash,cursor:cursor,offset:offset,horizontal:horizontal,isNew:isNew)
        }
        guard value != saved.state, let bytes = try? JSONEncoder().encode(CodeWorkspaceSave(expectedRevision:saved.revision,state:value)) else { return nil }
        sentCheckpoint = value
        return command(["web","workspace-save",module,String(decoding:bytes,as:UTF8.self)])
    }
    mutating func finishCheckpoint(text: String, status: Int) {
        guard let sent = sentCheckpoint else { return }
        sentCheckpoint = nil
        guard status == 0, let result = try? JSONDecoder().decode(CodeWorkspaceRecord.self,from:Data(text.utf8)),
              result.id == savedWorkspace?.id, result.module == module, result.state == sent else {
            recoveryFailure = "Recovery save stopped: " + text; return
        }
        savedWorkspace = result
    }
    private mutating func restore(_ record: CodeWorkspaceRecord) {
        savedWorkspace = record; restoredDivider = record.state.dividerShare
        wrapping = record.state.wrapping; vim.enabled = record.state.vim; treeFocus = record.state.treeFocus
        buffers = record.state.buffers.mapValues { Buffer(source:$0.source,draft:$0.draft,hash:$0.sha256,cursor:$0.cursor,offset:$0.offset,horizontal:$0.horizontal,isNew:$0.isNew) }
        if path == record.state.path { cursor = min(record.state.cursor,source.count); offset = record.state.offset; horizontal = record.state.horizontal }
        if let value = buffers.removeValue(forKey:record.state.path) {
            let changed = path != record.state.path || hash != value.hash
            path = record.state.path; source = value.source; draft = value.draft; hash = value.hash; cursor = value.cursor
            offset = value.offset; horizontal = value.horizontal; isNew = value.isNew; mode = "edit"
            if changed { error = "Recovered draft has a different source base. Compare before publishing; no source was overwritten." }
        }
        for (name,value) in record.state.buffers where !entries.contains(where: { $0.path == name }) {
            entries.append(Entry(path:name,sha256:value.sha256,bytes:value.draft.utf8.count))
        }
        entries.sort { $0.path < $1.path }; selected = entries.firstIndex { $0.path == path } ?? 0
    }
    private mutating func retainBuffer() {
        if mode == "edit", isNew || draft != source {
            buffers[path] = Buffer(source:source,draft:draft,hash:hash,cursor:cursor,offset:offset,horizontal:horizontal,isNew:isNew)
            if isNew, !entries.contains(where: { $0.path == path }) { entries.append(Entry(path:path,sha256:"",bytes:draft.utf8.count)); entries.sort { $0.path < $1.path } }
        }
    }
    private mutating func openNewBuffer(_ name: String) -> Bool {
        guard let value = buffers[name], value.isNew else { return false }
        retainBuffer(); buffers.removeValue(forKey:name)
        path = name; source = value.source; draft = value.draft; hash = value.hash; cursor = value.cursor
        offset = value.offset; horizontal = value.horizontal; isNew = true; mode = "edit"
        selected = entries.firstIndex(where: { $0.path == name }) ?? 0
        return true
    }
    private mutating func swiftTool(_ action: String, background: Bool = false) -> String? {
        guard change == nil, (path.hasSuffix(".swift") || action == "build"), !waiting, idePending == nil else { return nil }
        if action == "complete", mode != "edit" {
            guard editable else { return nil }; draft = source; isNew = false; mode = "edit"
            offset = min(offset, String(source.prefix(cursor)).filter { $0 == "\n" }.count)
        }
        let value = languageRequest(action)
        guard let data = try? JSONEncoder().encode(value), let json = String(data:data,encoding:.utf8) else { return nil }
        idePending = value
        if !background { ideResult = nil; error = "Swift "+action+"..." }
        return command(["web","ide",module,json])
    }
    private func languageRequest(_ action: String, at position: Int? = nil) -> SwiftIDERequest {
        SwiftIDERequest(action:action,path:path,sha256:isNew && mode == "edit" ? "" : hash,text:mode == "edit" ? draft : source,cursor:position ?? cursor,buffers:buffers.mapValues { SwiftIDEBuffer(sha256:$0.isNew ? "" : $0.hash,text:$0.draft) },newName:action == "rename" ? renameName : nil)
    }
    mutating func takeDeferredLanguageRead() -> String? {
        guard proposalReview == nil, let queued = queuedLanguageRead, idePending == nil, !waiting, confirmation.isEmpty else { return nil }
        queuedLanguageRead = nil
        let current = languageRequest(queued.action,at:["build","diagnostics","format"].contains(queued.action) ? queued.cursor : nil)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard (try? encoder.encode(queued)) == (try? encoder.encode(current)) else {
            error = "Queued Swift request cancelled because the editor changed; request it again."; return nil
        }
        return swiftTool(queued.action)
    }
    /// Called after a short idle period, never once per keystroke.
    mutating func completeAfterTyping() -> String? {
        guard proposalReview == nil, !waiting, autoCompletionReady, mode == "edit", !treeFocus, confirmation.isEmpty,
              !vim.enabled || vim.insert, idePending == nil, ideResult == nil else { return nil }
        autoCompletionReady = false
        let command = swiftTool("complete"); automaticCompletion = command != nil; return command
    }
    mutating func diagnoseAfterTyping() -> String? {
        guard proposalReview == nil, diagnosticsReady, mode == "edit", confirmation.isEmpty, !waiting, idePending == nil else { return nil }
        diagnosticsReady = false
        let command = swiftTool("diagnostics",background:true); automaticDiagnostics = command != nil; return command
    }
    private mutating func openLocation(_ location: SwiftIDELocation) -> String? {
        ideResult = nil
        if location.path != path {
            if openNewBuffer(location.path) { position(at:location); return nil }
            retainBuffer(); jump = location
            return request("file",["web","file",module,location.path])
        }
        position(at:location)
        return nil
    }
    private mutating func position(at location: SwiftIDELocation) {
        let text = mode == "edit" ? draft : source, rows = text.components(separatedBy:"\n")
        let line = min(max(0,location.line-1),rows.count-1)
        let column = min(max(0,location.column-1),rows[line].utf16.count)
        let utf16 = rows[line].utf16.index(rows[line].utf16.startIndex,offsetBy:column)
        let index = String.Index(utf16,within:rows[line]) ?? rows[line].startIndex
        cursor = rows.prefix(line).reduce(0){$0+$1.count+1}+rows[line].distance(from:rows[line].startIndex,to:index)
        offset = max(0,line-2); horizontal = max(0,column-12); treeFocus = false
    }
    init(module: String, change: String? = nil) { self.module = module; self.change = change }
    private func command(_ parts: [String]) -> String { parts.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ") }
    var reviewingAgent: Bool { proposalReview != nil }
    var canBrowseDuringTurn: Bool { proposalReview != nil || (mode == "browse" && confirmation.isEmpty) }
    var filePath: String { followingAgent && !hasUnsavedEdits ? agentFile?.path ?? path : path }
    var hasUnsavedEdits: Bool { (["edit","rename"].contains(mode) && (isNew || draft != source)) || recoverableDraft || publishingDraft || buffers.values.contains { $0.isNew || $0.draft != $0.source } }
    var contextJSON: String? { contextJSON(width:120) }
    func contextJSON(width: Int) -> String? {
        guard !hash.isEmpty, !waiting, mode != "receipt", mode != "name" else { return nil }
        if let review = proposalReview?.fileContext {
            let context = ["module":module,"path":review.1 == "missing" ? path : review.0,"sha256":review.1 == "missing" ? hash : review.1,"revision":"workspace","unsaved":hasUnsavedEdits ? "true" : "false","firstVisibleLine":String(review.2),"reviewWorker":review.3]
            return (try? JSONEncoder().encode(context)).map { String(decoding:$0,as:UTF8.self) }
        }
        let shown = followingAgent && !hasUnsavedEdits ? agentFile : nil
        let context: [String: String] = ["module": module, "path": shown?.path ?? path, "sha256": shown == nil ? hash : "",
            "revision": change ?? "workspace", "unsaved": hasUnsavedEdits || shown?.draft == true ? "true" : "false",
            "firstVisibleLine": String(shown != nil ? agentOffset+1 : wrapping ? (visualRows(width:width).dropFirst(offset).first?.0 ?? 0)+1 : offset+1)]
        guard let data = try? JSONEncoder().encode(context) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    mutating func refresh() -> String? {
        guard proposalReview == nil, !waiting, idePending == nil, ideResult == nil, !hasUnsavedEdits, mode == "browse" else { return nil }
        return request("refresh", ["web", "browse", module, path] + (change.map { [$0] } ?? []))
    }
    func load() -> String { command(["web", change == nil ? "workspace" : "browse", module, "App.swift"] + (change.map { [$0] } ?? [])) }
    private mutating func request(_ name: String, _ parts: [String]) -> String {
        if ["file","browse","refresh"].contains(name) { queuedLanguageRead = nil; publishAfterLanguageRead = false; if confirmation == "publish" { confirmation = "" } }
        waiting = true; pending = name; error = ""; return command(parts)
    }
    mutating func finish(text: String, status: Int) {
        if pending == "agent-review", proposalReview != nil, idePending == nil {
            proposalReview?.finish(text,status:status); return
        }
        if pending == "agent-stage", proposalReview != nil, idePending == nil {
            guard status == 0,
                  let result = try? JSONDecoder().decode(SwiftIDEResult.self,from:Data(text.utf8)),
                  let proposed = result.renameFiles, let filePath = proposed.keys.first, let file = proposed[filePath] else {
                proposalReview?.failedStage(status == 0 ? "Invalid proposed file response; local drafts preserved" : text); return
            }
            let selectedDirty = filePath == path && ["edit","rename"].contains(mode) && (isNew || draft != source)
            let storedDirty = buffers[filePath].map { $0.isNew || $0.draft != $0.source } ?? false
            guard !selectedDirty, !storedDirty else {
                proposalReview?.failedStage("This file already has local edits. They were preserved; choose another file or review those edits first."); return
            }
            var staged = buffers
            if mode == "edit", isNew || draft != source {
                staged[path] = Buffer(source:source,draft:draft,hash:hash,cursor:cursor,offset:offset,horizontal:horizontal,isNew:isNew)
            }
            staged[filePath] = Buffer(source:file.source,draft:file.text,hash:file.sha256,cursor:0,offset:0,horizontal:0,isNew:file.sha256.isEmpty)
            guard staged.count <= 32, staged.values.reduce(0,{ $0+$1.source.utf8.count+$1.draft.utf8.count }) <= 524288 else {
                proposalReview?.failedStage("Recovery storage limit reached. Existing drafts were preserved; save or export them before staging another file."); return
            }
            buffers = staged; buffers.removeValue(forKey:filePath)
            proposalReview = nil; waiting = false; followingAgent = false
            path = filePath; source = file.source; draft = file.text; hash = file.sha256
            isNew = hash.isEmpty; mode = "edit"; treeFocus = false; cursor = 0; offset = 0; horizontal = 0
            if !entries.contains(where: { $0.path == path }) { entries.append(Entry(path:path,sha256:hash,bytes:draft.utf8.count)); entries.sort { $0.path < $1.path } }
            selected = entries.firstIndex(where: { $0.path == path }) ?? 0
            error = "Agent proposal staged locally. Review/edit, Build, then Ctrl-D publish."; return
        }
        let previousSource = source, previousPath = path
        defer { if source != previousSource || path != previousPath { diagnostics = []; diagnosticsReady = true } }
        if let query = idePending {
            defer {
                if publishAfterLanguageRead {
                    publishAfterLanguageRead = false
                    if mode == "edit", editable { ideResult = nil; openPublicationReview() }
                }
            }
            let automatic = automaticCompletion
            let backgroundDiagnostics = automaticDiagnostics
            automaticCompletion = false
            automaticDiagnostics = false
            idePending = nil; error = ""
            guard status == 0, let data = text.data(using:.utf8), let result = try? JSONDecoder().decode(SwiftIDEResult.self,from:data) else { if !automatic && !backgroundDiagnostics { error = text }; return }
            let openBuffers = buffers.mapValues { SwiftIDEBuffer(sha256:$0.isNew ? "" : $0.hash,text:$0.draft) }
            guard (query.buffers ?? [:]) == openBuffers, query.path == path, query.text == (mode == "edit" ? draft : source), query.action == "diagnostics" || query.action == "format" || query.cursor == cursor, !automatic || (!treeFocus && (!vim.enabled || vim.insert) && confirmation.isEmpty) else { if !automatic && !backgroundDiagnostics { error = "Swift result belongs to an earlier buffer. Request it again." }; return }
            if result.action == "diagnostics" { diagnostics = result.locations; if backgroundDiagnostics { return } }
            if automatic && result.completions.isEmpty { return }
            ideResult = result; ideIndex = 0
            return
        }
        waiting = false
        if pending == "refactor", status != 0 || text.hasPrefix("Web change failed or unconfirmed") {
            // Keep the source/tree usable; retain the complete failure for review.
            // Never replay a failed or uncertain write automatically.
            mode = "browse"; receipt = text; refactorFailed = true
            error = "Refactor failed. V details: " + (text.components(separatedBy:"\n").first ?? "Inspect history before another write.")
            return
        }
        if pending == "run" { mode = "receipt"; receipt = text; offset = 0; return }
        if pending == "apply" || pending == "refactor" {
            refactorFailed = false
            recoverableDraft = pending == "apply" && publishingDraft && status != 0
            publishingDraft = false
            if status == 0 { buffers.removeAll() }
            mode = "receipt"; receipt = text; offset = 0
            error = status == 0 ? "" : "Change failed or unconfirmed. Inspect history and release before another write."
            return
        }
        guard status == 0, let data = text.data(using: .utf8) else { error = text; return }
        do {
            let file: File
            var restoration: CodeWorkspaceRecord?
            if pending == "browse" || pending == "refresh" {
                let view = try JSONDecoder().decode(Browse.self, from: data)
                entries = view.tree.files; editable = view.tree.editable; projectRoot = view.tree.projectRoot; file = view.file
                if pending == "browse" { restoration = view.workspace; reattachWorker = view.worker; error = view.recoveryNotice ?? "" }
                for (name,value) in buffers where value.isNew && !entries.contains(where: { $0.path == name }) { entries.append(Entry(path:name,sha256:"",bytes:value.draft.utf8.count)) }
                entries.sort { $0.path < $1.path }
            } else { file = try JSONDecoder().decode(File.self, from: data) }
            let keepPosition = pending == "refresh" && path == file.file
            path = file.file; hash = file.sha256; source = file.source; version = file.version
            selected = entries.firstIndex(where: { $0.path == path }) ?? 0
            vim.reset()
            mode = "browse"
            if !keepPosition { offset = 0; horizontal = 0; cursor = 0 }
            if let buffer = buffers.removeValue(forKey:path) {
                let changed = buffer.hash != hash
                source = buffer.source; draft = buffer.draft; hash = buffer.hash; cursor = buffer.cursor
                offset = buffer.offset; horizontal = buffer.horizontal; isNew = buffer.isNew; mode = "edit"
                if changed { error = "File changed on disk; original draft retained. Review before publishing." }
            }
            if let restoration { restore(restoration) }
            if vim.enabled, editable, mode == "browse" { draft = source; mode = "edit"; isNew = false; treeFocus = false }
            if let location = jump { jump = nil; position(at:location) }
        } catch { self.error = "Invalid project browser response" }
    }
    private mutating func openPublicationReview() {
        guard isNew || draft != source || !buffers.isEmpty else { error = "No changes to publish"; return }
        confirmation = "publish"; accepted = false
    }
    private mutating func publish(delete: Bool = false) -> String? {
        let operation: [String:String]
        if delete { operation = ["path":path,"action":"delete","sha256":hash] }
        else if isNew { operation = ["path":path,"action":"create","content":draft] }
        else { operation = ["path":path,"action":"replace","sha256":hash,"content":draft] }
        var operations = buffers.filter { $0.key != path && ($0.value.isNew || $0.value.draft != $0.value.source) }.sorted(by:{$0.key < $1.key}).map { name,value in
            value.isNew ? ["path":name,"action":"create","content":value.draft] : ["path":name,"action":"replace","sha256":value.hash,"content":value.draft]
        }
        operations.append(operation)
        guard let data = try? JSONEncoder().encode(operations), let json = String(data:data,encoding:.utf8) else { return nil }
        publishingDraft = !delete && mode == "edit"
        return request("apply",["web","apply",module,json])
    }
    private func visualRows(width: Int) -> [(Int,Int)] {
        let lines = (mode == "edit" ? draft : source).components(separatedBy:"\n"), room = max(1,codeWidth(width))
        return lines.enumerated().flatMap { index,line in
            let count = KilnTerminal.safe(line).replacingOccurrences(of:"\t",with:"    ").count
            return wrapping ? stride(from:0,to:max(1,count),by:room).map { (index,$0) } : [(index,horizontal)]
        }
    }
    private func codeWidth(_ width: Int) -> Int { let w = width-4; return w-min(32,max(18,w/4))-11 }
    private mutating func scroll(_ delta: Int = 0, across: Int = 0, width: Int, height: Int) {
        if wrapping && across != 0 { return }
        let lines = (mode == "edit" ? draft : source).components(separatedBy:"\n")
        offset = min(max(0,visualRows(width:width).count-max(1,height-8)),max(0,offset+delta))
        let longest = lines.map { KilnTerminal.safe($0).replacingOccurrences(of:"\t",with:"    ").count }.max() ?? 0
        horizontal = min(max(0,longest-max(1,codeWidth(width))),max(0,horizontal+across))
    }
    private mutating func revealCaret(width: Int, height: Int) {
        let before = Array(draft.prefix(cursor)), sourceLine = before.filter { $0 == "\n" }.count
        let visible = max(1,height-8)
        let rawColumn = String(before.reversed().prefix(while: { $0 != "\n" }).reversed()).replacingOccurrences(of:"\t",with:"    ").count
        let line = wrapping ? visualRows(width:width).lastIndex(where: { $0.0 == sourceLine && $0.1 <= rawColumn }) ?? 0 : sourceLine
        if line < offset { offset = line }; if line >= offset+visible { offset = line-visible+1 }
        let column = rawColumn
        let room = max(8,(width-4)-min(32,max(18,(width-4)/4))-11)
        if !wrapping { if column < horizontal { horizontal = column }; if column >= horizontal+room { horizontal = column-room+1 } }
    }
    private mutating func openRefactor() {
        guard editable && projectRoot && path.hasSuffix(".swift") else { error = "Refactor requires a current Swift file in a registered project root"; return }
        mode = "refactor"; refactorChoice = 2; error = ""
    }
    private func receiptLines(width: Int) -> [String] {
        let room = max(1,width-8)
        return (error.isEmpty ? receipt : error+"\n"+receipt).components(separatedBy:"\n").flatMap { line -> [String] in
            var remaining = KilnTerminal.safe(line).replacingOccurrences(of:"\t",with:"    "), rows: [String] = []
            repeat { rows.append(String(remaining.prefix(room))); remaining = String(remaining.dropFirst(room)) } while !remaining.isEmpty
            return rows
        }
    }
    private let scrollButtons = "[PgUp] [PgDn] [Top] [End] [<] [>]"
    mutating func handle(_ input: TerminalKey, width: Int, height: Int) -> String? {
        if proposalReview != nil {
            if let action = proposalReview?.handle(input,width:width,height:height) {
                switch action {
                case .read(let parts): pending = "agent-review"; return command(parts)
                case .stage(let parts): pending = "agent-stage"; return command(parts)
                }
            }
            if proposalReview?.active == false { proposalReview = nil }
            return nil
        }
        if input == .agentReview {
            guard !waiting, idePending == nil, confirmation.isEmpty, mode == "browse" || mode == "edit" else { error = "Finish the current editor action before reviewing proposals"; return nil }
            followingAgent = false; proposalReview = AgentReviewUI(module:module); pending = "agent-review"
            return command(["web","agents",module])
        }
        let previousDraft = draft, previousPath = path
        defer { if draft != previousDraft || path != previousPath { diagnosticsReady = true; diagnostics = [] } }
        autoCompletionReady = false
        if input == .followAgent { followingAgent.toggle(); return nil }
        if followingAgent, let file = agentFile, !hasUnsavedEdits {
            var preview = self
            preview.agentFile = nil; preview.source = file.source; preview.path = file.path
            preview.mode = "browse"; preview.treeFocus = false
            preview.offset = agentOffset; preview.horizontal = agentHorizontal
            switch input {
            case .up,.down,.left,.right,.pageUp,.pageDown,.home,.end,.panLeft,.panRight,.wrap:
                _ = preview.handle(input,width:width,height:height)
                agentOffset = preview.offset; agentHorizontal = preview.horizontal; wrapping = preview.wrapping; return nil
            case let .mouse(button,_,_,_) where button & 64 != 0:
                _ = preview.handle(input,width:width,height:height)
                agentOffset = preview.offset; agentHorizontal = preview.horizontal; return nil
            default: followingAgent = false // User navigation takes precedence over auto-follow.
            }
        }
        var key = input
        guard !waiting else { return nil }
        if key == .diagnostics, idePending?.action == "diagnostics" {
            automaticDiagnostics = false; ideResult = nil; error = "Swift diagnostics..."; return nil
        }
        if mode == "rename" {
            if key == .escape { mode = "edit"; renameName = ""; return nil }
            if key == .backspace, !renameName.isEmpty { renameName.removeLast() }
            if case .text(let text) = key, renameName.utf8.count+text.utf8.count <= 128 { renameName += text }
            if key == .enter { mode = "edit"; return swiftTool("rename") }
            return nil
        }
        if case let .mouse(button,column,row,released) = key, !released, button == 0, row == 1 {
            var left = 3
            for (label,action) in toolbar {
                if (left..<left+label.count).contains(column), column < width-1 { ideResult = nil; return handle(action,width:width,height:height) }
                left += label.count+1
            }
        }
        if key == .vim, confirmation.isEmpty, ideResult == nil, mode == "browse" || mode == "edit" {
            vim.enabled.toggle(); vim.reset()
            if vim.enabled, editable {
                if mode != "edit" { draft = source; isNew = false; mode = "edit" }
                let before = String(draft.prefix(cursor))
                position(at:SwiftIDELocation(path:path,line:before.components(separatedBy:"\n").count,column:(before.components(separatedBy:"\n").last?.utf16.count ?? 0)+1))
            }
            error = ""; return nil
        }
        if key == .panLeft || key == .panRight {
            scroll(across:key == .panLeft ? -8 : 8,width:width,height:height); return nil
        }
        if [.format,.codeActions,.build,.definition,.complete,.run,.references,.rename,.diagnostics].contains(key) { ideResult = nil }
        if key == .wrap {
            let rows = visualRows(width:width), line = rows.indices.contains(offset) ? rows[offset].0 : 0
            wrapping.toggle(); horizontal = 0
            offset = visualRows(width:width).firstIndex(where: { $0.0 == line }) ?? 0
            return nil
        }
        if let result = ideResult {
            if result.action == "complete" {
                switch key { case .text, .paste, .backspace, .delete: ideResult = nil; return handle(key,width:width,height:height); default: break }
            }
            let count = result.action == "complete" ? result.completions.count : result.action == "codeActions" ? (result.codeActions?.count ?? 0) : result.locations.count
            if key == .escape { ideResult = nil; return nil }
            if key == .up { ideIndex = max(0,ideIndex-1) }
            if key == .down || (key == .tab && result.action != "complete") { ideIndex = min(max(0,count-1),ideIndex+1) }
            if result.action == "complete", case let .mouse(button,_,_,released) = key, !released, button == 0 {
                ideResult = nil; return handle(key,width:width,height:height)
            }
            if case let .mouse(button,_,row,released) = key, !released {
                if button == 64 { ideIndex = max(0,ideIndex-1) }
                if button == 65 { ideIndex = min(max(0,count-1),ideIndex+1) }
                let start = max(0,ideIndex-max(1,height-13)+1)
                if button == 0, row >= 7, row < height-5, start+row-7 < count { ideIndex = start+row-7; return handle(.enter,width:width,height:height) }
            }
            if key == .enter || (key == .tab && result.action == "complete") {
                let action = result.action == "codeActions" ? result.codeActions.flatMap { $0.indices.contains(ideIndex) ? $0[ideIndex] : nil } : nil
                if let disabled = action?.disabledReason { error = disabled; ideResult = nil; return nil }
                if ["rename","format","codeActions"].contains(result.action), let proposed = action?.files ?? result.renameFiles {
                    vim.record(mode == "edit" ? draft : source,cursor)
                    retainBuffer()
                    for (name,file) in proposed {
                        buffers[name] = Buffer(source:file.source,draft:file.text,hash:file.sha256,cursor:0,offset:0,horizontal:0,isNew:file.sha256.isEmpty)
                    }
                    if let selected = buffers.removeValue(forKey:path) {
                        source = selected.source; draft = selected.draft; hash = selected.hash; cursor = min(cursor,draft.count); mode = "edit"
                    }
                    ideResult = nil; error = (result.action == "rename" ? "Rename" : result.action == "format" ? "Formatting" : "Compiler action")+" applied to drafts. Review files; Ctrl-D publishes the complete change."; return nil
                }
                if result.action == "complete", result.completions.indices.contains(ideIndex) {
                    let item = result.completions[ideIndex]; var chars = Array(draft)
                    guard item.start >= 0, item.end >= item.start, item.end <= chars.count else { ideResult = nil; return nil }
                    chars.replaceSubrange(item.start..<item.end,with:item.text)
                    guard String(chars).utf8.count <= 65536 else { error = "Completion exceeds file limit"; ideResult = nil; return nil }
                    vim.record(draft,cursor)
                    draft = String(chars); cursor = item.start+item.text.count; ideResult = nil
                    revealCaret(width:width,height:height)
                    return nil
                }
                if result.locations.indices.contains(ideIndex) { return openLocation(result.locations[ideIndex]) }
                ideResult = nil
            }
            return nil
        }
        if idePending != nil {
            if key == .escape, publishAfterLanguageRead || queuedLanguageRead != nil { publishAfterLanguageRead = false; queuedLanguageRead = nil; error = ""; return nil }
            if let action = key.swiftLanguageAction {
                publishAfterLanguageRead = false; queuedLanguageRead = languageRequest(action)
                error = "Queued Swift "+action+" until the current request finishes; Esc cancels"; return nil
            }
            if key == .eof, mode == "edit", editable {
                queuedLanguageRead = nil; publishAfterLanguageRead = true; error = "Waiting for Swift tools before publication review; Esc cancels"; return nil
            }
            switch key {
            case .up, .down, .left, .right, .home, .end, .pageUp, .pageDown: break
            case let .mouse(button,_,_,_): if button & 64 == 0 { return nil }
            case .text, .paste, .backspace, .delete, .enter, .tab, .escape: if mode != "edit" { return nil }
            default: return nil
            }
        }
        if mode == "browse", refactorFailed, key == .text("v") || key == .text("V") {
            sourceOffset = offset; offset = 0; returnToSource = true; mode = "receipt"; return nil
        }
        if key == .format || key == .codeActions {
            guard change == nil, editable else { error = "Open the current editable workspace for formatting or compiler fixes"; return nil }
            return swiftTool(key == .format ? "format" : "codeActions")
        }
        if key == .complete { return swiftTool("complete") }
        if key == .definition { return swiftTool("definition") }
        if key == .references { return swiftTool("references") }
        if key == .diagnostics { return swiftTool("diagnostics") }
        if key == .rename {
            guard change == nil, editable, path.hasSuffix(".swift") else { return nil }
            if mode != "edit" { draft = source; isNew = false }
            mode = "rename"; renameName = ""; return nil
        }
        if key == .build { return swiftTool("build") }
        if key == .run {
            guard !hasUnsavedEdits else { error = "Publish drafts with Ctrl-D before running the release"; return nil }
            return request("run",["app","restart",module])
        }
        if mode == "refactor" {
            if key == .escape { mode = "browse"; return nil }
            if key == .up { refactorChoice = (refactorChoice+2)%3 }
            if key == .down || key == .tab { refactorChoice = (refactorChoice+1)%3 }
            if case let .mouse(button,column,row,released) = key, !released, button == 0, column >= 3, column < width-1, (7...9).contains(row) {
                refactorChoice = row-7
                return handle(.enter,width:width,height:height)
            }
            if key == .enter {
                if refactorChoice == 2 { mode = "browse"; return nil }
                return request("refactor",["web","refactor",module,path,hash,refactorChoice == 0 ? "components" : "functions"])
            }
            return nil
        }
        if confirmation.isEmpty, mode == "browse" || mode == "edit", case let .mouse(button,column,row,released) = key, !released {
            if row == 1, button == 0 {
                if (3...9).contains(column) { return handle(.build,width:width,height:height) }
                if (11...15).contains(column) { return handle(.run,width:width,height:height) }
                if (17...21).contains(column) { return handle(.definition,width:width,height:height) }
                if (23...30).contains(column) { return handle(.wrap,width:width,height:height) }
                if (32...41).contains(column) { return handle(.complete,width:width,height:height) }
            }
            let w = width-4, treeWidth = min(32,max(18,w/4)), codeLeft = 3+treeWidth+4
            guard column >= 3, column < width-1, row >= 4, row <= height-2 else { return nil }
            if button & 64 != 0 {
                if column >= codeLeft {
                    treeFocus = false
                    if button & 3 >= 2 || button & 4 != 0 { scroll(across:button & 1 == 0 ? -8 : 8,width:width,height:height) }
                    else { scroll(button & 1 == 0 ? -3 : 3,width:width,height:height) }
                } else if mode == "browse" { treeFocus = true; selected = min(max(0,entries.count-1),max(0,selected+(button & 1 == 0 ? -3 : 3))) }
                return nil
            }
            if button == 0 {
                if mode == "browse", editable, projectRoot, path.hasSuffix(".swift"), row == 4, column >= width-15 { openRefactor(); return nil }
                if row == height-2, column < 5+scrollButtons.count {
                    let position = column-5
                    if (0..<6).contains(position) { scroll(-max(1,height-8),width:width,height:height) }
                    if (7..<13).contains(position) { scroll(max(1,height-8),width:width,height:height) }
                    if (14..<19).contains(position) { offset = 0 }
                    if (20..<25).contains(position) { scroll(Int.max/2,width:width,height:height) }
                    if (26..<29).contains(position) { scroll(across:-8,width:width,height:height) }
                    if (30..<33).contains(position) { scroll(across:8,width:width,height:height) }
                    return nil
                }
                if column >= codeLeft {
                    treeFocus = false
                    if row >= 5, row < height-4 {
                        let text = mode == "edit" ? draft : source, rows = text.components(separatedBy:"\n")
                        let visual = visualRows(width:width), n = min(max(0,offset+row-5),max(0,visual.count-1))
                        if visual.indices.contains(n) {
                            let index = visual[n].0, start = visual[n].1
                            let desired = max(0,column-codeLeft-6)+start
                            var cells = 0, count = 0
                            for char in rows[index] { let size = char == "\t" ? 4 : 1; if cells+size > desired { break }; cells += size; count += 1 }
                            cursor = rows.prefix(index).reduce(0){$0+$1.count+1}+count
                        }
                    }
                }
                else if (mode == "browse" || vim.enabled && !vim.insert), row >= 5, row < height-4 {
                    treeFocus = true
                    let nodes = treeRows, selectedRow = nodes.firstIndex(where: { $0.1 == selected }) ?? 0
                    let index = max(0,selectedRow-max(1,height-10)+1)+row-5
                    if nodes.indices.contains(index), let file = nodes[index].1 { selected = file; return handle(.enter,width:width,height:height) }
                }
                return nil
            }
        }
        if mode == "receipt" {
            if returnToSource, key == .enter || key == .escape {
                returnToSource = false; mode = "browse"; offset = sourceOffset; return nil
            }
            if recoverableDraft, key == .enter || key == .escape || key == .text("d") || key == .text("D") {
                // Keep the original path/hash/new-file intent. Recovery is local,
                // and does not refresh source, rebase, or repeat a publish.
                recoverableDraft = false; mode = "edit"; offset = 0; horizontal = 0; cursor = 0
                error = "Draft recovered. Ctrl-D publish; Esc discard."
                return nil
            }
            if key == .enter { return request("browse", ["web","browse",module,"App.swift"] + (change.map { [$0] } ?? [])) }
            if key == .escape { active = false }
            let last = max(0,receiptLines(width:width).count-max(1,height-8))
            if key == .pageDown { offset = min(last,offset+max(1,height-8)) }
            if key == .pageUp { offset = max(0,offset-max(1,height-8)) }
            if key == .home { offset = 0 }
            if key == .end { offset = last }
            if case let .mouse(button,column,row,released) = key, !released, button & 64 != 0, column >= 3, column < width-1, row >= 5, row < height-3 {
                offset = min(last,max(0,offset+(button & 1 == 0 ? -3 : 3)))
            }
            return nil
        }
        if !confirmation.isEmpty {
            if key == .escape { confirmation = ""; return nil }
            if key == .up || key == .down || key == .tab { accepted.toggle() }
            if key == .enter {
                let operation = confirmation; confirmation = ""
                guard accepted else { return nil }
                if operation == "close" { buffers.removeAll(); mode = "browse"; recoverableDraft = false; publishingDraft = false; active = false; return nil }
                if operation == "discard" { buffers.removeValue(forKey:path); mode = "browse"; draft = ""; recoverableDraft = false; publishingDraft = false; offset = 0; if isNew { return request("browse",["web","browse",module,"App.swift"]) }; return nil }
                return publish(delete: operation == "delete")
            }
            return nil
        }
        if mode == "name" {
            if key == .escape { mode = "browse" }
            if key == .backspace, !newPath.isEmpty { newPath.removeLast() }
            if case .text(let text) = key, newPath.count + text.count <= 180 { newPath += text }
            if case .paste(let text) = key, newPath.count + text.count <= 180, !text.contains("\n") { newPath += text }
            if key == .enter {
                guard !newPath.isEmpty, !entries.contains(where: { $0.path == newPath }) else { error = "Choose a new relative file path"; return nil }
                path = newPath; draft = ""; cursor = 0; offset = 0; horizontal = 0; isNew = true; mode = "edit"; error = ""
            }
            return nil
        }
        if mode == "edit" {
            if vim.enabled, !vim.insert, vim.command == nil {
                if key == .tab { treeFocus.toggle(); return nil }
                if treeFocus {
                    if key == .up || key == .text("k") { selected = max(0,selected-1) }
                    if key == .down || key == .text("j") { selected = min(max(0,entries.count-1),selected+1) }
                    if key == .enter, entries.indices.contains(selected) {
                        if openNewBuffer(entries[selected].path) { treeFocus = false; return nil }
                        retainBuffer(); return request("file",["web","file",module,entries[selected].path])
                    }
                    return nil
                }
            }
            if vim.enabled {
                switch vim.handle(key,text:&draft,cursor:&cursor) {
                case .handled: return nil
                case .notice(let notice): error = notice; return nil
                case .key(let mapped): key = mapped; error = ""
                case .write: key = .eof
                case .quit:
                    if hasUnsavedEdits { error = "Unsaved changes. :w publishes; F7 returns to standard editing." }
                    else { active = false }
                    return nil
                case .wrap(let value): if value != wrapping { return handle(.wrap,width:width,height:height) }; return nil
                case .disable: return handle(.vim,width:width,height:height)
                }
            }
            if key == .pageUp || key == .pageDown { scroll(key == .pageUp ? -max(1,height-8) : max(1,height-8),width:width,height:height); return nil }
            if key == .escape { confirmation = "discard"; accepted = false; return nil }
            if key == .eof { openPublicationReview(); return nil }
            let previousDraft = draft, previousCursor = cursor
            var chars = Array(draft); cursor = min(cursor,chars.count)
            let lineStart = chars[..<cursor].lastIndex(of:"\n").map { $0+1 } ?? 0
            let lineEnd = chars[cursor...].firstIndex(of:"\n") ?? chars.count
            switch key {
            case .text(let text), .paste(let text):
                let safe = String(text.unicodeScalars.filter { $0.value >= 32 || $0.value == 10 || $0.value == 9 })
                guard draft.utf8.count + safe.utf8.count <= 65536 else { error = "File limit is 64 KiB"; return nil }
                chars.insert(contentsOf: safe,at:cursor); cursor += safe.count
            case .enter: if draft.utf8.count < 65536 { chars.insert("\n",at:cursor); cursor += 1 }
            case .tab: if draft.utf8.count+4 <= 65536 { chars.insert(contentsOf:"    ",at:cursor); cursor += 4 }
            case .backspace: if cursor > 0 { chars.remove(at:cursor-1); cursor -= 1 }
            case .delete: if cursor < chars.count { chars.remove(at:cursor) }
            case .left: cursor = max(0,cursor-1)
            case .right: cursor = min(chars.count,cursor+1)
            case .home: cursor = lineStart
            case .end: cursor = lineEnd
            case .up:
                if lineStart > 0 { let end = lineStart-1, start = chars[..<end].lastIndex(of:"\n").map { $0+1 } ?? 0; cursor = min(end,start+cursor-lineStart) }
            case .down:
                if lineEnd < chars.count { let start = lineEnd+1, end = chars[start...].firstIndex(of:"\n") ?? chars.count; cursor = min(end,start+cursor-lineStart) }
            default: break
            }
            if String(chars) != previousDraft { vim.record(previousDraft,previousCursor) }
            draft = String(chars)
            revealCaret(width:width,height:height)
            if draft != previousDraft, !vim.enabled || vim.insert {
                switch key {
                case .text, .backspace, .delete:
                    let last = draft.prefix(cursor).last
                    autoCompletionReady = last.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." } ?? false
                default: break
                }
            }
            return nil
        }
        if key == .text("w") || key == .text("W"), change != nil {
            self = WorkspaceUI(module: module)
            return load()
        }
        if key == .escape {
            if !buffers.isEmpty { confirmation = "close"; accepted = false }
            else { active = false }
            return nil
        }
        if key == .tab { treeFocus.toggle() }
        if treeFocus, key == .up { selected = max(0,selected-1) }
        if treeFocus, key == .down { selected = min(max(0,entries.count-1),selected+1) }
        if treeFocus, key == .enter, entries.indices.contains(selected) {
            if openNewBuffer(entries[selected].path) { return nil }
            retainBuffer(); return request("file",["web","file",module,entries[selected].path] + (change.map { [$0] } ?? [])) }
        if !treeFocus, key == .up { scroll(-1,width:width,height:height) }
        if !treeFocus, key == .down { scroll(1,width:width,height:height) }
        if !treeFocus, key == .left { scroll(across:-8,width:width,height:height) }
        if !treeFocus, key == .right { scroll(across:8,width:width,height:height) }
        if key == .pageDown { scroll(max(1,height-8),width:width,height:height) }
        if key == .pageUp { scroll(-max(1,height-8),width:width,height:height) }
        if key == .home { offset = 0; horizontal = 0 }
        if key == .end { scroll(Int.max/2,width:width,height:height) }
        if key == .text("r") || key == .text("R") { openRefactor(); return nil }
        if key == .text("e") || key == .text("E") {
            guard editable else { error = "Retained versions are read-only. Open Codebase for workspace edits."; return nil }
            // Edit the file shown, not a different highlighted tree row.
            draft = source; isNew = false; mode = "edit"; treeFocus = false; error = ""
            offset = min(offset,String(source.prefix(cursor)).filter { $0 == "\n" }.count)
        }
        if key == .text("a") || key == .text("A") {
            guard editable && projectRoot else { error = "Adding files needs an explicitly registered project root"; return nil }
            newPath = ""; mode = "name"; error = ""
        }
        if key == .text("x") || key == .text("X") {
            guard editable && projectRoot && path != "App.swift" else { error = "Only additional workspace files can be deleted"; return nil }
            confirmation = "delete"; accepted = false
        }
        return nil
    }
    private var treeRows: [(String,Int?)] {
        var rows: [(String,Int?)] = [], seen = Set<String>()
        for (index, entry) in entries.enumerated() {
            let parts = entry.path.split(separator:"/").map(String.init)
            for depth in 0..<max(0,parts.count-1) {
                let directory = parts.prefix(depth+1).joined(separator:"/")
                if seen.insert(directory).inserted { rows.append((String(repeating:"  ",count:depth)+"+ "+parts[depth]+"/",nil)) }
            }
            rows.append((String(repeating:"  ",count:parts.count-1)+parts.last!,index))
        }
        return rows
    }
    func render(width: Int, height: Int, theme: TerminalTheme) -> String {
        guard width >= 50, height >= 16 else { return "" }
        if let proposalReview { return proposalReview.render(width:width,height:height,theme:theme) }
        if followingAgent, let file = agentFile, !hasUnsavedEdits {
            var preview = self; preview.agentFile = nil; preview.path = file.path
            preview.source = file.source; preview.mode = "browse"; preview.editable = false
            preview.treeFocus = false; preview.offset = agentOffset; preview.horizontal = agentHorizontal
            preview.ideResult = nil; preview.idePending = nil
            if !preview.entries.contains(where: { $0.path == file.path }) {
                preview.entries.append(Entry(path:file.path,sha256:"",bytes:file.source.utf8.count)); preview.entries.sort { $0.path < $1.path }
            }
            preview.selected = preview.entries.firstIndex(where: { $0.path == file.path }) ?? 0
            preview.error = file.draft ? "AGENT DRAFT - not published | F8 browse your code" : "AGENT READING | F8 browse your code"
            return preview.render(width:width,height:height,theme:theme)
        }
        let w = width-4, h = height-2, left = 3, top = 2, treeWidth = min(32,max(18,w/4)), codeWidth = w-treeWidth-5
        let display = mode == "receipt" ? "" : mode == "edit" ? draft : source
        let lines = display.components(separatedBy:"\n")
        let beforeCursor = String(display.prefix(cursor)), caretLine = beforeCursor.filter { $0 == "\n" }.count
        let caretColumn = (beforeCursor.components(separatedBy:"\n").last ?? "").replacingOccurrences(of:"\t",with:"    ").count
        let visual = visualRows(width:width)
        let start = min(offset,max(0,visual.count-max(1,height-8)))
        var lexer = SourceSyntax(), syntax: [[Int?]] = []
        for line in lines { syntax.append(lexer.colors(KilnTerminal.safe(line).replacingOccurrences(of:"\t",with:"    "),path:path)) }
        func fit(_ value: String, _ count: Int) -> String { String(KilnTerminal.safe(value).prefix(max(0,count))).padding(toLength:max(0,count),withPad:" ",startingAt:0) }
        var out = ""
        func row(_ y: Int, _ value: String) { out += "\u{1b}[\(top+y);\(left)H\u{1b}[0;48;5;\(theme.background);38;5;\(theme.foreground)m" + value + "\u{1b}[0m" }
        row(0,"+"+String(repeating:"-",count:w-2)+"+")
        row(1,"| "+fit("Codebase / \(module) / \(version)\(change == nil ? "" : " / read-only")",w-4)+" |")
        let refactorButton = mode == "browse" && editable && projectRoot && path.hasSuffix(".swift") ? " [R Refactor]" : ""
        row(2,"| "+fit("FILES" + (treeFocus ? " [focus]" : ""),treeWidth)+"| "+fit(path + (mode == "edit" ? " [" + (vim.enabled ? vim.label : "EDITING") + "]" : !treeFocus ? " [focus]" : ""),codeWidth-refactorButton.count)+"\u{1b}[38;5;\(theme.accent)m"+refactorButton+"\u{1b}[38;5;\(theme.foreground)m|")
        if mode != "receipt" {
            let nodes = treeRows
            let selectedRow = nodes.firstIndex(where: { $0.1 == selected }) ?? 0
            let listStart = max(0,selectedRow-max(1,h-8)+1)
            for y in 3..<h-3 {
                let n = y-3, visualIndex = start+n, treeIndex = listStart+n
                let index = visual.indices.contains(visualIndex) ? visual[visualIndex].0 : lines.count
                let across = visual.indices.contains(visualIndex) ? visual[visualIndex].1 : 0
                var label = ""
                if nodes.indices.contains(treeIndex) { label = (nodes[treeIndex].1 == selected ? "> " : "  ") + nodes[treeIndex].0 }
                let treeColor = nodes.indices.contains(treeIndex) && nodes[treeIndex].1 == selected ? theme.accent : theme.foreground
                var body = "| \u{1b}[38;5;\(treeColor)m"+fit(label,treeWidth)+"\u{1b}[38;5;\(theme.foreground)m| "
                if index < lines.count {
                    let safe = KilnTerminal.safe(lines[index]).replacingOccurrences(of:"\t",with:"    ")
                    let content = String(safe.dropFirst(across).prefix(max(1,codeWidth-6)))
                    let active = !treeFocus && index == caretLine
                    let issue = diagnostics.first(where: { $0.path == path && $0.line == index+1 })
                    let gutterColor = issue == nil ? 244 : issue?.message.hasPrefix("error:") == true ? 203 : 220
                    if active { body += "\u{1b}[48;5;234m" }
                    body += "\u{1b}[38;5;\(gutterColor)m"+String(format:"%5d",index+1)+(across > 0 && !safe.isEmpty ? "<" : active ? ">" : issue != nil ? "!" : " ")+"\u{1b}[38;5;\(theme.foreground)m"+SourceSyntax.styled(fit(content,codeWidth-6),colors:Array(syntax[index].dropFirst(min(across,syntax[index].count))),base:theme.foreground)+"\u{1b}[48;5;\(theme.background)m"+(safe.count > across+codeWidth-6 ? ">" : "|")
                } else { body += fit("",codeWidth)+"|" }
                row(y,body)
            }
            let footer = waiting ? "Working..." : !recoveryFailure.isEmpty ? recoveryFailure : !error.isEmpty ? error : mode == "edit" ? vim.enabled ? vim.label+"  i insert  Esc normal  Tab files  :w publish  F7 standard" : "Ctrl-Space complete  F12 def  F11 build  Ctrl-D publish  Esc cancel" : (change == nil ? "Ctrl-P proposals  Wheel scroll  Tab focus  Enter open  E edit  A add  X delete  R refactor  Esc back" : "Read-only revision  W workspace  Tab focus  Enter open  PgUp/Dn  Esc back")
            row(h-3,"| "+fit(footer,w-4)+" |")
            let issueStatus = diagnostics.isEmpty ? "" : "\(diagnostics.count) issues [F4]  "
            row(h-2,"| "+fit(issueStatus+scrollButtons+"  "+(wrapping ? "Wrap ON" : "Wrap OFF")+"  Ln \(caretLine+1):\(caretColumn+1)  ViewCol \(horizontal+1)  Lines \(visual.indices.contains(start) ? visual[start].0+1 : 1)-\(visual.isEmpty ? 1 : visual[min(visual.count-1,start+max(1,height-8)-1)].0+1)/\(lines.count)",w-4)+" |")
        }
        row(h-1,"+"+String(repeating:"-",count:w-2)+"+")
        out += "\u{1b}[1;3H" + theme.accentCode + fit(toolbar.map(\.0).joined(separator:" "),width-5)
        if let result = ideResult, result.action == "complete", !result.completions.isEmpty {
            let count = min(6,result.completions.count), first = max(0,ideIndex-count+1)
            let menuWidth = min(64,max(20,codeWidth-2))
            let caretY = (wrapping ? visual.lastIndex(where: { $0.0 == caretLine && $0.1 <= caretColumn }) ?? 0 : caretLine)-start+3
            let menuY = caretY+count+2 < h-3 ? max(3,caretY+1) : max(3,caretY-count-2)
            let menuX = left+treeWidth+2
            let menuColor = "\u{1b}[0;48;5;234;38;5;\(theme.foreground)m"
            for (i,item) in result.completions.dropFirst(first).prefix(count).enumerated() {
                out += "\u{1b}[\(top+menuY+i);\(menuX)H"+menuColor
                    + (first+i == ideIndex ? "\u{1b}[7m" : "") + fit(item.label,menuWidth)+"\u{1b}[0m"
            }
            row(h-3,"| "+fit("Suggestions: Up/Down choose  Tab/Enter insert  Esc dismiss; keep typing to refine",w-4)+" |")
        } else if let result = ideResult {
            row(3,"| "+fit(result.message.components(separatedBy:"\n").first ?? "Swift tools",w-4)+" |")
            let labels = result.action == "complete" ? result.completions.map { $0.label+"  "+$0.detail } : result.action == "codeActions" ? (result.codeActions ?? []).map { $0.title+($0.disabledReason.map { " [unavailable: "+$0+"]" } ?? "") } : result.locations.map { "\($0.path):\($0.line):\($0.column)  "+$0.message }
            let visible = max(1,height-13), start = max(0,ideIndex-visible+1)
            if labels.isEmpty {
                for (i,line) in result.message.components(separatedBy:"\n").prefix(visible).enumerated() { row(5+i,"| "+fit(line,w-4)+" |") }
            } else {
                for (i,label) in labels.dropFirst(start).prefix(visible).enumerated() {
                    let color = label.contains("error:") ? 203 : label.contains("warning:") ? 220 : theme.foreground
                    row(5+i,"| "+"\u{1b}[38;5;\(color)m"+fit((start+i == ideIndex ? "> " : "  ")+label,w-4)+" |")
                }
            }
            row(h-3,"| "+fit(["rename","format","codeActions"].contains(result.action) ? "Enter applies selected edits to drafts (no publish)  Esc discard" : "Arrows choose  Enter/click open or insert  Esc close",w-4)+" |")
        }
        if mode == "rename" {
            row(4,"| "+fit("Rename symbol at cursor. Changes stay in drafts until you publish.",w-4)+" |")
            row(6,"| "+fit("New Swift name: "+renameName+"_",w-4)+" |")
            row(h-3,"| "+fit("Enter asks SourceKit for a rename proposal  Esc cancel",w-4)+" |")
        }
        if mode == "name" { row(4,"| "+fit("New relative path (Enter to edit, Esc cancel): "+newPath,w-4)+" |") }
        if mode == "receipt" {
            let all = receiptLines(width:width), visible = max(1,height-8)
            let start = min(offset,max(0,all.count-visible))
            for i in 0..<visible {
                row(3+i,"| "+fit(start+i < all.count ? all[start+i] : "",w-4)+" |")
            }
            row(h-3,"| "+fit(waiting ? "Working..." : returnToSource ? "Enter/Esc return to code  PgUp/PgDn details; inspect history before retry" : recoverableDraft ? "Enter/D recover draft  Esc edit  PgUp/PgDn diagnostics" : "Enter refresh files  Esc back  PgUp/PgDn scroll",w-4)+" |")
            row(h-2,"| "+fit("Result lines \(start+1)-\(min(all.count,start+visible))/\(all.count)"+(recoverableDraft ? " | Draft retained in this connection" : ""),w-4)+" |")
        }
        if mode == "refactor" {
            row(4,"| "+fit("AI refactor "+path+" (validates, publishes, retains history)",w-4)+" |")
            for (index, label) in ["Split into smaller components", "One function per file (Swift extensions)", "Cancel"].enumerated() {
                row(5+index,"| "+fit((index == refactorChoice ? "> " : "  ")+label,w-4)+" |")
            }
            row(8,"| "+fit("Up/Down or click  Enter choose  Esc cancel",w-4)+" |")
        }
        if !confirmation.isEmpty {
            let question = confirmation == "close" ? "Discard pending file buffers and close the workspace?" : confirmation == "discard" ? "Discard unsaved edits?" : confirmation == "delete" ? "Delete \(path) and publish? History keeps this file." : "Compile and publish \(path)?"
            row(5,"| "+fit(question,w-4)+" |")
            row(6,"| "+fit(accepted ? "  Cancel     > Confirm" : "> Cancel       Confirm",w-4)+" |")
            row(7,"| "+fit("Up/Down choose  Enter  Esc cancel",w-4)+" |")
        } else if (mode == "edit" || mode == "browse" && !treeFocus), ideResult == nil || ideResult?.action == "complete" {
            let before = String((mode == "edit" ? draft : source).prefix(cursor)), line = before.filter { $0 == "\n" }.count
            let rawColumn = KilnTerminal.safe(String(before.split(separator:"\n",omittingEmptySubsequences:false).last ?? "")).replacingOccurrences(of:"\t",with:"    ").count
            let visualIndex = wrapping ? visual.lastIndex(where: { $0.0 == line && $0.1 <= rawColumn }) ?? 0 : line
            let y = visualIndex-offset
            let column = rawColumn-(wrapping && visual.indices.contains(visualIndex) ? visual[visualIndex].1 : horizontal)
            if y >= 0, y < h-6, column >= 0, column < codeWidth-6 { out += "\u{1b}[\(top+3+y);\(left+treeWidth+10+column)H\u{1b}[?25h" }
        }
        return out
    }
}
