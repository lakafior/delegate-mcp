# Delegate MCP

[![CI](https://github.com/mar/delegate-mcp/actions/workflows/ci.yml/badge.svg)](https://github.com/mar/delegate-mcp/actions/workflows/ci.yml)
[![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-black.svg)]()
[![Swift](https://img.shields.io/badge/Swift-6.2%2B-orange.svg)]()
[![License](https://img.shields.io/badge/license-MIT-blue.svg)]()

> **Delegate** is a native macOS menu bar app and stdio [Model Context Protocol (MCP)](https://modelcontextprotocol.io) server that lets Claude (Desktop & Code) delegate standalone tasks to cheaper, faster, or local AI models with automated fallback, cost tracking, and secret leak prevention.

---

## 🚀 Why Delegate?

When working with Claude (on Pro or Team subscriptions), many tasks—such as code boilerplate generation, unit test drafting, bulk translations, text summaries, or sanity checks—do not require expensive frontier models.

**Delegate** empowers Claude to act as an orchestrator:
1. **Intelligent Fallback**: Define provider priority in `delegate.toml`. If a provider hits a rate limit, runs out of balance, or fails, Delegate automatically falls over to the next available provider.
2. **Cost Tracking & ROI Calculator**: Tracks exact token usage, calculates actual costs per query in USD, and shows live savings compared to the Claude 3.5 Sonnet benchmark ($3/$15 per 1M tokens).
3. **Data Leak Prevention (DLP)**: Pre-flight secret leak detector inspects prompts before dispatching them to external APIs, blocking accidental transmission of API keys, Bearer tokens, and AWS/GitHub credentials.
4. **Native macOS Experience**: Written entirely in modern Swift 6 with SwiftUI. No Python, Node.js, or runtime bloat. Includes a menu bar app with quick connection tests, real-time health diagnostics, and Keychain integration.
5. **Broad Model & Protocol Support**: OpenAI-compatible APIs (Mistral, DeepSeek, OpenRouter, Cerebras, Groq), Google Gemini, Anthropic Messages API, local engines (Ollama, LM Studio, vLLM), and offline Apple Intelligence Foundation Models.

---

## 🛠️ MCP Tools Exposed to Claude

| Tool | Description |
|---|---|
| `delegate` | Sends a prompt to a target model (`provider/model`), tag (e.g. `code`, `translate`), or top priority. Supports `json: true`, custom `system`, temperature, max tokens, and automatic fallback. |
| `list_models` | Lists all configured providers and models ordered by priority, along with tags, pricing, key status, and routing guidance. |
| `list_remote_models` | Queries provider APIs directly for current model IDs, heuristic tags, context limits, and pricing. |
| `update_models` | Upserts model tags and pricing directly in `delegate.toml`. |
| `usage_summary` | Returns a breakdown of calls, tokens, total USD spend, and savings vs Sonnet benchmark. |

---

## 📦 Requirements

- macOS 26.0 or newer
- Xcode 16+ or Swift 6.2+
- Claude Desktop or Claude Code CLI

---

## ⚡ Quick Start

### 1. Build the Project

```bash
# Clone the repository
git clone https://github.com/mar/delegate-mcp.git
cd delegate-mcp

# Build CLI and Menu Bar App
./scripts/build-app.sh
```

The compiled application will be located in `dist/Delegate.app`, containing both the menu bar app and the bundled `delegate-mcp` server.

### 2. Configure in Claude Desktop

Add Delegate to your Claude Desktop configuration (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "delegate": {
      "command": "/absolute/path/to/delegate-mcp/dist/Delegate.app/Contents/Helpers/delegate-mcp"
    }
  }
}
```

Or install with a single click inside the Delegate app under **General (Ogólne) → Claude → Install**.

### 3. Configure in Claude Code

Run:

```bash
claude mcp add delegate -s user -- "/absolute/path/to/delegate-mcp/dist/Delegate.app/Contents/Helpers/delegate-mcp"
```

---

## ⚙️ Configuration (`delegate.toml`)

Configuration is stored at `~/Library/Application Support/Delegate/delegate.toml` (override with `$DELEGATE_HOME`).

Example configuration:

```toml
# Priority order is determined by the appearance of [[provider]] blocks.
timeout_seconds = 120

routing_guidance = """
Delegate self-contained tasks: boilerplate generation, translations, first drafts,
summaries of pasted text, second opinion on code snippets. Always verify output.
"""

[[provider]]
id = "mistral"
type = "openai"
base_url = "https://api.mistral.ai/v1"
api_key_env = "MISTRAL_API_KEY"

[[provider.model]]
id = "codestral-latest"
tags = ["code"]
cost = "free"

[[provider]]
id = "gemini"
type = "gemini"
base_url = "https://generativelanguage.googleapis.com/v1beta"
api_key_env = "GEMINI_API_KEY"

[[provider.model]]
id = "gemini-flash-latest"
tags = ["general", "translate", "summarize"]
cost = "free"

[[provider]]
id = "ollama"
type = "openai"
base_url = "http://localhost:11434/v1"
api_key_env = "" # Empty api_key_env means no authentication required

[[provider.model]]
id = "llama3.2:latest"
tags = ["local", "offline"]
cost = "free"

[[provider]]
id = "apple"
type = "foundation" # On-device Apple Intelligence

[[provider.model]]
id = "on-device"
tags = ["private", "offline", "short"]
cost = "free"
```

### Managing Providers in GUI

- **Add Provider**: Click `+` in the Settings window and pick a preset (Mistral, Gemini, DeepSeek, OpenRouter, Anthropic, Ollama, LM Studio, or a custom OpenAI-compatible API). A fresh install starts with only the on-device Apple model.
- **Rename Provider**: Click the pencil icon next to the provider title or right-click the provider in the sidebar and choose **Rename…**. The stored API key moves with it.
- **Reorder Priority**: Drag and drop providers in the sidebar list.
- **API Keys**: Stored securely in macOS Keychain with access control list (ACL) configured so the MCP helper process can read them seamlessly.

---

## 🧭 How Claude Learns When to Delegate

On startup the server sends MCP server instructions generated from your config: when to delegate, what never to send, and which ready models handle each task tag. Claude Code and Claude Desktop add them to every session, so no `CLAUDE.md` edits are needed. Optionally, **General → Claude** adds a short reminder block to `~/.claude/CLAUDE.md`. Restart Claude after changing providers so the instructions refresh.

---

## 🩺 Diagnostics & Doctor

Run the built-in diagnostic doctor from your terminal:

```bash
./dist/Delegate.app/Contents/Helpers/delegate-mcp doctor
```

Output checks:
- Configuration file validity and syntax
- API keys existence in Keychain or environment
- Live network connectivity and latency (ms) to each provider endpoint
- Apple Intelligence / on-device model availability
- Claude Desktop and Claude Code integration status

---

## 🧪 Testing

Run the test suite using SwiftPM:

```bash
swift test
```

---

## 🤝 Contributing

Contributions are warmly welcomed! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details on code style, testing, and pull request procedures.

---

## 📄 License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
