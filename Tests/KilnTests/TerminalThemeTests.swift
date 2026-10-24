import Testing
import KilnTerminal
import KilnKit

private func themeCommand(_ command: String, in ui: inout KilnTerminal) -> [TerminalEffect] {
    _ = ui.handle(.text(command))
    return ui.handle(.enter)
}

@Test func terminalBrandColorsCoverDashboardChatAndNarrowSidebar() {
    var ui = KilnTerminal()
    #expect(ui.render().contains("\u{1b}[48;5;0m"))
    #expect(ui.render().contains("\u{1b}[38;5;46m"))
    #expect(!ui.render().contains("38;5;215m"))
    _ = ui.handle(.text("`"))
    #expect(themeCommand("ai", in: &ui).isEmpty)
    for width in [50, 80, 120] {
        ui.resize(width: width, height: 30)
        #expect(ui.render().contains("\u{1b}[48;5;0m"))
        #expect(ui.render().contains("\u{1b}[38;5;46m"))
    }
}

@Test func terminalThemeCommandsStayLocalAndRejectInvalidColors() {
    var ui = KilnTerminal()
    _ = ui.handle(.text("`"))
    #expect(themeCommand("theme custom 51 16 255 244", in: &ui) == [.command("theme custom 51 16 255 244")])
    ui.applyTheme(TerminalTheme.parse(["custom", "51", "16", "255", "244"])!)
    ui.finish(text: "Theme saved", status: 0)
    #expect(!ui.busy)
    #expect(ui.render().contains("\u{1b}[48;5;16m"))
    #expect(ui.render().contains("\u{1b}[38;5;51m"))
    for invalid in ["theme custom 999 0 252 245", "theme custom 46 46 252 245", "theme custom 46 0 252", "theme unknown"] {
        #expect(themeCommand(invalid, in: &ui).isEmpty)
        #expect(!ui.busy)
        #expect(ui.render().contains("\u{1b}[38;5;51m"))
    }
    #expect(themeCommand("theme default", in: &ui) == [.command("theme default")])
    ui.applyTheme(TerminalTheme()); ui.finish(text: "Theme saved", status: 0)
    #expect(ui.render().contains("\u{1b}[38;5;46m"))
    #expect(KilnTerminal().render().contains("\u{1b}[38;5;46m"))
}

@Test func chatThemeDoesNotSendProviderRequests() {
    var ui = KilnTerminal()
    _ = ui.handle(.text("`")); _ = themeCommand("ai", in: &ui)
    #expect(themeCommand("/theme cyan", in: &ui) == [.command("theme cyan")])
    ui.applyTheme(TerminalTheme.parse(["cyan"])!); ui.finish(text: "Theme saved", status: 0)
    #expect(ui.chatVisible && !ui.busy)
    #expect(ui.render().contains("\u{1b}[38;5;51m"))
    #expect(themeCommand("/theme green", in: &ui) == [.command("theme green")])
    ui.applyTheme(TerminalTheme()); ui.finish(text: "Theme saved", status: 0)
    #expect(ui.render().contains("\u{1b}[38;5;46m"))
}
