import CryptoKit
import Foundation
import Testing
@testable import DelegateCore

// MARK: atrapa agenta

/// Atrapa agenta ACP: skrypt Pythona mówiący JSON-RPC po stdio. Scenariusz w `FAKE_SCENARIO`:
/// `ok` (sesja, dwa fragmenty odpowiedzi, prośba o zgodę na zapis), `auth` (sesja wymaga logowania),
/// `crash` (wychodzi przy `session/new`), `hang` (nie odpowiada na `session/prompt`).
let fakeAgentScript = #"""
#!/usr/bin/python3 -I
import json, os, sys
scenario = os.environ.get("FAKE_SCENARIO", "ok")
model = "m1"
effort = "default"

def send(m):
    sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()

def read():
    line = sys.stdin.readline()
    return json.loads(line) if line else None

while True:
    m = read()
    if m is None:
        break
    method, mid = m.get("method"), m.get("id")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": 1, "agentCapabilities": {},
            "authMethods": [{"id": "browser-auth", "name": "Sign in"}, {"id": "setup", "name": "Terminal", "type": "terminal", "args": ["--setup"]},
                            {"id": "legacy", "name": "Log in", "_meta": {"terminal-auth": {"command": "/opt/x/login-tool", "args": ["login"], "label": "Login"}}}],
            "agentInfo": {"name": "fake-agent", "title": "Fake Agent", "version": "1.2.3"},
            "echo": m["params"]["clientCapabilities"]}})
    elif method == "session/new":
        if scenario == "crash":
            sys.exit(3)
        if scenario == "auth":
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32000, "message": "Authentication required"}})
        else:
            send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": "s-" + os.path.basename(m["params"]["cwd"]),
                "modes": {"currentModeId": "auto", "availableModes": [{"id": "ask"}, {"id": "auto"}]},
                "configOptions": [{"id": "model", "category": "model", "currentValue": "m1",
                                   "options": [{"value": "m1"}, {"value": "m2"}]},
                                  {"id": "effort", "category": "thought_level", "currentValue": "default",
                                   "options": [{"value": "default"}, {"value": "low"}, {"value": "high"}]}]}})
    elif method == "authenticate":
        send({"jsonrpc": "2.0", "id": mid, "result": {}} if m["params"].get("methodId") == "browser-auth"
             else {"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": "unknown method id"}})
    elif method in ("session/set_config_option", "session/set_mode"):
        p = m["params"]
        if p.get("configId") == "model":
            model = p["value"]
        if p.get("configId") == "effort":
            effort = p["value"]
        send({"jsonrpc": "2.0", "id": mid, "result": {}})
    elif method == "session/prompt":
        if scenario == "hang":
            continue
        sid = m["params"]["sessionId"]
        text = m["params"]["prompt"][0]["text"]
        def chunk(t):
            send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {
                "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": t}}}})
        if scenario == "probe":
            out = []
            try: out.append("read:" + open("notes.txt").read().strip())
            except Exception: out.append("read:fail")
            try:
                open("x.txt", "w").write("x"); out.append("write:ok")
            except Exception: out.append("write:blocked")
            out.append("env:" + ("yes" if os.path.exists(".env") else "no"))
            secret = os.environ.get("FAKE_SECRET")
            if secret:
                try: open(secret).read(); out.append("secret:read")
                except Exception: out.append("secret:blocked")
            try:
                open(os.path.join(os.environ.get("TMPDIR", "/nonexistent"), "t.txt"), "w").write("t"); out.append("tmp:ok")
            except Exception: out.append("tmp:blocked")
            out.append("model:" + model)
            out.append("effort:" + effort)
            out.append("cwd:" + os.getcwd())
            import subprocess
            g = subprocess.run(["/usr/bin/git", "log", "--oneline", "-1"], capture_output=True, text=True)
            out.append("git:" + ("ok" if g.returncode == 0 and "init" in g.stdout else "fail[" + g.stderr.strip().replace(" ", "_")[:300] + "]"))
            chunk(" ".join(out) + " ")
            send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {
                "sessionUpdate": "tool_call", "toolCallId": "t1", "title": "grep notes", "kind": "search", "status": "completed"}}})
            send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {
                "sessionUpdate": "usage_update", "_meta": {"promptTokens": 100, "completionTokens": 7}}}})
        chunk("got: " + text.splitlines()[-1] + "; ")
        send({"jsonrpc": "2.0", "id": "perm-1", "method": "session/request_permission", "params": {
            "sessionId": sid, "toolCall": {"toolCallId": "c1", "kind": os.environ.get("FAKE_PERM_KIND", "edit")},
            "options": [{"optionId": "allow", "name": "Allow", "kind": "allow_once"},
                        {"optionId": "reject", "name": "Reject", "kind": "reject_once"}]}})
        while True:
            r = read()
            if r is None:
                sys.exit(0)
            if r.get("id") == "perm-1":
                break
        chunk("permission: " + r.get("result", {}).get("outcome", {}).get("optionId", "error"))
        send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
    elif mid is not None:
        send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "unknown " + str(method)}})
