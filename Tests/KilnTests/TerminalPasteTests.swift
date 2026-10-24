import Testing
import KilnTerminal

@Test func pastedUnicodeRespectsComposerByteLimitWithoutSplittingCharacters() {
    var ui = KilnTerminal()
    _ = ui.handle(.text("`"))
    _ = ui.handle(.paste(String(repeating: "🚀", count: 2000)))
    #expect(ui.input.utf8.count == 4096)
    #expect(ui.input == String(repeating: "🚀", count: 1024))
    _ = ui.handle(.paste("a"))
    #expect(ui.input.utf8.count == 4096)
    _ = ui.handle(.backspace)
    _ = ui.handle(.paste("ééé"))
    #expect(ui.input.hasSuffix("éé") && ui.input.utf8.count == 4096)
}

@Test func pastedUnicodeFitsRemainingSpaceAtCursorAndKeepsSanitization() {
    var ui = KilnTerminal()
    _ = ui.handle(.text("`"))
    _ = ui.handle(.text(String(repeating: "x", count: 4094)))
    _ = ui.handle(.home)
    _ = ui.handle(.paste("éa"))
    #expect(ui.input.hasPrefix("éx") && ui.input.utf8.count == 4096)
    _ = ui.handle(.backspace)
    #expect(ui.input == String(repeating: "x", count: 4094))
    _ = ui.handle(.interrupt)
    _ = ui.handle(.paste("status\nexit\u{1b}\u{7}"))
    #expect(ui.input == "status exit")
    _ = ui.handle(.interrupt)
    let largeCharacter = "a" + String(repeating: "\u{301}", count: 3000)
    #expect(largeCharacter.count == 1)
    _ = ui.handle(.paste(largeCharacter))
    #expect(ui.input.isEmpty)
}


@Test func composerKeepsCursorValidWhenInputJoinsExistingGraphemes() {
    for pasted in [false, true] {
        var ui = KilnTerminal()
        _ = ui.handle(.text("`")); _ = ui.handle(.text("eX"))
        _ = ui.handle(.home); _ = ui.handle(.right)
        _ = ui.handle(pasted ? .paste("\u{301}") : .text("\u{301}"))
        _ = ui.handle(.text("y"))
        #expect(ui.input == "éyX")
        _ = ui.handle(.backspace)
        #expect(ui.input == "éX")
        _ = ui.handle(.backspace)
        #expect(ui.input == "X")
    }
    var flags = KilnTerminal()
    _ = flags.handle(.text("`")); _ = flags.handle(.text("🇺 🇸"))
    _ = flags.handle(.home); _ = flags.handle(.right); _ = flags.handle(.delete)
    _ = flags.handle(.text("!"))
    #expect(flags.input == "🇺🇸!")
}


@Test func oversizedBracketedPasteNeverExecutesTrailingPayloadAsKeys() {
    var decoder = TerminalKeys()
    #expect(decoder.feed(Array("\u{1b}[200~".utf8)).isEmpty)
    #expect(decoder.feed(Array(String(repeating: "a", count: 17000).utf8)).isEmpty)
    #expect(decoder.feed(Array("\nexit\r\u{3}\u{4}\u{1b}[20".utf8)).isEmpty)
    let ended = decoder.feed(Array("1~".utf8))
    #expect(ended == [.paste(String(repeating: "a", count: 16384))])
    #expect(decoder.feed(Array("status\r".utf8)) == "status".map { .text(String($0)) } + [.enter])
}
