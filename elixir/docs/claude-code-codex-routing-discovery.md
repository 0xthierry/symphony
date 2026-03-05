# Discovery and Proposal: Label-Routed Claude Code + Codex (`0XT-34`)

Date: 2026-03-05

## 1. Goal

Add support for running either Codex or Claude Code per Linear issue with deterministic routing:

- If the issue labels contain `mode:claude`, run Claude Code.
- Otherwise, run Codex.
- Default remains Codex.

This document captures repository discovery, Claude CLI exploration, and a concrete implementation proposal.

## 2. Repository Baseline Discovery

### 2.1 Labels are already available and normalized

Label extraction and normalization already exist in the Linear adapter:

- `elixir/lib/symphony_elixir/linear/client.ex:485` (`extract_labels/1`)
- `elixir/lib/symphony_elixir/linear/client.ex:489` (`String.downcase/1`)

Normalized labels are stored on the issue model:

- `elixir/lib/symphony_elixir/linear/issue.ex:17`
- `elixir/lib/symphony_elixir/linear/issue.ex:40` (`label_names/1`)

The workflow prompt already includes labels in issue context:

- `elixir/WORKFLOW.md:66` (`Labels: {{ issue.labels }}`)

### 2.2 Routing/filter primitives already exist for dispatch

The repository now includes generic issue filtering (`tracker.issue_filters`) used by orchestrator dispatch decisions:

- `elixir/lib/symphony_elixir/issue_filter.ex`
- `elixir/lib/symphony_elixir/config.ex:222` (`linear_issue_filters/0`)
- `elixir/lib/symphony_elixir/orchestrator.ex:277` (dispatch filter usage)

This is useful context, but it does not choose agent backend (Codex vs Claude) once an issue is selected.

### 2.3 Agent execution is Codex-only today

Execution flow is hard-wired to Codex:

- `elixir/lib/symphony_elixir/agent_runner.ex:7` aliases `SymphonyElixir.Codex.AppServer`
- `elixir/lib/symphony_elixir/agent_runner.ex:53` starts Codex session
- `elixir/lib/symphony_elixir/agent_runner.ex:66` runs Codex turn
- `elixir/lib/symphony_elixir/codex/app_server.ex:175` launches configured codex command

Config validation is Codex-specific today:

- `elixir/lib/symphony_elixir/config.ex:31` default codex command
- `elixir/lib/symphony_elixir/config.ex:445` `require_codex_command/0`

### 2.4 Concrete reproduction signal

Observed repository scans in this workspace:

```bash
rg -n "mode:claude|mode:codex|claude" elixir/lib elixir/WORKFLOW.md elixir/config -S
# no matches (exit code 1)

rg -n "Codex\.AppServer|codex_command|codex app-server" \
  elixir/lib/symphony_elixir/agent_runner.ex \
  elixir/lib/symphony_elixir/config.ex \
  elixir/lib/symphony_elixir/codex/app_server.ex -S
# matches found in all three files
```

Conclusion: label-driven backend routing does not exist yet; runtime remains Codex-only.

## 3. Claude CLI Discovery (Local Exploration)

### 3.1 Installed version and availability

```bash
command -v claude
# /home/thierry/.local/bin/claude

claude --version
# 2.1.63 (Claude Code)
```

### 3.2 CLI features relevant to orchestration

From `claude --help`, the following capabilities are directly relevant:

- Non-interactive execution: `-p, --print`
- Structured output: `--output-format text|json|stream-json`
- Permission controls: `--permission-mode acceptEdits|bypassPermissions|default|dontAsk|plan`
- Session control: `--resume`, `--continue`, `--session-id`, `--no-session-persistence`
- Tool surface controls: `--tools`, `--allowedTools`, `--disallowedTools`
- MCP controls: `--mcp-config`, `--strict-mcp-config`
- Workspace/scope controls: `--add-dir`, `--setting-sources`, `--settings`

### 3.3 Output behavior in non-interactive runs

Probe command:

```bash
claude -p "Respond with exactly OK" --output-format json --permission-mode plan --tools ""
```

Observed behavior:

- Output is a JSON array containing multiple event records (for example `system/init`, `assistant`, `rate_limit_event`, `result`).
- Final useful response is in the `result` event (`"result":"OK"`).

Probe command:

```bash
claude -p "Respond with exactly OK" --output-format stream-json --permission-mode plan --tools ""
```

Observed behavior:

- Output is newline-delimited JSON events.
- In this environment, startup hook events (`hook_started`, `hook_response`) appear before init/result events.

Implication: parser logic must be event-oriented and tolerant of extra event types rather than assuming a single response object.