"""#

let pythonAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")

func tempDir(_ prefix: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func writeFakeAgent(in dir: URL, name: String = "fake-agent") throws -> URL {
    let url = dir.appendingPathComponent(name)
    try Data(fakeAgentScript.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

/// Zbiera powiadomienia z wątku odczytu.
actor Collected {
    var updates: [JSONValue] = []
    func add(_ v: JSONValue) { updates.append(v) }
    var text: String {
        updates.compactMap { $0["update"]?["content"]?["text"]?.stringValue }.joined()
    }
}

// MARK: połączenie

@Suite(.enabled(if: pythonAvailable)) struct ACPConnectionTests {
    private func launch(_ scenario: String, collected: Collected = Collected()) throws -> ACPConnection {
        let agent = try writeFakeAgent(in: try tempDir("acp"))
        return try ACPConnection.launch(
            executable: agent, environment: ["FAKE_SCENARIO": scenario],
            onRequest: { method, params in
                guard method == "session/request_permission" else { return .failure(.methodNotFound(method)) }
                // Jak w trybie tylko do odczytu: zawsze pierwsza opcja odrzucająca.
                let reject = params["options"]?.arrayValue?.first { $0["kind"]?.stringValue?.hasPrefix("reject") == true }
                return .success(["outcome": ["outcome": "selected", "optionId": reject?["optionId"] ?? "?"]])
            },
            onNotification: { _, params in await collected.add(params) })
    }

    @Test func handshakeSessionAndPromptWithPermission() async throws {
        let collected = Collected()
        let conn = try launch("ok", collected: collected)
        let hello = try await conn.initialize()
        #expect(hello.name == "Fake Agent")
        #expect(hello.version == "1.2.3")
        #expect(hello.authMethods.map(\.id) == ["browser-auth", "setup", "legacy"])
        #expect(hello.authMethods[0].type == "agent")
        #expect(hello.authMethods[1].args == ["--setup"])
        // Starszy zapis `_meta.terminal-auth` (Copilot): terminal z osobnym programem.
        #expect(hello.authMethods[2] == .init(id: "legacy", name: "Log in", type: "terminal", args: ["login"], command: "/opt/x/login-tool"))

        let session = try await conn.newSession(cwd: URL(fileURLWithPath: "/tmp/project"))
        #expect(session.id == "s-project")
        let result = try await conn.request("session/prompt", [
            "sessionId": .string(session.id), "prompt": [["type": "text", "text": "analyse"]],
        ], timeout: .seconds(10))
        #expect(result["stopReason"]?.stringValue == "end_turn")
        #expect(await collected.text == "got: analyse; permission: reject")
        await conn.close()
    }

    @Test func clientCapabilitiesDefaultToNoFilesAndNoTerminal() async throws {
        let conn = try launch("ok")
        let raw = try await conn.request("initialize", [
            "protocolVersion": 1, "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
        ])
        #expect(raw["echo"]?["terminal"]?.boolValue == false)
        await conn.close()
    }

    @Test func authRequiredIsRecognised() async throws {
        let conn = try launch("auth")
        _ = try await conn.initialize()
        do {
            _ = try await conn.newSession(cwd: URL(fileURLWithPath: "/tmp/x"))
            Issue.record("expected auth error")
        } catch let e as ACPConnection.RemoteError {
            #expect(e.isAuthRequired)
        }
        await conn.close()
    }

    @Test func crashFailsPendingRequestInsteadOfHanging() async throws {
        let conn = try launch("crash")
        _ = try await conn.initialize()
        await #expect(throws: ACPConnection.ConnectionError.self) {
            _ = try await conn.newSession(cwd: URL(fileURLWithPath: "/tmp/x"), timeout: .seconds(10))
        }
        // Po śmierci agenta kolejne żądania od razu dostają błąd.
        await #expect(throws: ACPConnection.ConnectionError.self) { _ = try await conn.request("initialize") }
    }

    @Test func requestTimesOut() async throws {
        let conn = try launch("hang")
        _ = try await conn.initialize()
        let session = try await conn.newSession(cwd: URL(fileURLWithPath: "/tmp/x"))
        let started = Date()
        do {
            _ = try await conn.request("session/prompt", ["sessionId": .string(session.id), "prompt": [["type": "text", "text": "x"]]],
                                       timeout: .milliseconds(300))
            Issue.record("expected timeout")
        } catch ACPConnection.ConnectionError.timeout(let method) {
            #expect(method == "session/prompt")
        }
        #expect(Date().timeIntervalSince(started) < 5)
        await conn.close()
    }

    @Test func unknownAgentRequestGetsMethodNotFound() async throws {
        // Domyślny `onRequest` odrzuca wszystko, czego klient nie obsługuje; agent dostaje błąd, nie ciszę.
        let agent = try writeFakeAgent(in: try tempDir("acp"))
        let conn = try ACPConnection.launch(executable: agent)
        _ = try await conn.initialize()
        let session = try await conn.newSession(cwd: URL(fileURLWithPath: "/tmp/x"))
        let result = try await conn.request("session/prompt", ["sessionId": .string(session.id), "prompt": [["type": "text", "text": "x"]]],
                                            timeout: .seconds(10))
        #expect(result["stopReason"]?.stringValue == "end_turn")
        await conn.close()
    }
}

/// Ręczny test z prawdziwym agentem: `DELEGATE_REAL_ACP_AGENT=/ścieżka/vibe-acp swift test --filter realAgent`.
/// Tylko `initialize` i `session/new` (nic nie wysyła modelowi, nic nie kosztuje).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DELEGATE_REAL_ACP_AGENT"] != nil))
struct RealACPAgentTests {
    @Test func realAgentHandshakeAndSession() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["DELEGATE_REAL_ACP_AGENT"])
        let conn = try ACPConnection.launch(executable: URL(fileURLWithPath: path))
        let hello = try await conn.initialize()
        #expect(hello.protocolVersion == ACPConnection.protocolVersion)
        #expect(!hello.authMethods.isEmpty)
        let session = try await conn.newSession(cwd: try tempDir("real-acp"))
        #expect(!session.id.isEmpty)
        await conn.close()
    }
}

// MARK: rejestr

let registryFixture = #"""
{
  "version": "1.0.0",
  "agents": [
    {"id": "mistral-vibe", "name": "Mistral Vibe", "version": "3.0.1", "description": "Mistral's assistant",
     "icon": "https://cdn.example/vibe.svg", "authors": ["Mistral AI"], "license": "Apache-2.0", "unknownField": 1,
     "distribution": {"binary": {
       "darwin-aarch64": {"archive": "https://example.com/vibe-arm.tar.gz", "cmd": "./vibe-acp", "sha256": "abc"},
       "darwin-x86_64": {"archive": "https://example.com/vibe-x86.tar.gz", "cmd": "./vibe-acp", "sha256": "def"}}}},
    {"id": "gemini", "name": "Gemini CLI", "version": "0.65.0",
     "distribution": {"npx": {"package": "@google/gemini-cli@0.65.0", "args": ["--acp"]}}},
    {"id": "py", "name": "Py Agent", "version": "1", "distribution": {"uvx": {"package": "py-agent"}}},
    {"id": "linux-only", "name": "Linux", "version": "1",
     "distribution": {"binary": {"linux-x86_64": {"archive": "https://example.com/l.tar.gz", "cmd": "./l"}}}}
  ],
  "extensions": []
}
"""#

@Suite struct ACPRegistryTests {
    @Test func parsesAgentsAndInstallKinds() throws {
        let r = try ACPRegistry.parse(Data(registryFixture.utf8))
        #expect(r.agents.count == 4)
        guard case .binary(let t) = r.agent("mistral-vibe")?.installKind else {
            Issue.record("vibe should install as binary"); return
        }
        #expect(t.cmd == "./vibe-acp")
        #expect(t.sha256 == (ACPRegistry.platformKey == "darwin-aarch64" ? "abc" : "def"))
        #expect(r.agent("gemini")?.installKind == .npm(.init(package: "@google/gemini-cli@0.65.0", args: ["--acp"], env: nil)))
        #expect(r.agent("py")?.installKind == .needsRuntime("uv"))
        #expect(r.agent("linux-only")?.installKind == .unavailable)
    }

    @Test func storeCachesAndFallsBackWhenOffline() async throws {
        let dir = try tempDir("reg")
        let cache = dir.appendingPathComponent("registry.json")
        let online = MockTransport(["cdn.agentclientprotocol.com": .init(status: 200, body: registryFixture)])
        let first = await ACPRegistryStore(cacheURL: cache, transport: online).load()
        #expect(first?.agents.count == 4)
        #expect(online.calls.count == 1)

        // Świeża kopia: bez sieci.
        _ = await ACPRegistryStore(cacheURL: cache, transport: online).load()
        #expect(online.calls.count == 1)

        // Wymuszone odświeżenie przy awarii sieci: zostaje stara kopia.
        let offline = MockTransport([:])
        let stale = await ACPRegistryStore(cacheURL: cache, transport: offline).load(forceRefresh: true)
        #expect(stale?.agents.count == 4)
        #expect(offline.calls.count == 1)
    }
}

// MARK: instalator

/// Transport z jedną binarną odpowiedzią (archiwum agenta).
final class DataTransport: HTTPTransport, @unchecked Sendable {
    let data: Data
    let status: Int
    init(_ data: Data, status: Int = 200) { self.data = data; self.status = status }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite(.enabled(if: pythonAvailable)) struct AgentInstallerTests {
    /// Archiwum `.tar.gz` z atrapą agenta w środku (`./bin/fake-agent`) i jego SHA-256.
    private func archive() throws -> (Data, String) {
        let src = try tempDir("src")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("bin"), withIntermediateDirectories: true)
        _ = try writeFakeAgent(in: src.appendingPathComponent("bin"))
        let out = try tempDir("tar").appendingPathComponent("agent.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", out.path, "-C", src.path, "bin"]
        try tar.run()
        tar.waitUntilExit()
        let data = try Data(contentsOf: out)
        return (data, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    private func entry(version: String = "1.0.0", sha: String?, cmd: String = "./bin/fake-agent",
                       archive: String = "https://example.com/agent.tar.gz") -> ACPRegistry.Agent {
        ACPRegistry.Agent(id: "fake", name: "Fake Agent", version: version, description: nil, repository: nil,
                          website: nil, authors: nil, license: nil, icon: nil,
                          distribution: .init(binary: [ACPRegistry.platformKey: .init(archive: archive, sha256: sha, cmd: cmd,
                                                                                         args: ["--acp"], env: ["A": "1"])],
                                              npx: nil, uvx: nil))
    }

    @Test func installsVerifiesAndRunsAgent() async throws {
        let (data, sha) = try archive()
        let dir = try tempDir("agents")
        let installer = AgentInstaller(directory: dir, transport: DataTransport(data))
        let installed = try await installer.install(entry(sha: sha))
        #expect(installed.executable.hasPrefix(dir.path + "/fake/1.0.0/"))
        #expect(FileManager.default.isExecutableFile(atPath: installed.executable))
        #expect(installed.args == ["--acp"])
        #expect(installer.installed().map(\.id) == ["fake"])

        // Zainstalowany agent naprawdę rozmawia po ACP.
        let conn = try ACPConnection.launch(executable: URL(fileURLWithPath: installed.executable), arguments: installed.args)
        #expect(try await conn.initialize().name == "Fake Agent")
        await conn.close()
    }

    @Test func updateReplacesOldVersionAndUninstallRemovesEverything() async throws {
        let (data, sha) = try archive()
        let dir = try tempDir("agents")
        let installer = AgentInstaller(directory: dir, transport: DataTransport(data))
        try await installer.install(entry(version: "1.0.0", sha: sha))
        #expect(installer.hasUpdate(entry(version: "1.1.0", sha: sha)))
        try await installer.install(entry(version: "1.1.0", sha: sha))
        let versions = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("fake").path)
        #expect(versions == ["1.1.0"])
        #expect(installer.installed("fake")?.version == "1.1.0")

        try installer.uninstall("fake")
        #expect(installer.installed().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("fake").path))
    }

    @Test func refusesBadChecksumMissingChecksumAndUnsafePaths() async throws {
        let (data, sha) = try archive()
        let dir = try tempDir("agents")
        let installer = AgentInstaller(directory: dir, transport: DataTransport(data))
        await #expect(throws: DelegateError.self) { try await installer.install(entry(sha: String(repeating: "0", count: 64))) }
        // Bez sumy i bez podpisu Developer ID (skrypt): tylko za zgodą użytkownika.
        await #expect(throws: UnverifiedAgentError.self) { try await installer.install(entry(sha: nil)) }
        await #expect(throws: DelegateError.self) { try await installer.install(entry(sha: sha, cmd: "../escape")) }
        await #expect(throws: DelegateError.self) { try await installer.install(entry(sha: sha, cmd: "./missing")) }
        await #expect(throws: DelegateError.self) { try await installer.install(entry(sha: sha, archive: "http://example.com/a.tar.gz")) }
        #expect(installer.installed().isEmpty)
        // Po nieudanych próbach nie zostają katalogi tymczasowe.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("fake").path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test func installsBareExecutableWithoutArchive() async throws {
        let raw = Data(fakeAgentScript.utf8)
        let sha = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        let installer = AgentInstaller(directory: try tempDir("agents"), transport: DataTransport(raw))
        let installed = try await installer.install(entry(sha: sha, cmd: "./fake-agent", archive: "https://example.com/fake-agent-darwin-arm64"))
        #expect(FileManager.default.isExecutableFile(atPath: installed.executable))
    }

    @Test func refusesNonBinaryAgents() async throws {
        let r = try ACPRegistry.parse(Data(registryFixture.utf8))
        let installer = AgentInstaller(directory: try tempDir("agents"), transport: DataTransport(Data()))
        // Agent z npm bez Node: czytelny błąd, bez prób instalacji.
        await #expect(throws: DelegateError.self) { try await installer.install(r.agent("gemini")!, node: nil) }
        await #expect(throws: DelegateError.self) { try await installer.install(r.agent("py")!, node: nil) }
    }

    @Test func commandPathRules() throws {
        #expect(try AgentInstaller.commandPath("./vibe-acp") == "vibe-acp")
        #expect(try AgentInstaller.commandPath("bin/./tool") == "bin/tool")
        #expect(throws: DelegateError.self) { try AgentInstaller.commandPath("/usr/bin/env") }
        #expect(throws: DelegateError.self) { try AgentInstaller.commandPath("a/../../x") }
        #expect(AgentInstaller.safeComponent("../evil/1.0") == "_evil_1.0")
    }
}

// MARK: agenci z npm

/// Minimalny agent ACP w JavaScripcie (tylko `initialize` i `session/new`), jako paczka npm z polem `bin`.
let fakeNodeAgentJS = #"""
#!/usr/bin/env node
const rl = require("readline").createInterface({ input: process.stdin });
const send = (m) => process.stdout.write(JSON.stringify(m) + "\n");
rl.on("line", (line) => {
  const m = JSON.parse(line);
  if (m.method === "initialize") send({ jsonrpc: "2.0", id: m.id, result: { protocolVersion: 1, authMethods: [],
    agentInfo: { name: "node-fake", title: "Node Fake", version: "2.0.0" }, argv: process.argv.slice(2), path: process.env.PATH } });
  else if (m.method === "session/new") send({ jsonrpc: "2.0", id: m.id, result: { sessionId: "n1" } });
  else if (m.id !== undefined) send({ jsonrpc: "2.0", id: m.id, error: { code: -32601, message: "unknown" } });
});
"""#

let nodeRuntime = NodeRuntime.find()

@Suite(.enabled(if: nodeRuntime != nil)) struct NpmAgentTests {
    /// `npm pack` lokalnej paczki: instalacja bez sieci.
    private func tarball() async throws -> URL {
        let src = try tempDir("npm-src")
        try #"{"name": "node-fake-acp", "version": "2.0.0", "bin": {"node-fake-acp": "bin/agent.js", "other": "bin/other.js"}}"#
            .write(to: src.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fakeNodeAgentJS.write(to: src.appendingPathComponent("bin/agent.js"), atomically: true, encoding: .utf8)
        try "process.exit(1)".write(to: src.appendingPathComponent("bin/other.js"), atomically: true, encoding: .utf8)
        let out = try tempDir("npm-pack")
        let node = try #require(nodeRuntime)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = node.path
        let (status, output) = try await runProcess(node.npm, ["pack", "--pack-destination", out.path, src.path], environment: env)
        #expect(status == 0, "\(output)")
        let file = try #require(try FileManager.default.contentsOfDirectory(atPath: out.path).first { $0.hasSuffix(".tgz") })
        return out.appendingPathComponent(file)
    }

    private func entry(_ package: String) -> ACPRegistry.Agent {
        ACPRegistry.Agent(id: "node-fake-acp", name: "Node Fake", version: "2.0.0", description: nil, repository: nil,
                          website: nil, authors: nil, license: nil, icon: nil,
                          distribution: .init(binary: nil, npx: .init(package: package, args: ["--acp"], env: ["X": "1"]), uvx: nil))
    }

    @Test func installsPackageAndRunsItWithSystemNode() async throws {
        let tgz = try await tarball()
        let dir = try tempDir("agents")
        let installer = AgentInstaller(directory: dir, transport: DataTransport(Data()))
        let installed = try await installer.install(entry(tgz.path), node: nodeRuntime)
        #expect(installed.kind == "npm")
        #expect(installed.executable == nodeRuntime?.node.path)
        #expect(installed.args.first?.hasSuffix("node_modules/node-fake-acp/bin/agent.js") == true)
        #expect(installed.args.dropFirst() == ["--acp"])
        #expect(installed.env["X"] == "1")
        #expect(installed.installDir == dir.appendingPathComponent("node-fake-acp/2.0.0").path)
        #expect(installer.installed().map(\.id) == ["node-fake-acp"])

        // Uruchomienie bez PATH z terminala: node podany wprost, PATH ze środowiska agenta.
        let conn = try ACPConnection.launch(executable: URL(fileURLWithPath: installed.executable),
                                            arguments: installed.args, environment: installed.env)
        let raw = try await conn.request("initialize", ["protocolVersion": 1, "clientCapabilities": [:]], timeout: .seconds(20))
        #expect(raw["agentInfo"]?["title"]?.stringValue == "Node Fake")
        #expect(raw["argv"]?.arrayValue == ["--acp"])
        await conn.close()

        // Usunięty katalog = agent nie jest już zainstalowany.
        try FileManager.default.removeItem(atPath: try #require(installed.installDir))
        #expect(installer.installed().isEmpty)
    }

    @Test func npmFailureIsReported() async throws {
        let installer = AgentInstaller(directory: try tempDir("agents"), transport: DataTransport(Data()))
        do {
            _ = try await installer.install(entry("/nonexistent/package.tgz"), node: nodeRuntime)
            Issue.record("expected npm failure")
        } catch let e as DelegateError {
            #expect(e.description.contains("npm install failed"))
        }
    }
}

// MARK: podpis kodu

/// Mała binarka z podpisem Developer ID, jeśli jest na tym Macu (Zed CLI).
let developerIDSample: URL? = ["/Applications/Zed.app/Contents/MacOS/cli"]
    .map { URL(fileURLWithPath: $0) }
    .first { FileManager.default.isExecutableFile(atPath: $0.path) }

@Suite struct CodeSignatureTests {
    @Test func scriptsAndApplePlatformBinariesAreNotDeveloperID() throws {
        let script = try writeFakeAgent(in: try tempDir("sig"))
        #expect(!CodeSignature.check(script).isDeveloperID)
        #expect(!CodeSignature.check(URL(fileURLWithPath: "/usr/bin/true")).isDeveloperID)
    }

    @Test(.enabled(if: developerIDSample != nil)) func developerIDBinaryNamesItsPublisher() throws {
        let sig = CodeSignature.check(try #require(developerIDSample))
        #expect(sig.isDeveloperID)
        #expect(sig.publisher == "Zed Industries, Inc.")
        #expect(sig.teamID == "MQ55VZLNZQ")
    }
}

@Suite(.enabled(if: pythonAvailable)) struct UnverifiedInstallTests {
    private func entry(version: String = "1.0.0", archive: String) -> ACPRegistry.Agent {
        ACPRegistry.Agent(id: "nosum", name: "No Sum", version: version, description: nil, repository: nil,
                          website: nil, authors: nil, license: nil, icon: nil,
                          distribution: .init(binary: [ACPRegistry.platformKey: .init(archive: archive, sha256: nil, cmd: "./tool")],
                                              npx: nil, uvx: nil))
    }

    @Test func unsignedNeedsApprovalAndIsPinnedByHash() async throws {
        let raw = Data(fakeAgentScript.utf8)
        let dir = try tempDir("agents")
        let installer = AgentInstaller(directory: dir, transport: DataTransport(raw))
        do {
            try await installer.install(entry(archive: "https://example.com/tool"))
            Issue.record("expected UnverifiedAgentError")
        } catch let e as UnverifiedAgentError {
            #expect(e.sha256.count == 64)
        }
        #expect(installer.installed().isEmpty)

        let ok = try await installer.install(entry(archive: "https://example.com/tool"), allowUnverified: true)
        #expect(ok.verifiedBy == "trusted")
        #expect(ok.signer == nil)

        // Ta sama wersja, inny plik: odmowa, nawet za zgodą.
        let changed = AgentInstaller(directory: dir, transport: DataTransport(raw + Data("# changed\n".utf8)))
        await #expect(throws: DelegateError.self) {
            try await changed.install(entry(archive: "https://example.com/tool"), allowUnverified: true)
        }
        // Nowa wersja może mieć inny plik.
        let next = try await changed.install(entry(version: "1.1.0", archive: "https://example.com/tool"), allowUnverified: true)
        #expect(next.version == "1.1.0")
    }

    @Test(.enabled(if: developerIDSample != nil)) func developerIDSignedBinaryInstallsWithoutChecksum() async throws {
        let data = try Data(contentsOf: try #require(developerIDSample))
        let installer = AgentInstaller(directory: try tempDir("agents"), transport: DataTransport(data))
        let installed = try await installer.install(entry(archive: "https://example.com/tool"))
        #expect(installed.verifiedBy == "signature")
        #expect(installed.signer == "Zed Industries, Inc.")
    }
}
