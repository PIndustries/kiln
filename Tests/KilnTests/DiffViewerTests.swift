import Foundation
import Testing
@testable import KilnTerminal

private func diffHistory() throws -> String {
    String(decoding: try JSONEncoder().encode((0..<2).map {
        ["id":"change-\($0)", "version":"\($0)", "status":"active", "created":"2026-10-25", "commit":"git-\($0)"]
    }), as: UTF8.self)
}
@Test func diffColorsBelongToSourceLinesAndSurviveWrapping() throws {
    var viewer = ManagementUI()
    _ = viewer.changeHistory("demo/web"); viewer.finish(text: try diffHistory(), status: 0)
    #expect(viewer.handle(.enter, width: 80, height: 35) == "'web' 'diff' 'demo/web' 'change-0'")
    viewer.finish(text: "--- Before.swift\n+++ App.swift\n@@ -1 +1 @@\n-" + String(repeating: "old", count: 40) + "\n+" + String(repeating: "new", count: 40) + "\n unchanged context", status: 0)
    let output = viewer.render(width: 80, height: 35)
    #expect(output.components(separatedBy: ";38;5;203m| ").count-1 == 2)
    #expect(output.components(separatedBy: ";38;5;114m| ").count-1 == 2)
    #expect(output.contains(";38;5;81m| --- Before.swift"))
    #expect(output.contains(";38;5;81m| +++ App.swift"))
    #expect(output.contains("unchanged context"))
    #expect(output.contains("Left/Right"))
}
@Test func diffBrowserMovesBetweenVersionsAndReturnsToSelectionWithoutExtraMenus() throws {
    var viewer = ManagementUI()
    _ = viewer.changeHistory("demo/web"); viewer.finish(text: try diffHistory(), status: 0)
    #expect(viewer.handle(.enter, width: 100, height: 30) == "'web' 'diff' 'demo/web' 'change-0'")
    viewer.finish(text: "+first", status: 0)
    #expect(viewer.handle(.left, width: 100, height: 30) == nil)
    #expect(viewer.handle(.right, width: 100, height: 30) == "'web' 'diff' 'demo/web' 'change-1'")
    viewer.finish(text: "+second", status: 0)
    #expect(viewer.render(width: 100, height: 30).contains("Source diff 2/2"))
    #expect(viewer.handle(.escape, width: 100, height: 30) == nil)
    #expect(viewer.render(width: 100, height: 30).contains("Changes / demo/web"))
    #expect(viewer.handle(.enter, width: 100, height: 30) == "'web' 'diff' 'demo/web' 'change-1'")
    viewer.finish(text: "+second", status: 0)
    #expect(viewer.handle(.text("r"), width: 100, height: 30) == nil)
    #expect(viewer.render(width: 100, height: 30).contains("Restore source"))
    // The initial choice is Cancel: Enter must not publish accidentally.
    #expect(viewer.handle(.enter, width: 100, height: 30) == "'web' 'diff' 'demo/web' 'change-1'")
    viewer.finish(text: "+second", status: 0)
    _ = viewer.handle(.text("r"), width: 100, height: 30)
    _ = viewer.handle(.down, width: 100, height: 30)
    #expect(viewer.handle(.enter, width: 100, height: 30) == "'web' 'restore' 'demo/web' 'change-1'")
    viewer.finish(text: "Restored as a new release", status: 0)
    #expect(viewer.handle(.enter, width: 100, height: 30) == "'web' 'history' 'demo/web'")
}
