defmodule SymphonyElixir.AgentMode do
  @moduledoc """
  Resolves which agent backend should run for a given issue.
  """

  alias SymphonyElixir.{Config, Linear.Issue}

  @type backend :: :codex | :claude

  @spec for_issue(Issue.t() | map()) :: backend()
  def for_issue(%Issue{} = issue) do
    labels =
      issue
      |> Issue.label_names()
      |> Enum.map(&normalize_label/1)
      |> MapSet.new()

    mode_label = normalize_label(Config.agent_mode_label())

    if MapSet.member?(labels, mode_label) do
      :claude
    else
      Config.agent_default_mode()
    end
  end

  def for_issue(_issue), do: Config.agent_default_mode()

  defp normalize_label(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_label(_label), do: ""
end
