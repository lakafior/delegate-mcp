# Contributing to Delegate

Thank you for your interest in contributing to **Delegate**! This document provides guidelines and information to help you submit high-quality contributions.

---

## 🏛️ Project Architecture

The project is structured as a Swift package with three primary targets:

- `DelegateCore`: Core business logic, TOML parser/serializer (`Config`), secret stores (`Secrets`), usage logger & cost calculator (`UsageLog`), providers & HTTP transport (`ProviderClient`), diagnostics engine (`DelegateDoctor`), and Claude integration helpers (`ClaudeIntegration`).
- `delegate-mcp`: Stdio executable serving MCP tools to Claude Desktop / Code using the official Model Context Protocol Swift SDK.
- `Delegate`: Native macOS Menu Bar and Settings application written with SwiftUI.

---

## 💻 Development Setup

1. **Prerequisites**:
   - macOS 26.0+
   - Swift 6.2+ (Xcode 16+)
2. **Build**:
   ```bash
   swift build
   ```
3. **Run Tests**:
   ```bash
   swift test
   ```
4. **Build Full Application**:
   ```bash
   ./scripts/build-app.sh
   ```

---

## 🧪 Testing Guidelines

- All business logic in `DelegateCore` should be accompanied by comprehensive tests in `Tests/DelegateCoreTests`.
- We use the modern Swift Testing framework (`import Testing`, `@Suite`, `@Test`, `#expect(...)`).
- HTTP calls should be mocked using `MockTransport` to avoid network dependencies in test suites.

---

## 📝 Code Style & Conventions

- Follow standard Swift conventions and concurrency safety (`Sendable`, structured concurrency, actors where appropriate).
- Avoid unnecessary external dependencies. Keep the binary lean and performant.
- Ensure all comments and documentation remain clear and descriptive.

---

## 🚀 Submitting Changes

1. Fork the repository and create your branch from `main`:
   ```bash
   git checkout -b feature/my-new-feature
   ```
2. Commit your changes with clear, descriptive commit messages.
3. Make sure all unit tests pass:
   ```bash
   swift test
   ```
4. Open a Pull Request explaining the problem, the solution, and any testing performed.
