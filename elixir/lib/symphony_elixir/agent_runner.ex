defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in an isolated workspace with a selected backend.
  """

  require Logger
  alias SymphonyElixir.AgentBackend.{ClaudeCli, Codex}
  alias SymphonyElixir.AgentMode
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    backend_module = backend_module_for_issue(issue)
    backend_name = backend_name_for_module(backend_module)

    Logger.info("Starting agent run for #{issue_context(issue)} backend=#{backend_name}")

    case Workspace.create_for_issue(issue) do
      {:ok, workspace} ->
        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue),
               :ok <- run_backend_turns(backend_module, backend_name, workspace, issue, codex_update_recipient, opts) do
            :ok
          else
            {:error, reason} ->
              Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
              raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
          end
        after
          Workspace.run_after_run_hook(workspace, issue)
        end

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp run_backend_turns(backend_module, backend_name, workspace, issue, codex_update_recipient, opts) do
    run_context = %{
      backend_module: backend_module,
      backend_name: backend_name,
      workspace: workspace,
      codex_update_recipient: codex_update_recipient,
      opts: opts,
      max_turns: Keyword.get(opts, :max_turns, Config.agent_max_turns()),
      issue_state_fetcher: Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    }

    with {:ok, session} <- backend_module.start_session(workspace) do
      try do
        do_run_backend_turns(Map.put(run_context, :session, session), issue, 1)
      after
        backend_module.stop_session(session)
      end
    end
  end

  defp do_run_backend_turns(
         %{
           backend_module: backend_module,
           backend_name: backend_name,
           session: app_session,
           workspace: workspace,
           codex_update_recipient: codex_update_recipient,
           opts: opts,
           issue_state_fetcher: issue_state_fetcher,
           max_turns: max_turns
         } = run_context,
         issue,
         turn_number
       ) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns, backend_name)

    with {:ok, turn_session} <-
           backend_module.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} backend=#{backend_name} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} backend=#{backend_name} after normal turn completion turn=#{turn_number}/#{max_turns}")

          do_run_backend_turns(run_context, refreshed_issue, turn_number + 1)

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns, _backend_name), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns, backend_name) do
    """
    Continuation guidance:

    - The previous #{String.capitalize(backend_name)} turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.linear_active_states()
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp backend_module_for_issue(issue) do
    case AgentMode.for_issue(issue) do
      :claude -> ClaudeCli
      _ -> Codex
    end
  end

  defp backend_name_for_module(backend_module) when backend_module == ClaudeCli, do: "claude"
  defp backend_name_for_module(backend_module) when backend_module == Codex, do: "codex"
  defp backend_name_for_module(_backend_module), do: "codex"
end
