# Maestro — The Journey

An AI orchestrator that takes an iOS Jira ticket to a merged GitHub PR.
No custom code. One config file. Human in control at every step.

---

## Milestone 1 — Foundation

### Decision: Claude Code template over a Python orchestrator
Eliminated an entire app layer. Any developer with Claude Code can use
Maestro — no runtime to install.

### Decision: Single `project.yaml` config
All project-specific values in one file. New iOS project = edit one file.

### Decision: HITL designed to reduce over time
Hard gates today — nothing commits or pushes without approval. Each HITL
point is isolated per agent so autonomy can be dialled up incrementally
as confidence in the system grows.

---

## Milestone 2 — Agent Pipeline

### Decision: Seven single-responsibility agents
BA → Architect → Developer → Code Review → Security → PR Manager →
PR Routine. Each re-runnable independently via its own slash command.

### Decision: Loop-back gates on Code Review and Security
Failed review sends work back to Developer with issues as context.
Pipeline doesn't advance until both pass.

### Decision: TDD + SOLID in the Developer agent
Red/Green/Refactor enforced by prompt. SOLID principles applied by
default — if legacy code requires a significant refactor to comply,
the agent pauses and presents options rather than proceeding silently.

### Decision: Multiple-choice HITL over open-ended questions
When agents need input, they present numbered options. BA and Architect
always include an "Escalate to PO" option when the question is a product
decision the developer can't answer alone.

### Decision: Per-agent slash commands alongside `/maestro`
Each agent re-runnable independently. Loop-backs don't restart the
pipeline from the Jira ticket.

---

## Milestone 3 — MCP Integration

### Decision: `.mcp.json` over VS Code global connector
VS Code global MCP connections don't travel with the repo. `.mcp.json`
is project-local — every developer who clones Maestro gets the MCP
server definitions automatically.

### Decision: Shell env vars over hardcoded credentials
Credentials stay in `.env` (gitignored). MCP servers inherit them from
the shell. New developers copy `.env.example`, fill in tokens once.

### Verified
Jira API confirmed live against `LIT` project via curl and MCP connection.

---

## Milestone 4 — Project-Agnostic Distribution

### Decision: Decouple from LiteUp, become a generic iOS orchestrator
Maestro was originally wired to a single guinea-pig project. Decided
to make it distributable — any iOS team can clone it, run `install.sh`,
and be up and running with their own Jira boards and GitHub repos.

### Decision: `maestro.yaml` lives in each iOS project repo
Project config no longer lives in the orchestrator. Each iOS repo owns
its `maestro.yaml`. Maestro ships with zero project knowledge.

### Decision: VS Code multi-root workspaces for project switching
One `.code-workspace` file per project, generated at install time.
Switching projects = opening a different workspace file. No config
toggling, no credential swapping — Claude reads the active `maestro.yaml`
from the second workspace root automatically.

### Decision: Multiple Jira orgs via named MCP servers
Each Atlassian account gets its own MCP server entry (`atlassian-acme`,
`atlassian-clientco`). `maestro.yaml` declares which server to use.
Credentials stay in `.env`, scoped by account nickname.

### Decision: `install.sh` as a self-contained setup wizard
Interactive wizard collects all project details, generates `.env`,
`.mcp.json`, workspace files, and `maestro.yaml` in each iOS repo.
Idempotent — re-run to add a new project without losing existing config.

---

## Milestone 5 — BA Agent: Production-Ready Workflow

### Decision: Structured Clarification Needed flow over open-ended questions
Numbered multiple-choice with at least two assumptions per item, plus an ⛔ Escalate to PO blocking option. Up to 3 rounds before offering "proceed with deferred clarification."

### Decision: Blocking escalation posts to Jira and stops the pipeline
Escalate to PO drafts a Jira comment, gets HITL approval, posts it, attempts a Blocked transition, and halts. Resumes only when PO input arrives.

### Decision: Given/When/Then test cases grouped by Happy Path, Edge, Negative
Same language as acceptance criteria. Each TC is a self-contained behavioural contract — no table columns to interpret.

### Decision: AC + TCs in a single Jira comment draft
One HITL approval, one comment, one source of truth on the ticket.

### Decision: Clarification Needed owns all questions — Open Questions removed
Unresolved items are documented inline as "Not yet clarified" rather than deferred to an appendix.

### Decision: Branch confirmation at pipeline startup
Maestro checks the current git branch and asks the user to confirm the correct base before any agent runs.

### Decision: Keep HITL on most checkpoints while agents are in training
Agents are still being tested and tuned. Dense human gates now — autonomy can be dialled back once behaviour is proven reliable.

---

## Milestone 6 — Architect Agent: Production-Ready Workflow

### Decision: MVVM+C as the default architectural pattern
Defaults to MVVM+C when no pattern is established or specified.
Deviates only to match an existing codebase pattern.

### Decision: SOLID enforced at planning stage, not just development
The Architect flags violations before the Developer touches code.
Targeted refactor only — minimum needed for testability, rest left as-is.

### Decision: Baseline test run before strategy selection
Tests run against a confirmed scheme before any plan is made. Failing
tests escalate to PO and block the ticket — unless the user explicitly
accepts the risk.

### Decision: Implementation strategy scored against complexity factors
Each strategy is evaluated against a fixed set of factors (legacy,
DB changes, untested areas, SOLID violations, monolith). One is marked
Recommended. HITL selects before planning proceeds.

### Decision: Integration tests require explicit scheme confirmation
Real endpoint tests require user confirmation. If opted in, the plan
includes a notice: integration tests must live in a dedicated scheme,
never in development schemes.

