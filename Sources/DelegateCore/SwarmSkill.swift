import Foundation

/// Skill `/swarm` dla Claude Code: jawny tryb dyrygenta. Instrukcje serwera tylko zachęcają do delegowania,
/// a skill daje Claude'owi procedurę: rozbić cel → dobrać wykonawców → wysłać równolegle → przejrzeć → scalić.
/// Instalowany przez apkę do `~/.claude/skills/swarm/SKILL.md`; plik z innym skillem o tej nazwie (bez naszego
/// znacznika) zostaje nietknięty. Tekst po angielsku, jak wszystko, co czyta Claude.
public enum SwarmSkill {
    public static let marker = "<!-- delegate-mcp swarm skill -->"

    public static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills/swarm/SKILL.md")
    }

    public enum State: Sendable, Equatable {
        case notInstalled
        case installed
        case outdated
        /// Inny skill o nazwie `swarm` (nie nasz) — nie nadpisujemy.
        case foreign
    }

    public static func state(of text: String?) -> State {
        guard let text else { return .notInstalled }
        guard text.contains(marker) else { return .foreign }
        return text == content ? .installed : .outdated
    }

    public static func install() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Usuwa tylko nasz skill.
    public static func remove() throws {
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.contains(marker) else { return }
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    public static let content = """
    ---
    name: swarm
    description: Conductor mode. Split a goal (a roadmap item, an issue, a list of changes) into independent tasks, run them in parallel on cheaper models and coding agents through the delegate MCP tools, then review and merge the results. Use when the user invokes /swarm or asks to run a swarm or fan work out to agents.
    argument-hint: <goal, e.g. "implement section C of ROADMAP.md">
    ---
    \(marker)

    # Swarm: you are the conductor

    Your own tokens are the expensive resource. Plan, brief, review and merge yourself; hand the reading, writing
    and testing to the `delegate` tools. Goal: $ARGUMENTS

    ## 1. Understand the goal
    - Read only what you need to plan (the roadmap section, the issue, the relevant file list). For a wide
      unknown area, start with one `delegate_agent` job in read mode ("map where X lives and what must change")
      instead of reading many files yourself.
    - Call `list_models` once: it lists the agents with their models, effort levels, defaults, sign-in state
      and repository rules.

    ## 2. Plan independent tasks
    - Split the goal into tasks that don't touch the same files and don't depend on each other's results. Tasks
      that must run in sequence go in later waves; a later task gets an earlier report with `context_jobs: ["<id>"]`
      instead of you retelling it in the brief.
    - Pick the executor per task:
      - **Long text from files** (translations, docs, changelog, fixtures, one-file rewrites; worth it from a few
        hundred lines of output): `delegate` with `files` in, `output_file` out, a `check`, `background: true`.
      - **Repo analysis**: `delegate_agent` in read mode.
      - **Code changes with checks**: `delegate_agent` with `mode: "write"`. Its branch starts from HEAD, so
        tell the user to commit first if the task builds on uncommitted work.
    - Pick the model: cheap ones (the user's defaults, `haiku`/`low`, flash models) for mechanical work,
      stronger ones for tricky logic. An agent on your own subscription (Claude Agent when you are Claude) only
      pays off with a cheaper model. Respect `sensitivity` (work or personal code: `personal`) and repository
      rules; if a job is refused, don't route around the rule.
    - Brief like a senior to a junior: the goal in a few sentences, boundaries (files, no new dependencies) and
      the acceptance `check` (build, tests, a validator). Don't explain what the agent can read in the repo or
      the model gets in `files`; a long brief costs you more than it saves.
    - Show the plan as a short table (task, executor and model, mode, files) and wait for the user's go-ahead,
      unless they already said to proceed. Dispatching sends code to other providers and spends their quotas.

    ## 3. Dispatch
    - Start every task of the wave in one go (`background: true` for `delegate`; `delegate_agent` always runs in
      the background). The server runs a limited number of agents at once and queues the rest.
    - While they work, do the parts that need your judgement, or prepare the review.
    - Collect with `delegate_result` (`wait` up to 40 s per call), all job IDs at once.

    ## 4. Review every result
    - A passing `check` plus `git diff --stat` is the acceptance. The server already sent failures back for up to
      two fix rounds, so don't re-run the checks or write your own validators. Read the diff only when the check
      failed, the stat looks wrong (unexpected files, huge changes) or the area is risky.
    - Spot-check file:line claims from read-mode reports before relying on them.
    - Accept, or send one follow-up round with concrete feedback (`delegate_agent` write mode with
      `branch_from: "<branch>"` continues on top of the agent's branch). If a task fails twice, do it yourself.

    ## 5. Merge and clean up
    - Merge accepted branches one at a time with `git merge --squash <branch>`, run the tests after each, and
      resolve conflicts yourself. Don't commit unless the user asked you to; follow their commit habits.
    - Delete merged and rejected branches (`git branch -D <branch>`); list leftovers with
      `git branch --list 'delegate/*'`.

    ## 6. Report
    A short table: task, executor, result (merged, rejected, done by you), and what is left. Mention anything
    that needs the user's decision.
    """
}
