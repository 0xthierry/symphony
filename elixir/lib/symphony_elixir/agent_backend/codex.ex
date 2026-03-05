defmodule SymphonyElixir.AgentBackend.Codex do
  @moduledoc """
  Adapter over the existing Codex app-server client.
  """

  @behaviour SymphonyElixir.AgentBackend

  alias SymphonyElixir.Codex.AppServer

  @impl true
  def start_session(workspace), do: AppServer.start_session(workspace)

  @impl true
  def run_turn(session, prompt, issue, opts \\ []), do: AppServer.run_turn(session, prompt, issue, opts)

  @impl true
  def stop_session(session), do: AppServer.stop_session(session)
end
