import Foundation
import Testing
@testable import KilnWeb
import KilnKit
import KilnRuntime
import KilnCommands
@testable import KilnDevelopment

private struct WelcomeView: View {
    let name: String
    let items: [String]
    var body: some View {
        Main {
            H1("Hello, \(name)")
            if !items.isEmpty {
                Section {
                    for item in items { Paragraph(item) }
                }.cssClass("cards")
            }
            Link("Home",href:"/?q=\"&").aria("current","page")
            Input(name:"name",value:name).attribute(.required,"")
            Button("Update").onClick("rename")
        }.id("content").cssClass("page").padding(12).background("var(--bg)")
    }
}
@Test func nativeSwiftViewsComposeEscapeDataAndKeepCSSCustomizable() throws {
    let view = WelcomeView(name:"<img src=x onerror=alert(1)>",items:["A&B","<second>"])
    let html = view.render().rendered
    #expect(html.contains("&lt;img src=x onerror=alert(1)&gt;"))
    #expect(!html.contains("<img"))
    #expect(html.contains("<p>A&amp;B</p><p>&lt;second&gt;</p>"))
    #expect(html.contains("class=\"page kiln-style-"))
    let stylePattern = try NSRegularExpression(pattern:#"href="(/__kiln/style/[^" ]+)""#)
    let styleMatch = try #require(stylePattern.firstMatch(in:html,range:NSRange(html.startIndex...,in:html)))
    let stylePath = String(html[Range(styleMatch.range(at:1),in:html)!])
    #expect(ViewStyles.stylesheet(stylePath)?.contains("padding:12px;background:var(--bg)") == true)
    #expect(ViewStyles.stylesheet(stylePath.replacingOccurrences(of:".css",with:"a.css")) == nil)
    #expect(html.contains("href=\"/?q=&quot;&amp;\""))
    #expect(html.contains("data-kiln-click=\"rename\""))
    #expect(!html.contains("</input>"))
    #expect(TemplateValue.text("<guest>").render().rendered == "&lt;guest&gt;")
    #expect(throws:TemplateValueError.self) { try TemplateValue.view("<b>unsafe in attribute</b>").attribute() }
    let response = WebResponse.view(view,status:201)
    #expect(response.status == 201 && response.body == Data(html.utf8))
    let empty = WelcomeView(name:"Swift",items:[]).render().rendered
    #expect(!empty.contains("<section"))
    let doc = Document(title:"A&B") { view; Text("<safe>") }.rendered
    #expect(doc.hasPrefix("<!doctype html><html lang=\"en\">"))
    #expect(doc.contains("<title>A&amp;B</title>")); #expect(doc.contains("&lt;safe&gt;"))
}
@Test func templatesGenerateOnlyRegisteredViewsAndRejectMalformedOrExecutableSlots() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:root) }
    let template = "<h1>{{ name }}</h1><div>{{content}}</div>\n\\(fatalError())\u{1}"
    let output = try WebTemplateCompiler.write(["Views/Home/index.html":Data(template.utf8),"Assets/ignored.html":Data("ignored".utf8)],at:root)
    let generated = try #require(output)
    let swift = try String(contentsOf:generated,encoding:.utf8)
    #expect(swift.contains("case \"Home/index\"")); #expect(!swift.contains("ignored"))
    #expect(swift.contains("values[\"name\"]")); #expect(swift.contains("\\\\(fatalError())"))
    #expect(swift.contains("\\u{1}"))
    for source in ["{{invalid-name}}","<script>{{value}}</script>","<STYLE>{{value}}</STYLE>","<div data-x={{value}}>","<p style=\"{{value}}\">", "<p onclick=\"{{value}}\">"] {
        #expect(throws:(any Error).self) { try WebTemplateCompiler.write(["Views/Bad.html":Data(source.utf8)],at:root) }
    }
    #expect(try WebTemplateCompiler.write(["Outside.html":Data("{{bad-name}}".utf8)],at:root) == nil)
}

