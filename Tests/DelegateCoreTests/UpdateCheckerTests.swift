import Foundation
import Testing
@testable import DelegateCore

struct UpdateCheckerTests {
    let releaseBody = #"""
    {"tag_name":"v0.3.0","html_url":"https://github.com/lakafior/delegate-mcp/releases/tag/v0.3.0","body":"- nowe",
     "assets":[{"name":"Delegate-0.3.0.dmg.sha256","browser_download_url":"https://github.com/x/Delegate-0.3.0.dmg.sha256"},
               {"name":"Delegate-0.3.0.dmg","browser_download_url":"https://github.com/x/Delegate-0.3.0.dmg"}]}
    """#

    @Test func versionComparison() {
        #expect(UpdateChecker.isVersion("0.3.0", newerThan: "0.2.0"))
        #expect(UpdateChecker.isVersion("0.10.0", newerThan: "0.9.1"))
        #expect(UpdateChecker.isVersion("1.0", newerThan: "0.9.9"))
        #expect(!UpdateChecker.isVersion("0.2.0", newerThan: "0.2.0"))
        #expect(!UpdateChecker.isVersion("0.2", newerThan: "0.2.0"))
        #expect(!UpdateChecker.isVersion("0.1.9", newerThan: "0.2.0"))
        #expect(!UpdateChecker.isVersion("0.2.0-beta", newerThan: "0.2.0"))
    }

    @Test func parsesLatestReleaseAndPicksDmg() async throws {
        let t = MockTransport(["api.github.com": .init(status: 200, body: releaseBody)])
        let release = try #require(try await UpdateChecker(transport: t).newerRelease(than: "0.2.0"))
        #expect(release.version == "0.3.0")
        #expect(release.notes == "- nowe")
        #expect(release.dmgURL?.lastPathComponent == "Delegate-0.3.0.dmg")
        #expect(t.calls.first?.url?.path == "/repos/lakafior/delegate-mcp/releases/latest")
    }

    @Test func currentVersionMeansNoUpdate() async throws {
        let t = MockTransport(["api.github.com": .init(status: 200, body: releaseBody)])
        #expect(try await UpdateChecker(transport: t).newerRelease(than: "0.3.0") == nil)
    }

    @Test func httpErrorThrows() async {
        let t = MockTransport(["api.github.com": .init(status: 403, body: #"{"message":"rate limit"}"#)])
        await #expect(throws: ProviderError.self) { try await UpdateChecker(transport: t).latest() }
    }
}
