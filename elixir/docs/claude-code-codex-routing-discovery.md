# Discovery and Proposal: Add Claude Code Alongside Codex (`0XT-34`)

Date: 2026-03-05

## 1. Executive Summary

Symphony already has the right primitives to route work by Linear label, but execution is currently hard-wired to Codex.

Recommended direction:

- Keep Codex as the default execution engine.
- Add a label router with deterministic behavior:
  - if issue labels include `mode:claude`, run Claude Code.
  - otherwise run Codex (default).
- Introduce an agent backend abstraction so Claude and Codex share orchestration lifecycle logic.
- Start with opt-in rollout using `mode:claude` only.

This keeps existing behavior stable while enabling controlled Claude adoption.

## 2. Scope and Non-Goals

### In scope (this ticket)

- Discovery of how to integrate Claude Code in this repository.
- Exploration of Claude CLI and operational constraints.
- Detailed implementation proposal, validation plan, and rollout strategy.

### Out of scope (this ticket)

- Shipping production code changes.
- Switching default mode away from Codex.
- Broad UI/observability redesign.

## 3. Current State in This Repository

### 3.1 Labels are already ingested and normalized

The Linear client already fetches issue labels and lowercases them:

- `elixir/lib/symphony_elixir/linear/client.ex:485` (`extract_labels/1`)
- `elixir/lib/symphony_elixir/linear/client.ex:489` (`String.downcase/1`)

The normalized labels are present in the issue struct:

- `elixir/lib/symphony_elixir/linear/issue.ex:40`

The workflow prompt also already exposes labels to the agent context:

- `elixir/WORKFLOW.md:54` (`Labels: {{ issue.labels }}`)

### 3.2 Execution path is Codex-only today

Agent execution is currently bound to the Codex AppServer module:

- `elixir/lib/symphony_elixir/agent_runner.ex:7` (`alias ... Codex.AppServer`)
- `elixir/lib/symphony_elixir/agent_runner.ex:53` (`AppServer.start_session/1`)
- `elixir/lib/symphony_elixir/agent_runner.ex:66` (`AppServer.run_turn/4`)

Codex command/config are codex-specific:

- `elixir/lib/symphony_elixir/config.ex:31` default command is `codex app-server`
- `elixir/lib/symphony_elixir/config.ex:277` `codex_command/0`

Codex runtime launch is direct shell execution:

- `elixir/lib/symphony_elixir/codex/app_server.ex:175`

### 3.3 Baseline reproduction signal

Current repository scan confirms no Claude integration exists yet:

```bash
rg -n "mode:claude|claude" -S elixir/lib elixir/test SPEC.md README.md elixir/WORKFLOW.md
# no matches
```

## 4. Claude Code / Claude CLI Discovery

## 4.1 CLI surfaces relevant for orchestration

From local CLI help and execution probes in this workspace:

- Non-interactive mode is available via `-p/--print`.
- Machine-readable outputs are available (`--output-format json` and `stream-json`).
- Permission behavior is configurable (`--permission-mode ...`).
- Tool execution can be constrained (`--allowedTools`, `--disallowedTools`, `--tools`).
- MCP can be configured from files/JSON (`--mcp-config`, `--strict-mcp-config`).
- Session continuation is supported (`--resume`, `--continue`, `--session-id`).
- Session persistence and safety controls are exposed (`--no-session-persistence`, `--add-dir`, `--dangerously-skip-permissions`).

This is sufficient to support unattended orchestration semantics similar to current Codex automation.

## 4.2 Permission modes and unattended runs

The local CLI advertises permission modes including:

- `default`
- `acceptEdits`
- `dontAsk`
- `plan`
- `bypassPermissions`

For unattended worker runs, `bypassPermissions` is the closest equivalent to strict non-interactive automation, but it must only run inside strong sandbox boundaries.

## 4.3 Deployment and model-provider options

Claude Code supports multiple provider backends:

- Anthropic API
- AWS Bedrock
- Google Vertex AI

Docs provide provider-selection env vars and model override env vars (for example, provider and model selection keys).

This means Symphony can remain provider-agnostic at orchestration level while backend auth/model policy is managed by environment and per-run config.

## 4.4 Agent SDK option (wrapping Claude CLI)

Anthropic also provides an Agent SDK (TypeScript and Python) that wraps Claude CLI usage patterns and supports options such as `permissionMode`, output format selection, and settings sources.

Given this codebase is Elixir, direct CLI invocation is the simplest first integration path. SDK wrapping can remain a future option if richer session control is needed.

## 4.5 Local environment probe results

Local probe in this workspace:

- `claude` is installed: `2.1.63 (Claude Code)`.
- CLI supports required automation flags.
- In this sandbox, direct runs failed with `EACCES: permission denied, open` when using default home/config paths.
- Running with `HOME=/tmp` removed the file-permission error, confirming Claude CLI expects writable home/config/session paths.
- With `HOME=/tmp`, auth was not present (`Not logged in`), which is expected because auth state is home-scoped.

Observed commands:

```bash
claude --version
# 2.1.63 (Claude Code)

claude -p "ping" --output-format json --permission-mode plan
# error_during_execution ... "EACCES: permission denied, open"

HOME=/tmp claude -p "ping" --output-format json --permission-mode plan
# {"is_error":true,...,"result":"Not logged in · Please run /login"}
```

Implication: production worker runs need an explicit writable runtime home/config strategy and non-interactive auth provisioning.

## 5. Proposed Design

## 5.1 Deterministic routing rules

Normalize labels to lowercase (already done today), then apply:

1. If labels include `mode:claude`, route to Claude backend.
2. Else route to Codex backend.

Default remains Codex.

Optional later extension:

- Explicit `mode:codex` can be supported, but not required for initial scope.

