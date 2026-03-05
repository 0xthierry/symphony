defmodule SymphonyElixir.AgentRunnerTest do
  use SymphonyElixir.TestSupport

  test "agent runner defaults to codex backend when mode label is absent" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-codex-routing-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CODEX")
      codex_binary = Path.join(test_root, "fake-codex")
      claude_binary = Path.join(test_root, "fake-claude")
      codex_trace = Path.join(test_root, "codex.trace")
      claude_trace = Path.join(test_root, "claude.trace")

      File.mkdir_p!(workspace)
      write_fake_codex!(codex_binary, codex_trace)
      write_fake_claude!(claude_binary, claude_trace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        claude_command: claude_binary,
        claude_output_format: "stream-json"
      )

      issue = %Issue{
        id: "issue-codex-routing",
        identifier: "MT-CODEX",
        title: "Codex routing",
        description: "No mode label",
        state: "In Progress",
        labels: ["backend"]
      }

      assert :ok =
               AgentRunner.run(issue, nil, issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end)

      assert File.read!(codex_trace) =~ "RUN"
      refute File.exists?(claude_trace)
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner selects claude backend when mode label is present" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-claude-routing-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CLAUDE")
      codex_binary = Path.join(test_root, "fake-codex")
      claude_binary = Path.join(test_root, "fake-claude")
      codex_trace = Path.join(test_root, "codex.trace")
      claude_trace = Path.join(test_root, "claude.trace")

      File.mkdir_p!(workspace)
      write_fake_codex!(codex_binary, codex_trace)
      write_fake_claude!(claude_binary, claude_trace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        claude_command: "#{claude_binary} --base",
        claude_model: "sonnet",
        claude_output_format: "stream-json"
      )

      issue = %Issue{
        id: "issue-claude-routing",
        identifier: "MT-CLAUDE",
        title: "Claude routing",
        description: "Mode label present",
        state: "In Progress",
        labels: ["mode:claude"]
      }

      assert :ok =
               AgentRunner.run(issue, nil, issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Done"}]} end)

      trace = File.read!(claude_trace)
      assert trace =~ "ARGV:--base"
      assert trace =~ "--output-format stream-json"
      assert trace =~ "--session-id"
      refute File.exists?(codex_trace)
    after
      File.rm_rf(test_root)
    end
  end

  defp write_fake_codex!(path, trace_file) do
    File.write!(path, """
    #!/bin/sh
    trace_file=\"#{trace_file}\"
    printf 'RUN\\n' >> \"$trace_file\"
    count=0

    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"
      case \"$count\" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-routing"}}}'
          ;;
        3)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-routing"}}}'
          ;;
        4)
          printf '%s\\n' '{"method":"turn/completed"}'
          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(path, 0o755)
  end

  defp write_fake_claude!(path, trace_file) do
    File.write!(path, """
    #!/bin/sh
    trace_file=\"#{trace_file}\"
    printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"
    printf '%s\\n' '{"type":"result","result":"OK","usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}'
    """)

    File.chmod!(path, 0o755)
  end
end
