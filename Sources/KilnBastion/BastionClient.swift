import Foundation
import KilnKit

public final class BastionClient: Sendable {
    private let directory: URL
    private let connection: ServiceConnection
    public init(directory: URL) { self.directory = directory; connection = ServiceConnection(path:SessionService.socketPath(directory:directory)) }
    public func start() async throws {
        if let version: String = try? await connection.request(.init(op:"ping")) {
            guard version == "kiln-session-service/1" else { throw KilnError.message("Session service protocol mismatch; explicit service upgrade required") }; return
        }
        let executable = URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL
        let process = Process(); process.executableURL = executable
        process.arguments = ["session-service", "--state", directory.path]
        process.standardInput = FileHandle.nullDevice
        let log = directory.appendingPathComponent("session-service.log")
        if !FileManager.default.fileExists(atPath:log.path) { FileManager.default.createFile(atPath:log.path,contents:nil,attributes:[.posixPermissions:0o600]) }
        let output = try FileHandle(forWritingTo:log); try output.seekToEnd()
        process.standardOutput = output; process.standardError = output
        try process.run(); try? output.close()
        for _ in 0..<50 {
            if let version: String = try? await connection.request(.init(op:"ping")), version == "kiln-session-service/1" { return }
            try await Task.sleep(for:.milliseconds(100))
        }
        throw KilnError.message("Session service did not become ready; inspect session-service.log")
    }
    private func call<T: Decodable & Sendable>(_ op:String,_ args:[String] = [], as:T.Type = T.self) async throws -> T {
        try await connection.request(.init(op:op,args:args))
    }
    public func stop() async throws -> String { try await call("stop") }
    public func serverSnapshots() async throws -> [ServerSnapshot] { try await call("servers") }
    public func sessionSnapshots() async throws -> [TerminalSessionSnapshot] { try await call("sessions") }
    public func add(name:String,host:String,user:String,port:Int) async throws -> String { try await call("add",[name,host,user,String(port)]) }
    public func edit(name:String,host:String,user:String,port:Int) async throws -> String { try await call("edit",[name,host,user,String(port)]) }
    public func remove(_ name:String) async throws -> String { try await call("remove",[name]) }
    public func profile(_ name:String) async throws -> ServerProfile { try await call("profile",[name]) }
    public func allowForward(host:String,port:Int) async throws -> Bool { try await call("allow",[host,String(port)]) }
    public func list() async throws -> String { try await call("list") }
    public func keys() async throws -> String { try await call("keys") }
    public func createKey(_ name:String) async throws -> String { try await call("createKey",[name]) }
    public func publicKey(_ name:String) async throws -> String { try await call("publicKey",[name]) }
    public func deleteKey(_ name:String) async throws -> String { try await call("deleteKey",[name]) }
    public func assign(server:String,key:String) async throws -> String { try await call("assign",[server,key]) }
    public func generateKey(server:String,name:String) async throws -> String { try await call("generateKey",[server,name]) }
    public func scan(_ name:String) async throws -> String { try await call("scan",[name]) }
    public func trust(_ name:String,fingerprint:String) async throws -> String { try await call("trust",[name,fingerprint]) }
    public func execute(_ name:String,command:String) async throws -> RemoteResult { try await call("execute",[name,command]) }
    public func createSession(name:String,server:String) async throws -> String { try await call("new",[name,server]) }
    public func renameSession(_ name:String,to replacement:String) async throws -> String { try await call("rename",[name,replacement]) }
    public func closeSession(_ name:String) async throws -> String { try await call("close",[name]) }
    public func session(_ name:String) async throws -> RemoteTerminalClient {
        guard try await sessionSnapshots().contains(where:{$0.name == name}) else { throw KilnError.message("Unknown session") }
        return RemoteTerminalClient(name:name,path:connection.path)
    }
}
public final class RemoteTerminalClient: Sendable {
    public let name: String
    private let connection: ServiceConnection
    init(name:String,path:String) { self.name = name; connection = ServiceConnection(path:path) }
    public func attach(owner:UUID,width:Int,height:Int) async throws {
        let _:String = try await connection.request(.init(op:"attach",args:[name],owner:owner,width:width,height:height))
    }
    public func detach(owner:UUID) { connection.fire(.init(op:"detach",args:[name],owner:owner)) }
    public func send(_ bytes:[UInt8],owner:UUID) { connection.fire(.init(op:"send",args:[name],owner:owner,bytes:Data(bytes))) }
    public func resize(width:Int,height:Int,owner:UUID) { connection.fire(.init(op:"resize",args:[name],owner:owner,width:width,height:height)) }
    public func frame(owner:UUID,after revision:UInt64?) async -> RemoteTerminalFrame? {
        do { return try await connection.request(.init(op:"frame",args:[name],owner:owner,revision:revision)) }
        catch { return RemoteTerminalFrame(revision:.max,text:"Session unavailable: \(error)") }
    }
}
