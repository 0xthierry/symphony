defmodule SymphonyElixir.AgentModeTest do
  use SymphonyElixir.TestSupport

  test "routes to codex by default when mode label is absent" do
    issue = %Issue{identifier: "MT-1", labels: []}

    assert AgentMode.for_issue(issue) == :codex

    issue_with_other_labels = %Issue{identifier: "MT-2", labels: ["bug", "backend"]}

    assert AgentMode.for_issue(issue_with_other_labels) == :codex
  end

  test "routes to claude when mode label is present" do
    issue = %Issue{identifier: "MT-3", labels: ["mode:claude"]}

    assert AgentMode.for_issue(issue) == :claude
  end

  test "mode label matching is case-insensitive" do
    issue = %Issue{identifier: "MT-4", labels: ["Mode:Claude"]}

    assert AgentMode.for_issue(issue) == :claude
  end

  test "supports custom mode label and default mode" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_mode_label: "mode:anthropic",
      agent_default_mode: "claude"
    )

    codex_issue = %Issue{identifier: "MT-5", labels: ["bug"]}
    claude_issue = %Issue{identifier: "MT-6", labels: ["mode:anthropic"]}

    assert AgentMode.for_issue(codex_issue) == :claude
    assert AgentMode.for_issue(claude_issue) == :claude
  end
end
