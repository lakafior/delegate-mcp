import Foundation
import Testing
@testable import DelegateCore

/// Edycja `~/.codex/config.toml` dla serwera `delegate`: wpis musi być tekstowy, żeby reszta pliku
/// (inne tabele, komentarze, kolejność) zostawała bez zmian.
@Suite struct CodexMCPConfigTests {

    @Test func configURLInCodexDirectory() {
        let url = CodexMCPConfig.configURL
        #expect(url.lastPathComponent == "config.toml")
        #expect(url.path.hasSuffix("/.codex/config.toml"))
    }

    @Test func emptyFile() {
        #expect(CodexMCPConfig.registeredCommand(in: "") == nil)
        let withEntry = CodexMCPConfig.updating("", command: "/opt/delegate-mcp")
        #expect(withEntry == "[mcp_servers.delegate]\ncommand = \"/opt/delegate-mcp\"\n")
        #expect(CodexMCPConfig.registeredCommand(in: withEntry) == "/opt/delegate-mcp")
        #expect(CodexMCPConfig.updating(withEntry, command: nil) == "")
        #expect(CodexMCPConfig.updating("", command: nil) == "")
    }

    @Test func otherTablesAndCommentsStayUntouched() {
        let original = """
        # Codex configuration

        model = "gpt-5"
        sandbox_mode = "workspace-write"

        [mcp_servers.delegate]
        command = "/opt/delegate-mcp"
        args = ["--stdio"]

        # Built-in servers
        [mcp_servers.browser]
        command = "browser"
        """ + "\n"
        let replaced = CodexMCPConfig.updating(original, command: "/new/delegate-mcp")
        #expect(replaced == """
        # Codex configuration

        model = "gpt-5"
        sandbox_mode = "workspace-write"

        [mcp_servers.delegate]
        command = "/new/delegate-mcp"

        # Built-in servers
        [mcp_servers.browser]
        command = "browser"
        """ + "\n")
        let removed = CodexMCPConfig.updating(replaced, command: nil)
        #expect(removed == """
        # Codex configuration

        model = "gpt-5"
        sandbox_mode = "workspace-write"

        # Built-in servers
        [mcp_servers.browser]
        command = "browser"
        """ + "\n")
        // Po usunięciu wpis wraca dopisany na koniec, po pustej linii.
        let readded = CodexMCPConfig.updating(removed, command: "/new/delegate-mcp")
        #expect(readded == removed + "\n[mcp_servers.delegate]\ncommand = \"/new/delegate-mcp\"\n")
    }

    @Test func replacesEntryWithSubTable() {
        let original = """
        model = "gpt-5"

        [mcp_servers.delegate]
        command = "/old/delegate-mcp"

        [mcp_servers.delegate.env]
        DELEGATE_HOME = "/Users/mar"

        [mcp_servers.shell]
        command = "shell"
        """ + "\n"
        #expect(CodexMCPConfig.registeredCommand(in: original) == "/old/delegate-mcp")
        let replaced = CodexMCPConfig.updating(original, command: "/new/delegate-mcp")
        #expect(replaced == """
        model = "gpt-5"

        [mcp_servers.delegate]
        command = "/new/delegate-mcp"

        [mcp_servers.shell]
        command = "shell"
        """ + "\n")
        #expect(CodexMCPConfig.registeredCommand(in: replaced) == "/new/delegate-mcp")
        #expect(CodexMCPConfig.updating(original, command: nil) == """
        model = "gpt-5"

        [mcp_servers.shell]
        command = "shell"
        """ + "\n")
    }

    @Test func escapesSpaceQuoteAndBackslash() {
        let path = "/Users/mar/My Tools/we\"ird\\name/delegate-mcp"
        let text = CodexMCPConfig.updating("", command: path)
        #expect(text == "[mcp_servers.delegate]\ncommand = \"/Users/mar/My Tools/we\\\"ird\\\\name/delegate-mcp\"\n")
        #expect(CodexMCPConfig.registeredCommand(in: text) == path)
    }

    @Test func detectsCommand() {
        let typical = """
        # Codex
        model = "gpt-5"

        [mcp_servers.delegate]
        command = "/opt/delegate-mcp"  # stdio binary
        args = []

        [mcp_servers.other]
        command = "/opt/other"
        """
        #expect(CodexMCPConfig.registeredCommand(in: typical) == "/opt/delegate-mcp")
        #expect(CodexMCPConfig.registeredCommand(in: "model = \"gpt-5\"\n") == nil)
        #expect(CodexMCPConfig.registeredCommand(in: "[mcp_servers.other]\ncommand = \"/opt/other\"\n") == nil)
        #expect(CodexMCPConfig.registeredCommand(in: "[mcp_servers.delegate]\ncommands = \"/nope\"\n") == nil)
        #expect(CodexMCPConfig.registeredCommand(in: "[mcp_servers.delegate]\ncommand = '/opt/literal'\n") == "/opt/literal")
    }
}
