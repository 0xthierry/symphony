defmodule SymphonyElixir.AgentBackend.ClaudeCli do
  @moduledoc """
  Claude Code backend that runs one non-interactive CLI turn per invocation.
  """

  @behaviour SymphonyElixir.AgentBackend

  require Logger

  alias SymphonyElixir.Config

  @type session :: %{
          workspace: Path.t(),
          metadata: map(),
          claude_session_id: String.t()
        }

  @type parsed_output :: %{
          events: [map()],
          result: String.t(),
          model: String.t() | nil,
          usage: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer(), total_tokens: non_neg_integer()},
          claude_session_id: String.t() | nil
        }

  @impl true
  @spec start_session(Path.t()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace) do
    with :ok <- validate_workspace_cwd(workspace) do
      expanded_workspace = Path.expand(workspace)

      {:ok,
       %{
         workspace: expanded_workspace,
         metadata: %{backend: "claude"},
         claude_session_id: session_id()
       }}
    end
  end

  @impl true
  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%{workspace: workspace, claude_session_id: claude_session_id, metadata: metadata}, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    turn_id = Integer.to_string(System.unique_integer([:positive]))
    session_id = "#{claude_session_id}-#{turn_id}"

    emit_message(
      on_message,
      :session_started,
      %{
        session_id: session_id,
        thread_id: claude_session_id,
        turn_id: turn_id,
        backend: "claude"
      },
      metadata
    )

    with {:ok, invocation} <- build_invocation(workspace, claude_session_id, prompt),
         :ok <- ensure_runtime_dirs(invocation.env),
         {:ok, output} <- run_claude(invocation),
         {:ok, parsed_output} <- parse_cli_output(output) do
      payload = %{
        "method" => "turn/completed",
        "backend" => "claude",
        "usage" => parsed_output.usage,
        "model" => parsed_output.model,
        "result" => parsed_output.result
      }

      emit_message(
        on_message,
        :notification,
        %{session_id: session_id, payload: payload, usage: parsed_output.usage},
        metadata
      )

      {:ok,
       %{
         result: parsed_output.result,
         session_id: session_id,
         thread_id: claude_session_id,
         turn_id: turn_id,
         model: parsed_output.model,
         usage: parsed_output.usage
       }}
    else
      {:error, reason} ->
        Logger.warning("Claude session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

        emit_message(
          on_message,
          :turn_ended_with_error,
          %{session_id: session_id, reason: reason},
          metadata
        )

        {:error, reason}
    end
  end

  @impl true
  @spec stop_session(session()) :: :ok
  def stop_session(_session), do: :ok

  @doc false
  @spec parse_cli_output(String.t()) :: {:ok, parsed_output()} | {:error, term()}
  def parse_cli_output(output) when is_binary(output) do
    with {:ok, events} <- decode_events(output) do
      parse_events(events, output)
    end
  end

  def parse_cli_output(_output), do: {:error, {:claude_parse_error, :invalid_output}}

  defp build_invocation(workspace, session_id, prompt) do
    with {:ok, executable, base_args} <- parse_command(Config.claude_command()) do
      args =
        base_args
        |> Kernel.++([
          "-p",
          prompt,
          "--output-format",
          Config.claude_output_format(),
          "--permission-mode",
          Config.claude_permission_mode(),
          "--session-id",
          session_id
        ])
        |> maybe_append_option("--model", Config.claude_model())
        |> maybe_append_option("--setting-sources", Config.claude_setting_sources())
        |> maybe_append_option("--tools", Config.claude_tools())
        |> append_repeated_option("--allowedTools", Config.claude_allowed_tools())
        |> append_repeated_option("--disallowedTools", Config.claude_disallowed_tools())
        |> maybe_append_flag("--no-session-persistence", not Config.claude_session_persistence?())
        |> Kernel.++(Config.claude_extra_args())

      {:ok,
       %{
         executable: executable,
         args: args,
         workspace: workspace,
         env: [
           {"HOME", Config.claude_runtime_home(workspace)},
           {"XDG_CONFIG_HOME", Config.claude_runtime_config_home(workspace)}
         ]
       }}
    end
  end

  defp parse_command(command) when is_binary(command) do
    case command |> OptionParser.split() |> Enum.reject(&(&1 == "")) do
      [executable | args] -> {:ok, executable, args}
      _ -> {:error, :missing_claude_command}
    end
  rescue
    _ ->
      {:error, :missing_claude_command}
  end

  defp maybe_append_option(args, _flag, value) when value in [nil, ""], do: args
  defp maybe_append_option(args, flag, value), do: args ++ [flag, value]

  defp append_repeated_option(args, _flag, values) when values in [nil, []], do: args

  defp append_repeated_option(args, flag, values) when is_list(values) do
    Enum.reduce(values, args, fn value, acc ->
      if is_binary(value) and String.trim(value) != "" do
        acc ++ [flag, value]
      else
        acc
      end
    end)
  end

  defp maybe_append_flag(args, _flag, false), do: args
  defp maybe_append_flag(args, flag, true), do: args ++ [flag]

  defp ensure_runtime_dirs(env) when is_list(env) do
    env
    |> Enum.filter(fn {name, value} ->
      name in ["HOME", "XDG_CONFIG_HOME"] and is_binary(value) and String.trim(value) != ""
    end)
    |> Enum.reduce_while(:ok, fn {_name, path}, _acc ->
      case File.mkdir_p(path) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:claude_runtime_dir_unavailable, path, reason}}}
      end
    end)
  end

  defp run_claude(%{executable: executable, args: args, workspace: workspace, env: env}) do
    timeout_ms = Config.codex_turn_timeout_ms()

    task =
      Task.async(fn ->
        System.cmd(executable, args,
          cd: workspace,
          env: env,
          stderr_to_stdout: true
        )
      end)

    try do
      case Task.await(task, timeout_ms) do
        {output, 0} ->
          {:ok, output}

        {output, status} when is_integer(status) ->
          if auth_failure_text?(output) do
            {:error, {:claude_auth_error, summarize_output(output)}}
          else
            {:error, {:claude_command_failed, status, summarize_output(output)}}
          end
      end
    rescue
      error ->
        {:error, {:claude_command_failed_to_start, Exception.message(error)}}
    catch
      :exit, {:timeout, _} ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:claude_command_timeout, timeout_ms}}

      :exit, reason ->
        {:error, {:claude_command_failed_to_start, Exception.format_exit(reason)}}
    end
  end

  defp decode_events(output) when is_binary(output) do
    trimmed = String.trim(output)

    if trimmed == "" do
      {:error, {:claude_parse_error, :empty_output}}
    else
      case Jason.decode(trimmed) do
        {:ok, decoded} ->
          decode_json_payload(decoded)

        {:error, _reason} ->
          decode_ndjson_lines(trimmed)
      end
    end
  end

  defp decode_json_payload(%{} = payload), do: {:ok, [payload]}

  defp decode_json_payload(payload) when is_list(payload) do
    events = Enum.flat_map(payload, &normalize_event_container/1)

    if events == [] do
      {:error, {:claude_parse_error, :no_events}}
    else
      {:ok, events}
    end
  end

  defp decode_json_payload(_payload), do: {:error, {:claude_parse_error, :unexpected_json_shape}}

  defp decode_ndjson_lines(output) do
    {events, rejected_lines} =
      output
      |> String.split("\n", trim: true)
      |> Enum.reduce({[], []}, fn line, {acc_events, acc_rejected} ->
        case Jason.decode(line) do
          {:ok, decoded} ->
            {acc_events ++ normalize_event_container(decoded), acc_rejected}

          {:error, _reason} ->
            {acc_events, [line | acc_rejected]}
        end
      end)

    case events do
      [] -> {:error, {:claude_parse_error, {:no_json_events, summarize_output(Enum.reverse(rejected_lines) |> Enum.join("\n"))}}}
      _ -> {:ok, events}
    end
  end

  defp normalize_event_container(%{} = event), do: [event]

  defp normalize_event_container(events) when is_list(events) do
    Enum.flat_map(events, &normalize_event_container/1)
  end

  defp normalize_event_container(_event), do: []

  defp parse_events(events, output) do
    result = find_result(events)
    model = find_model(events)
    usage = find_usage(events)
    session_id = find_session_id(events)

    cond do
      auth_failure_text?(output) or auth_failure_text?(result) ->
        {:error, {:claude_auth_error, summarize_output(output)}}

      is_binary(result) and String.trim(result) != "" ->
        {:ok,
         %{
           events: events,
           result: result,
           model: model,
           usage: usage,
           claude_session_id: session_id
         }}

      true ->
        {:error, {:claude_parse_error, :missing_result}}
    end
  end

  defp find_result(events) when is_list(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(&result_text_from_event/1)
  end

  defp result_text_from_event(%{} = event) do
    fallback_text = extract_text_from_value(event)

    direct_result =
      map_get(event, ["result", :result]) ||
        map_get(event, ["message", :message]) ||
        map_get(event, ["text", :text]) ||
        fallback_text

    if is_binary(direct_result) do
      normalize_non_empty_binary(direct_result)
    else
      nil
    end
  end

  defp result_text_from_event(_event), do: nil

  defp extract_text_from_value(value) when is_binary(value), do: String.trim(value)

  defp extract_text_from_value(value) when is_list(value) do
    value
    |> Enum.find_value(&extract_text_from_value/1)
  end

  defp extract_text_from_value(%{} = value) do
    keys = ["result", :result, "text", :text, "message", :message, "content", :content]

    Enum.find_value(keys, fn key ->
      value
      |> Map.get(key)
      |> extract_text_from_value()
      |> normalize_non_empty_binary()
    end)
  end

  defp extract_text_from_value(_value), do: nil

  defp find_model(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn event ->
      event
      |> map_get(["model", :model, "model_name", :model_name, "modelName", :modelName])
      |> normalize_non_empty_binary()
    end)
  end

  defp find_usage(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(&usage_from_value/1)
    |> normalize_usage()
  end

  defp usage_from_value(%{} = value) do
    if integer_token_map?(value) do
      value
    else
      nested_keys = ["usage", :usage, "tokenUsage", :tokenUsage, "tokens", :tokens, "result", :result]

      Enum.find_value(nested_keys, fn key ->
        value
        |> Map.get(key)
        |> usage_from_value()
      end) ||
        Enum.find_value(Map.values(value), &usage_from_value/1)
    end
  end

  defp usage_from_value(values) when is_list(values) do
    Enum.find_value(values, &usage_from_value/1)
  end

  defp usage_from_value(_value), do: nil

  defp find_session_id(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn event ->
      event
      |> map_get(["session_id", :session_id, "sessionId", :sessionId])
      |> normalize_non_empty_binary()
    end)
  end

  defp normalize_usage(nil), do: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}

  defp normalize_usage(usage) do
    input =
      map_get(usage, [
        "input_tokens",
        :input_tokens,
        "prompt_tokens",
        :prompt_tokens,
        "input",
        :input,
        "inputTokens",
        :inputTokens,
        "promptTokens",
        :promptTokens
      ])
      |> integer_like()

    output =
      map_get(usage, [
        "output_tokens",
        :output_tokens,
        "completion_tokens",
        :completion_tokens,
        "output",
        :output,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])
      |> integer_like()

    total =
      map_get(usage, ["total_tokens", :total_tokens, "total", :total, "totalTokens", :totalTokens])
      |> integer_like()

    input_tokens = input || 0
    output_tokens = output || 0

    %{
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      total_tokens: total || max(0, input_tokens + output_tokens)
    }
  end

  defp integer_token_map?(payload) when is_map(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    Enum.any?(token_fields, fn field ->
      payload
      |> Map.get(field)
      |> integer_like()
      |> is_integer()
    end)
  end

  defp map_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> Map.get(payload, field) end)
  end

  defp normalize_non_empty_binary(value) when is_binary(value) do
    trimmed = String.trim(value)
    if(trimmed == "", do: nil, else: trimmed)
  end

  defp normalize_non_empty_binary(_value), do: nil

  defp summarize_output(output) when is_binary(output) do
    output
    |> String.replace("\n", "\\n")
    |> String.trim()
    |> String.slice(0, 500)
  end

  defp summarize_output(output), do: inspect(output)

  defp auth_failure_text?(value) when is_binary(value) do
    normalized = String.downcase(value)

    String.contains?(normalized, "not logged in") or
      String.contains?(normalized, "please run /login") or
      String.contains?(normalized, "claude auth login")
  end

  defp auth_failure_text?(_value), do: false

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} when parsed >= 0 -> parsed
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil

  defp validate_workspace_cwd(workspace) when is_binary(workspace) do
    workspace_path = Path.expand(workspace)
    workspace_root = Path.expand(Config.workspace_root())

    root_prefix = workspace_root <> "/"

    cond do
      workspace_path == workspace_root ->
        {:error, {:invalid_workspace_cwd, :workspace_root, workspace_path}}

      not String.starts_with?(workspace_path <> "/", root_prefix) ->
        {:error, {:invalid_workspace_cwd, :outside_workspace_root, workspace_path, workspace_root}}

      true ->
        :ok
    end
  end

  defp validate_workspace_cwd(_workspace), do: {:error, {:invalid_workspace_cwd, :invalid_path}}

  defp session_id do
    "claude-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp default_on_message(_message), do: :ok

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp issue_context(_issue), do: "issue_id=n/a issue_identifier=n/a"
end