## 5.2 Introduce backend abstraction

Add a behavior boundary for agent execution so orchestration logic stays shared:

- `SymphonyElixir.AgentBackend` behavior (new)
- `SymphonyElixir.AgentBackend.Codex` adapter (wraps current `Codex.AppServer` flow)
- `SymphonyElixir.AgentBackend.ClaudeCli` adapter (new)

### Suggested behavior sketch

```elixir
defmodule SymphonyElixir.AgentBackend do
  @callback start_session(Path.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback run_turn(map(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback stop_session(map()) :: :ok
end
```

`AgentRunner` then chooses backend from issue labels before `start_session`.

## 5.3 Claude backend execution model

Recommended initial strategy:

- Use `claude -p` in non-interactive mode.
- Use JSON output format for deterministic parseability.
- Pass permission mode from config (default conservative, with explicit override for unattended environments).
- Pass tool constraints from config to keep parity with current safety posture.
- Execute with workspace as cwd, similar to Codex worker behavior.

Command shape (illustrative):

```bash
claude -p "$PROMPT" \
  --output-format json \
  --permission-mode "$CLAUDE_PERMISSION_MODE" \
  --model "$CLAUDE_MODEL"
```

## 5.4 Config additions

Add a new top-level `agent` routing block and `claude` block.

Example proposal:

```yaml
agent:
  default_mode: codex
  label_mode_prefix: "mode:"

claude:
  command: claude
  model: sonnet
  permission_mode: bypassPermissions
  output_format: json
  setting_sources: project,local
  extra_args: []
```

Notes:

- Preserve existing `codex.*` settings untouched for backward compatibility.
- Keep codex as default when label routing does not match.

## 5.5 Event and observability compatibility

Current runtime fields and dashboard labels are codex-named (`codex_*`).

Recommended incremental approach:

- Keep existing fields for backward compatibility initially.
- Add `backend` metadata (`codex` or `claude`) in running entry state.
- If needed later, rename `codex_*` fields to provider-neutral fields in a separate migration ticket.

## 5.6 Failure and fallback semantics

To avoid silent behavior changes:

- If label resolves to Claude and Claude backend fails to initialize, fail the run with explicit error (do not silently switch to Codex in v1).
- Keep retries managed by existing orchestrator retry/backoff logic.
- Include backend identity in error messages and status dashboard output.

## 6. Implementation Plan (Phased)

### Phase 1: Routing and abstraction (no behavior change for non-Claude labels)

- Add backend selector module from issue labels.
- Introduce backend behavior and Codex adapter wrapper.
- Update `AgentRunner` to call selected backend.
- Add unit tests for routing decisions.

### Phase 2: Claude CLI backend

- Implement Claude CLI runner module with command builder and JSON parsing.
- Add configuration parsing/validation for `claude.*` options.
- Add integration tests with fake `claude` executable fixture to simulate success/error output.

### Phase 3: Operational hardening

- Add explicit runtime home/config directory controls for Claude execution.
- Document auth/token setup for unattended runs.
- Add dashboard/backend annotations and failure diagnostics.

## 7. Validation Plan

### 7.1 Unit tests

- Label routing matrix:
  - `[] -> codex`
  - `["bug"] -> codex`
  - `["mode:claude"] -> claude`
  - mixed-case labels still route correctly after normalization.

### 7.2 Integration tests

- `AgentRunner` chooses Codex when no mode label is present.
- `AgentRunner` chooses Claude when `mode:claude` is present.
- Claude command construction includes required flags and workspace cwd.
- Claude error output propagates into orchestrator retry path.

### 7.3 Manual validation

- Create two comparable Linear tickets:
  - one without `mode:claude`
  - one with `mode:claude`
- Confirm backend selected in logs/status dashboard.
- Confirm retry behavior and state transitions stay unchanged.

## 8. Risks and Mitigations

- Auth/session file paths may be unwritable in restricted sandboxes.
  - Mitigation: configure writable runtime home/config directory for Claude process.
- Provider/auth drift across environments.
  - Mitigation: explicit startup health check + clear error classification.
- CLI output format/schema drift.
  - Mitigation: parse defensively; pin tested Claude CLI version in deployment docs.
- Safety mismatch between providers.
  - Mitigation: explicit permission mode policy per backend in `WORKFLOW.md`.

## 9. Recommended Rollout

1. Ship routing + abstraction with no Claude labels in production tickets.
2. Enable `mode:claude` for a small pilot subset.
3. Observe stability, retries, token usage, and result quality.
4. Expand label usage after validation.

## 10. Open Questions

- Should `mode:claude` failure ever auto-fallback to Codex, or always fail closed?
- Do we want provider-neutral metric keys immediately, or defer to a follow-up migration?
- Should per-project defaults allow Claude without labels, or keep label-only routing long-term?

## 11. Source References

### Repository references

- `elixir/lib/symphony_elixir/linear/client.ex:485`
- `elixir/lib/symphony_elixir/agent_runner.ex:7`
- `elixir/lib/symphony_elixir/codex/app_server.ex:175`
- `elixir/lib/symphony_elixir/config.ex:31`
- `elixir/WORKFLOW.md:54`

### External references (Anthropic)

- Claude Code CLI reference:
  - https://docs.anthropic.com/en/docs/claude-code/cli-reference
- Permission modes:
  - https://docs.anthropic.com/en/docs/claude-code/iam#permission-modes
- Settings and precedence:
  - https://docs.anthropic.com/en/docs/claude-code/settings
- Deployment/provider configuration:
  - https://docs.anthropic.com/en/docs/claude-code/deployment/overview
- Agent SDK (CLI wrapper, TS/Python):
  - https://docs.anthropic.com/en/docs/claude-code/sdk