### 3.4 Auth and runtime home behavior

Default home in this environment is authenticated:

```bash
claude auth status
# {"loggedIn": true, ...}
```

Changing home to a fresh temp path removes auth context:

```bash
HOME=/tmp claude auth status
# {"loggedIn": false, ...}

HOME=/tmp claude -p "ping" --output-format json --permission-mode plan
# result indicates not logged in and requests /login
```

Implication: unattended production runs need explicit and writable runtime home/config paths plus pre-provisioned auth for that runtime identity.

### 3.5 Operational implications for Symphony

- Claude CLI is viable for unattended invocation in this environment.
- Session/auth behavior is home-scoped; environment isolation must be deliberate.
- Startup hooks/settings can inject additional text/events; parser and policy should not assume a minimal stream.
- Permission mode and tool restrictions should be explicitly configured by workflow, not left to workstation defaults.

## 4. Proposed Design

### 4.1 Deterministic routing contract

Routing rule (required by ticket):

1. If issue labels include `mode:claude`, backend is `claude`.
2. Else backend is `codex`.

Default remains Codex.

### 4.2 Backend selector module

Introduce a small selector module to centralize routing logic:

- New: `SymphonyElixir.AgentMode`

Suggested API:

```elixir
@type backend :: :codex | :claude
@spec for_issue(SymphonyElixir.Linear.Issue.t()) :: backend()
```

Reference behavior:

```elixir
def for_issue(issue) do
  labels = issue |> SymphonyElixir.Linear.Issue.label_names() |> MapSet.new()
  if MapSet.member?(labels, "mode:claude"), do: :claude, else: :codex
end
```

### 4.3 Provider abstraction for execution

Introduce provider abstraction so runner/orchestrator logic is shared:

- New behavior: `SymphonyElixir.AgentBackend`
- New adapter: `SymphonyElixir.AgentBackend.Codex`
- New adapter: `SymphonyElixir.AgentBackend.ClaudeCli`

Behavior sketch:

```elixir
defmodule SymphonyElixir.AgentBackend do
  @callback start_session(Path.t(), map()) :: {:ok, map()} | {:error, term()}
  @callback run_turn(map(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback stop_session(map()) :: :ok
end
```

Then update `AgentRunner` to:

- pick backend from `AgentMode.for_issue(issue)`
- delegate `start_session/run_turn/stop_session` to selected adapter
- preserve existing retry/continue behavior

### 4.4 Claude CLI backend shape

Recommended v1 backend strategy:

- Use `claude -p` per turn.
- Use `--output-format stream-json` for incremental event parsing and compatibility with event-rich output.
- Keep session continuity by supplying a stable `--session-id` per runner session.
- Run with explicit env overrides for isolated runtime directories.
- Preserve current workspace cwd behavior.

Illustrative command:

```bash
claude -p "$PROMPT" \
  --output-format stream-json \
  --permission-mode "$CLAUDE_PERMISSION_MODE" \
  --model "$CLAUDE_MODEL" \
  --session-id "$CLAUDE_SESSION_ID"
```

### 4.5 Config proposal

Keep existing `codex.*` config untouched. Add Claude-specific and routing config:

```yaml
agent:
  default_mode: codex
  mode_label: mode:claude

claude:
  command: claude
  model: sonnet
  permission_mode: plan
  output_format: stream-json
  session_persistence: true
  setting_sources: project,local
  tools: default
  allowed_tools: []
  disallowed_tools: []
  runtime_home: .symphony/claude-home
  runtime_config_home: .symphony/claude-config
  extra_args: []
```

Validation rules to add in `Config`:

- `agent.default_mode` in `codex|claude` (default `codex`)
- `agent.mode_label` non-empty string (default `mode:claude`)
- `claude.command` non-empty when Claude backend can be selected
- `claude.output_format` constrained to `json|stream-json` for machine parsing

### 4.6 Output normalization and parser strategy

Add parser utility in Claude backend:

- Accept either JSON array (`--output-format json`) or NDJSON events (`stream-json`)
- Ignore unknown event types
- Extract canonical fields:
  - final text result
  - model name
  - token usage/cost when present
  - session id
- Return structured failure for:
  - parse errors
  - auth errors (`not logged in`)
  - CLI process failures/timeouts

### 4.7 Observability updates

Current runtime metrics are codex-prefixed. For minimal-risk v1:

- Add `backend` field to running metadata (`codex|claude`)
- Include backend in log lines and status rows
- Keep existing token counters as-is to avoid broad refactor

Optional follow-up: migrate to provider-neutral metric key names.

### 4.8 Failure policy

