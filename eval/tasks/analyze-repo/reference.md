# Reference (delegate-mcp at 8989842)

Definition
- Sources/DelegateCore/RoutingPolicy.swift:65-90 `RoutingExclusion` with `Kind` (unavailable, region, pause, budget); `isPause` at :89.
- Sources/DelegateCore/RoutingPolicy.swift:93-140 `RoutingPlan.refusalAdvice`: one line per kind present; needs a `quota` line.

Produced
- Sources/DelegateCore/DelegateService.swift:251-310 `routingPlan`: unavailable (:258), region (:264, :267), pause (:283), budget (:295). A quota check (from a usage counter or provider response) would add `kind: .quota` exclusions here, before or next to the budget filter.
- Sources/DelegateCore/AgentRun.swift:110-150 `AgentChoice.pick` builds exclusions for agents (region, pause, unavailable); not needed for a provider quota, but it switches over nothing, so no change required.

Read
- Sources/DelegateCore/DelegateService.swift:346 refusal message uses `refusalAdvice`.
- Sources/DelegateCore/DelegateService.swift:409 header lists paused models via `isPause` (quota could get its own note).
- Sources/Delegate/RoutingView.swift:~140-150 shows excluded rows and a "Resume paused models" button when `isPause`.

Also
- Tests: Tests/DelegateCoreTests/RefusalAdviceTests.swift (one test per refusal path).
- CLAUDE.md "Routing" section documents the kinds.
