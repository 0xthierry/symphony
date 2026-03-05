defmodule SymphonyElixir.AgentBackend.ClaudeCliTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentBackend.ClaudeCli

  test "parse_cli_output handles JSON array output" do
    payload = [
      %{"type" => "system/init", "model" => "sonnet"},
      %{
        "type" => "result",
        "result" => "OK",
        "usage" => %{"input_tokens" => 7, "output_tokens" => 5, "total_tokens" => 12},
        "session_id" => "session-json"
      }
    ]

    assert {:ok, parsed} = ClaudeCli.parse_cli_output(Jason.encode!(payload))
    assert parsed.result == "OK"
    assert parsed.model == "sonnet"
    assert parsed.usage == %{input_tokens: 7, output_tokens: 5, total_tokens: 12}
    assert parsed.claude_session_id == "session-json"
  end

  test "parse_cli_output handles stream-json events and ignores unknown event types" do
    output =
      [
        ~s({"type":"hook_started","message":"boot"}),
        ~s({"type":"assistant","message":"intermediate"}),
        ~s({"type":"result","result":"Done","usage":{"input_tokens":3,"output_tokens":2,"total_tokens":5},"model":"sonnet-4","session_id":"session-stream"})
      ]
      |> Enum.join("\n")

    assert {:ok, parsed} = ClaudeCli.parse_cli_output(output)
    assert parsed.result == "Done"
    assert parsed.model == "sonnet-4"
    assert parsed.usage == %{input_tokens: 3, output_tokens: 2, total_tokens: 5}
    assert parsed.claude_session_id == "session-stream"
  end

  test "parse_cli_output returns auth error when claude reports missing login" do
    output =
      Jason.encode!([
        %{
          "type" => "result",
          "result" => "Not logged in. Please run /login to continue."
        }
      ])

    assert {:error, {:claude_auth_error, _message}} = ClaudeCli.parse_cli_output(output)
  end

  test "run_turn executes claude with configured flags and workspace-scoped runtime dirs" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-claude-cli-run-turn-#{System.unique_integer([:positive])}"
      )

    trace_var = "SYMP_TEST_CLAUDE_TRACE"
    previous_trace = System.get_env(trace_var)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-CLAUDE")
      claude_binary = Path.join(test_root, "fake-claude")
      trace_file = Path.join(test_root, "claude.trace")

      File.mkdir_p!(workspace)

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env(trace_var, previous_trace)
        else
          System.delete_env(trace_var)
        end
      end)

      System.put_env(trace_var, trace_file)

      File.write!(claude_binary, """
      #!/bin/sh
      trace_file=\"${SYMP_TEST_CLAUDE_TRACE:-/tmp/claude.trace}\"
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"
      printf 'CWD:%s\\n' \"$PWD\" >> \"$trace_file\"
      printf 'HOME:%s\\n' \"$HOME\" >> \"$trace_file\"
      printf 'XDG_CONFIG_HOME:%s\\n' \"$XDG_CONFIG_HOME\" >> \"$trace_file\"
      printf '%s\\n' '{"type":"result","result":"OK","usage":{"input_tokens":2,"output_tokens":1,"total_tokens":3},"model":"sonnet-test","session_id":"claude-session"}'
      """)

      File.chmod!(claude_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        claude_command: "#{claude_binary} --base",
        claude_model: "sonnet-4",
        claude_permission_mode: "plan",
        claude_output_format: "stream-json",
        claude_session_persistence: false,
        claude_setting_sources: "project,local",
        claude_tools: "default",
        claude_allowed_tools: ["exec_command"],
        claude_disallowed_tools: ["request_user_input"],
        claude_runtime_home: ".symphony/claude-home",
        claude_runtime_config_home: ".symphony/claude-config",
        claude_extra_args: ["--extra-flag", "value"]
      )

      issue = %Issue{
        id: "issue-claude",
        identifier: "MT-CLAUDE",
        title: "Claude turn",
        description: "Validate CLI invocation",
        state: "In Progress",
        labels: ["mode:claude"]
      }

      assert {:ok, session} = ClaudeCli.start_session(workspace)
      assert {:ok, result} = ClaudeCli.run_turn(session, "Respond with OK", issue)
      assert result.result == "OK"

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert argv_line = Enum.find(lines, &String.starts_with?(&1, "ARGV:"))
      assert argv_line =~ "--base"
      assert argv_line =~ "-p Respond with OK"
      assert argv_line =~ "--output-format stream-json"
      assert argv_line =~ "--permission-mode plan"
      assert argv_line =~ "--model sonnet-4"
      assert argv_line =~ "--session-id"
      assert argv_line =~ "--setting-sources project,local"
      assert argv_line =~ "--tools default"
      assert argv_line =~ "--allowedTools exec_command"
      assert argv_line =~ "--disallowedTools request_user_input"
      assert argv_line =~ "--no-session-persistence"
      assert argv_line =~ "--extra-flag value"

      assert cwd_line = Enum.find(lines, &String.starts_with?(&1, "CWD:"))
      assert cwd_line == "CWD:#{Path.expand(workspace)}"

      assert home_line = Enum.find(lines, &String.starts_with?(&1, "HOME:"))
      assert home_line == "HOME:#{Path.join(Path.expand(workspace), ".symphony/claude-home")}"

      assert config_home_line = Enum.find(lines, &String.starts_with?(&1, "XDG_CONFIG_HOME:"))

      assert config_home_line ==
               "XDG_CONFIG_HOME:#{Path.join(Path.expand(workspace), ".symphony/claude-config")}"
    after
      System.delete_env(trace_var)
      File.rm_rf(test_root)
    end
  end
end
