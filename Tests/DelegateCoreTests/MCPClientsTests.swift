import Foundation
import Testing
@testable import DelegateCore

@Suite struct MCPClientsTests {
    @Test(arguments: MCPClient.allCases)
    func addDetectRemove(_ client: MCPClient) throws {
        let added = try MCPClientConfig.updating(nil, for: client, command: "/usr/local/bin/delegate")
        #expect(MCPClientConfig.registeredCommand(in: added, for: client) == "/usr/local/bin/delegate")

        let removed = try MCPClientConfig.updating(added, for: client, command: nil)
        #expect(MCPClientConfig.registeredCommand(in: removed, for: client) == nil)
    }

    @Test(arguments: MCPClient.allCases)
    func preservesUnrelatedKeys(_ client: MCPClient) throws {
        let original = Data(#"{"unrelated":{"kept":true},"another":42}"#.utf8)
        let updated = try MCPClientConfig.updating(original, for: client, command: "delegate")
        let root = try #require(JSONSerialization.jsonObject(with: updated) as? [String: Any])
        let unrelated = try #require(root["unrelated"] as? [String: Any])
        #expect(unrelated["kept"] as? Bool == true)
        #expect(root["another"] as? Int == 42)
    }

    @Test func zedRefusesJSONC() throws {
        let jsonc = Data("{\n  // Zed comment\n  \"trailing\": true\n}".utf8)
        #expect(throws: DelegateError.self) {
            try MCPClientConfig.updating(jsonc, for: .zed, command: "delegate")
        }
    }
}