@Test func nativeViewsAndHTMLTemplatesCompileTogetherAndHaveLanguageServiceSupport() async throws {
    guard let sdk = ProcessInfo.processInfo.environment["KILN_MVC_SDK"], WebIsolation.supported else { return }
    let root = URL(fileURLWithPath:WebIsolation.canonical(FileManager.default.temporaryDirectory.path)).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:root) }
    let source = """
    import KilnWeb
    struct Home: View {
        var body: some View { H1("Native Swift"); Paragraph("CSS stays customizable").cssClass("intro") }
    }
    @main struct App {
        static func main() throws {
            let fragment = try AppTemplates.render("Home/greeting",values:["name":.text("<guest>"),"content":.view(Home().render())])
            print(WebResponse.view(fragment).status)
        }
    }
    """
    let files = WebFiles(files:["App.swift":Data(source.utf8),"Views/Home/greeting.html":Data("<h1>{{name}}</h1>{{content}}".utf8)])
    try files.writeSources(at:root.appendingPathComponent("source"))
    let config = WebProjectConfiguration(schemaVersion:1,module:"mvc/test",source:root.appendingPathComponent("source/App.swift").path,sdk:sdk,publicOrigin:"http://127.0.0.1:18085",ingressPort:18085,workerPorts:[18084,18086],autoPublish:true,root:root.appendingPathComponent("source").path)
    let manifest = ApplicationManifest(application:"mvc",name:"test",version:"initial",executable:"/usr/bin/false",healthURL:"http://127.0.0.1:18084/health",ingressPort:18085)
    let dev = WebDevelopment(directory:root)
    _ = try await dev.register(data:JSONEncoder().encode(config),target:manifest)
    let hash = WebIsolation.digest(Data(source.utf8))
    let built = try await dev.ide(module:"mvc/test",request:SwiftIDERequest(action:"build",path:"App.swift",sha256:hash,text:source,cursor:0))
    #expect(built.message.contains("Build passed"))
    let draft = source.replacingOccurrences(of:"AppTemplates.render",with:"AppTemplates.re")
    let cursor = draft.distance(from:draft.startIndex,to:draft.range(of:"AppTemplates.re")!.upperBound)
    let result = try await dev.ide(module:"mvc/test",request:SwiftIDERequest(action:"complete",path:"App.swift",sha256:hash,text:draft,cursor:cursor))
    #expect(result.completions.contains { $0.label.contains("render") })
    let template = files.files["Views/Home/greeting.html"]!
    let invalidTemplate = try await dev.ide(module:"mvc/test",request:SwiftIDERequest(action:"build",path:"Views/Home/greeting.html",sha256:WebIsolation.digest(template),text:"<script>{{name}}</script>",cursor:0))
    #expect(invalidTemplate.message.contains("Build failed"))
    #expect(try WebFiles.read(config) == files)
}

@Test func administratorPatchImportRejectsOversizedFilesSymlinksAndUnrecognizedIdentity() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let runtime = try KilnRuntime(stateDirectory:root)
    defer { try? FileManager.default.removeItem(at:root) }
    let commands = KilnCommands(runtime:runtime)
    let patch = root.appendingPathComponent("patch.json")
    try KilnStateFile.write(Data(repeating:65,count:262145),to:patch)
    let oversized = await commands.execute("web apply-file demo/web "+patch.path)
    #expect(oversized.status != 0 && oversized.text.contains("256 KiB"))
    let link = root.appendingPathComponent("link.json")
    try FileManager.default.createSymbolicLink(at:link,withDestinationURL:patch)
    let symlink = await commands.execute("web apply-file demo/web "+link.path)
    #expect(symlink.status != 0 && symlink.text.contains("symbolic link"))
    let denied = await commands.forIdentity(name:"unrecognized",publicKey:"invalid").execute("web apply-file demo/web /does-not-exist")
    #expect(denied.status != 0 && !denied.text.contains("Patch file unavailable"))
    await runtime.shutdown()
}