Fail closed for selected backend in v1:

- If `mode:claude` routes to Claude and Claude initialization/execution fails, do not auto-fallback to Codex.
- Surface explicit backend-specific error and let existing retry/backoff policies operate.

This avoids silent behavior drift.

## 5. Implementation Blueprint (File-Level)

### Phase 1: Routing and abstraction

- Add `elixir/lib/symphony_elixir/agent_mode.ex`
- Add `elixir/lib/symphony_elixir/agent_backend.ex`
- Add `elixir/lib/symphony_elixir/agent_backend/codex.ex` (thin wrapper around current Codex flow)
- Refactor `elixir/lib/symphony_elixir/agent_runner.ex` to use selected backend

### Phase 2: Claude backend + config

- Add `elixir/lib/symphony_elixir/agent_backend/claude_cli.ex`
- Extend `elixir/lib/symphony_elixir/config.ex` schema/getters for `agent.*` and `claude.*`
- Update `elixir/WORKFLOW.md` example config with optional Claude section

### Phase 3: Observability and errors

- Add backend markers in orchestrator/status payloads where useful
- Classify Claude failure reasons for logs/status dashboard

### Phase 4: Tests

- Add `elixir/test/symphony_elixir/agent_mode_test.exs`
- Add backend selection tests in `agent_runner` tests
- Add Claude parser/execution tests with fixture outputs (json array + stream-json lines + auth failure)
- Add config validation tests for new keys

## 6. Validation Plan

### 6.1 Unit tests

Routing matrix:

- `[] -> :codex`
- `["bug"] -> :codex`
- `["mode:claude"] -> :claude`
- mixed case from Linear still routes because labels are normalized upstream

Parser matrix:

- valid `json` array output
- valid `stream-json` event sequence
- unknown event types ignored
- malformed JSON returns explicit parse error

### 6.2 Integration tests

- `AgentRunner` selects Codex when `mode:claude` absent
- `AgentRunner` selects Claude when label present
- Claude command includes expected flags/env/cwd
- Claude auth failure bubbles to orchestrator retry path

### 6.3 Manual validation in staging

- Ticket A without `mode:claude` executes Codex
- Ticket B with `mode:claude` executes Claude
- Verify backend value in logs/dashboard
- Verify retry behavior and issue state transitions remain unchanged

## 7. Risks and Mitigations

- Home-scoped auth mismatch in production
  - Mitigation: explicit runtime home/config dirs + documented auth bootstrap for runtime identity
- CLI output drift
  - Mitigation: event-tolerant parser + pinned tested Claude CLI version
- Safety mismatch across providers
  - Mitigation: explicit permission/tool settings in workflow config
- Hidden user-level hooks/settings affecting runs
  - Mitigation: controlled `setting_sources` and explicit settings path for worker runtime

## 8. Rollout Recommendation

1. Land routing abstraction with Codex adapter first (no behavior change).
2. Land Claude backend behind label routing only.
3. Pilot with a small set of `mode:claude` issues.
4. Observe error rates, retry loops, token/cost behavior, and output quality.
5. Expand usage only after stability thresholds are met.

## 9. Open Questions

- Should conflicting future labels (for example `mode:claude` + `mode:codex`) be rejected explicitly or resolved by fixed precedence?
- Should we add provider-neutral metric names now or in a dedicated migration ticket?
- Do we need explicit startup health checks for Claude auth before dispatching `mode:claude` issues?

## 10. References

### Repository references

- `elixir/lib/symphony_elixir/linear/client.ex:485`
- `elixir/lib/symphony_elixir/linear/issue.ex:40`
- `elixir/lib/symphony_elixir/agent_runner.ex:7`
- `elixir/lib/symphony_elixir/codex/app_server.ex:175`
- `elixir/lib/symphony_elixir/config.ex:31`
- `elixir/lib/symphony_elixir/config.ex:222`
- `elixir/lib/symphony_elixir/issue_filter.ex`
- `elixir/lib/symphony_elixir/orchestrator.ex:277`
- `elixir/WORKFLOW.md:66`

### External references

- Claude Code CLI reference:
  - https://docs.anthropic.com/en/docs/claude-code/cli-reference
- Claude Code settings:
  - https://docs.anthropic.com/en/docs/claude-code/settings
- Claude Code IAM and permission modes:
  - https://docs.anthropic.com/en/docs/claude-code/iam#permission-modes
- Claude Code deployment overview:
  - https://docs.anthropic.com/en/docs/claude-code/deployment/overview
- Claude Code SDK:
  - https://docs.anthropic.com/en/docs/claude-code/sdk
