import Foundation
import Testing
@testable import DelegateCore

/// `check`: kryterium akceptacji jak u seniora, który odsyła pracę, aż testy przejdą.
@Suite(.enabled(if: AgentSandbox.isAvailable)) struct CheckTests {
    private func runner() throws -> CheckRunner {
        CheckRunner(home: DelegateHome(directory: try tempDir("home")), userHome: try tempDir("user"))
    }

    @Test func passFailAndTimeout() async throws {
        let dir = try tempDir("check")
        let r = try runner()
        let ok = await r.run("echo fine && test -d .", in: dir)
        #expect(ok.passed && ok.output == "fine" && ok.line == "✓ check `echo fine && test -d .` passed")
        let bad = await r.run("echo broken >&2; exit 3", in: dir)
        #expect(!bad.passed && bad.exitCode == 3 && bad.output == "broken")
        let slow = await r.run("sleep 5", in: dir, timeout: 1)
        #expect(!slow.passed && slow.output.contains("stopped after 1 s") && slow.seconds < 4)
    }

    @Test func sandboxBlocksNetworkKeychainAndWritesOutside() async throws {
        // Katalog tymczasowy użytkownika (/var/folders/…/T) jest zapisywalny celowo (cache budowania); /tmp nie.
        let dir = try tempDir("check"), outside = URL(fileURLWithPath: "/private/tmp/delegate-check-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let r = try runner()
        #expect(await r.run("echo x > inside.txt", in: dir).passed)
        #expect(!(await r.run("echo x > \(outside.path)/leak.txt", in: dir).passed))
        #expect(!(await r.run("/usr/bin/curl -sS -m 5 -o /dev/null https://example.com", in: dir).passed))
        #expect(!(await r.run("/usr/bin/security find-generic-password -s com.mar.delegate", in: dir).passed))
    }

    @Test func failedCheckGoesBackToTheSameModel() async throws {
        let dir = try tempDir("out")
        let out = dir.appendingPathComponent("pl.json").path
        let t = GeminiThinkingTests.SequenceTransport([
            .init(status: 200, body: #"{"choices":[{"message":{"content":"{\"a\": 1,}"}}],"usage":{"prompt_tokens":10,"completion_tokens":3}}"#),
            .init(status: 200, body: #"{"choices":[{"message":{"content":"{\"a\": 1}"}}],"usage":{"prompt_tokens":10,"completion_tokens":3}}"#),
        ])
        let cfg = Config(providers: [ProviderConfig(id: "mistral", kind: .openai, baseURL: "https://api.mistral.ai/v1",
                                                    apiKeyEnv: "MISTRAL_API_KEY",
                                                    models: [ModelConfig(id: "small"), ModelConfig(id: "large")])])
        let log = UsageLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID()).jsonl"))
        let svc = DelegateService(loadConfig: { cfg }, secrets: FixedSecrets(values: ["MISTRAL_API_KEY": "m"]), transport: t,
                                  onDevice: FakeOnDevice(), usage: log, checks: try runner())
        let check = "/usr/bin/python3 -m json.tool pl.json > /dev/null"
        let text = try await svc.delegate(.init(prompt: "Translate", model: "mistral/large", outputFile: out, check: check))
        #expect(text.hasPrefix("[delegate] model: mistral/large"))
        #expect(text.contains("✓ check `\(check)` passed after 1 fix · \(out): 1 lines"))
        #expect(!text.contains("Preview"))   // dyrygent nie dostaje treści, tylko wynik
        #expect(t.bodies.count == 2)
        #expect(t.bodies[1]["model"] as? String == "large")
        let second = ((t.bodies[1]["messages"] as? [[String: Any]])?.last?["content"] as? String) ?? ""
        #expect(second.contains("failed the acceptance check") && second.contains(#"{"a": 1,}"#))

        await #expect(throws: DelegateError.self) {
            try await svc.delegate(.init(prompt: "x", check: "true"))   // bez output_file nie ma czego sprawdzać
        }
    }
}