### Decision: Time gap + branch check before any agent starts
If more than 3 hours have elapsed since the last agent interaction,
the agent verifies the current branch matches the ticket. Maestro
passes the last-interaction timestamp at spawn time.

### Decision: Branch proposed by the Architect at plan handoff
Branch name follows project convention (feature/release/hotfix +
project key + ticket title). Current branch offered as last option.
Confirmed before the Developer Agent is invoked.

---

## Milestone 7 — Pipeline Infrastructure: Shared Rules

### Decision: Shared rules defined in CLAUDE.md, referenced by agents
Time Gap Check, Branch Verification, and SOLID are defined once in
CLAUDE.md and referenced with a single line in each agent. Avoids
duplication and ensures changes propagate automatically.

### Decision: SOLID as a guide, not a blocker
Violations do not stop work — they must be surfaced and documented.
Silently ignoring a violation is not acceptable. The rule lives in
CLAUDE.md so no agent can claim it was not loaded.

---

## Milestone 8 — Developer Agent: Production-Ready Workflow

### Decision: Developer as TDD cycle orchestrator
The developer does not write tests and production code simultaneously.
It drives a disciplined RED → GREEN → SOLID check → REFACTOR → COMMIT
loop — RED is always delegated to the `red-tdd-developer` subagent.

### Decision: Work queue built from Architect's Test Map
Before any code is written, the developer builds a typed, ordered,
validated checklist from the Architect's Test Map. Extend TCs are
verified on disk; Integration TCs are flagged before the loop starts.

### Decision: 3-attempt limits on GREEN and REFACTOR
Both phases cap at 3 attempts before escalating to the user with a
full account of what was tried and why it failed. No silent loops.

### Decision: red-tdd-developer as a Failing tests agent
AI tends to anticipate solutions. The RED phase is delegated to a
scope-locked subagent whose sole purpose is a buildable failing test —
no implementation context, no GREEN. SOLID still applies.

---

## Milestone 9 — Architecture Patterns & Production Readiness

### Decision: Architecture Guide as a shared thinking framework
Layers are a guide, not a rule or a count. The dependency direction is
non-negotiable; the physical structure (folders → packages → own repo)
evolves with complexity. Guide lives in CLAUDE.md — one source for all agents.

### Decision: Policy contracts live in Domain
Business validation rules are pure Swift value types — impossible to construct
in an invalid state. Error messages live in Presentation. Never mixed.

### Decision: coding_standards.md as single source of truth
Architecture, Swift 6 concurrency, data storage, SOLID, access control, and
naming in one shared file. Agents reference it; they don't duplicate it.

### Decision: Code Review Agent fully rewritten with compliance gates
Architecture layer compliance (4.7) and Data storage migration compliance
(4.8) are explicit review gates, not afterthoughts.

---

## Milestone 10 — Per-Account Setup & Hybrid Auth

### Decision: Per-account state over shared workspace
Each Mac account owns its state under `$HOME/.maestro` — secrets in a
gitignored `.env` and API keys in the login keychain, never in the shared
repo. Only read-only code (agents, hooks, commands) is shared. Sharing the
working folder across accounts is out; each account clones from GitHub.

### Decision: Current-repo `maestro.yaml` over workspace-root search
Replaced VS Code multi-root workspaces (Milestone 4) with a simpler model:
commands read `./maestro.yaml` from the current repo, and a SessionStart
hook auto-activates Maestro only in repos that contain one. No workspace
file to open, no second root to resolve.

### Decision: Hybrid Claude authentication chosen at install
One up-front prompt: subscription login (Pro/Max), per-project API key, or
decide per project. The choice is asked once; per-project keys are collected
only for projects that opt in.

### Decision: Subscription login as the default to avoid credit billing
A stale `apiKeyHelper` silently billed against API credits ("Credit balance
is too low") instead of the subscription. Subscription projects now strip any
helper; keyed projects store the key in the keychain and wire a gitignored
`apiKeyHelper` pointer, with a credits warning shown before key entry.

---

## Milestone 11 — Security Agent: Production-Ready Workflow

### Decision: Critical / High / Notes severity tiers
Critical blocks. High must be fixed before release but doesn't block the
PR. Notes are non-blocking. Severity drives the verdict.

### Decision: Handoff gated on approval OR a documented accepted risk
Hands off only on SECURITY APPROVED, or when the user accepts the risk
and the documenting Jira comment is posted.

---

## Milestone 12 — PR Routine: Delivery Automation

### Decision: PR Routine as a PR Manager complementary agent
Improvements on PR Routine as a PR Manager complementary agent, to help keep
track of the PR and Build status, automating the workflow until the ticket is
Ready for QA.

---

## Milestone 13 — Security Across the Pipeline

### Decision: Stop data leaks before they are pushed
A commit that leaks data, such as a token or a password, is risky and must
never go public. Security now runs across the agents, not only at the end:
the Architect takes a gitleaks and SwiftLint baseline, the Developer checks
for secrets before each commit, and the Security Agent scans again before
the pull request.

---

## Milestone 14 — Simpler Installation

### Decision: Simplify and reduce the installation pack
Makes setup simpler for the user and removes tools Maestro no longer uses
(mcp-atlassian, node, the GitHub and git MCP servers). Install sets up the
tools and Maestro; link connects one project at a time. 1,633 → 1,037 lines.

---

## Milestone 15 — Uninstall

### Decision: Uninstall as a standard feature
The ability to remove software is normal practice in the market, and users
expect it. `uninstall.sh` removes everything the installer set up,
credentials included, all at once or one by one. It always asks before it
deletes the Maestro code.

---

## Milestone 16 — README & Portfolio Polish 🔜
