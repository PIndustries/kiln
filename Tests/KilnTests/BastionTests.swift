import Foundation
import Testing
import KilnBastion

@Test func destinationPolicyPersistsAndFailsClosed() async throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:directory)}
    let bastion=KilnBastion(directory:directory)
    #expect(try await !bastion.allowForward(host:"127.0.0.1",port:22))
    _=try await bastion.add(name:"dev",host:"127.0.0.1",user:"alice",port:2222)
    #expect(try await bastion.allowForward(host:"127.0.0.1",port:2222))
    #expect(try await !bastion.allowForward(host:"127.0.0.1",port:22))
    #expect(try await !bastion.allowForward(host:"localhost",port:2222))
    let restored=KilnBastion(directory:directory)
    #expect(try await restored.profile("dev").user == "alice")
    _=try await restored.remove("dev")
    #expect(try await !restored.allowForward(host:"127.0.0.1",port:2222))
}

@Test func rejectsOptionAndPathInjection() throws {
    for host in ["-oProxyCommand=evil","host;touch","example.com/path","*.example.com","host\nother"] {
        #expect(throws:(any Error).self) {try KilnBastion.validate(name:"dev",host:host,user:"alice",port:22)}
    }
    #expect(throws:(any Error).self) {try KilnBastion.validate(name:"../escape",host:"localhost",user:"alice",port:22)}
    #expect(throws:(any Error).self) {try KilnBastion.validate(name:"dev",host:"localhost",user:"-root",port:22)}
}
