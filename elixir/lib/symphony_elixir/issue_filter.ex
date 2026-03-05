defmodule SymphonyElixir.IssueFilter do
  @moduledoc """
  Parses and evaluates workflow-configured issue routing filters.
  """

  alias SymphonyElixir.Linear.Issue

  @type op ::
          :eq
          | :neq
          | :in
          | :not_in
          | :includes
          | :includes_any
          | :includes_all
          | :contains
          | :starts_with
          | :ends_with
          | :gt
          | :gte
          | :lt
          | :lte
          | :exists

  @type condition :: %{
          type: :condition,
          field_path: [String.t()],
          op: op(),
          value: term()
        }

  @type filter_node ::
          %{type: :all, filters: [filter_node()]}
          | %{type: :any, filters: [filter_node()]}
          | %{type: :not, filter: filter_node()}
          | condition()

  @type t :: filter_node() | nil

  @spec normalize(term()) :: {:ok, t()} | {:error, term()}
  def normalize(nil), do: {:ok, nil}

  def normalize(filter) do
    filter
    |> normalize_keys()
    |> parse_filter()
  end

  @spec matches?(Issue.t(), t()) :: boolean()
  def matches?(%Issue{}, nil), do: true

  def matches?(%Issue{} = issue, %{type: :all, filters: filters}) do
    Enum.all?(filters, &matches?(issue, &1))
  end

  def matches?(%Issue{} = issue, %{type: :any, filters: filters}) do
    Enum.any?(filters, &matches?(issue, &1))
  end

  def matches?(%Issue{} = issue, %{type: :not, filter: filter}) do
    !matches?(issue, filter)
  end

  def matches?(%Issue{} = issue, %{type: :condition} = condition) do
    evaluate_condition(issue, condition)
  end

  def matches?(_issue, _filter), do: false

  defp parse_filter(filter) when is_list(filter) do
    with {:ok, parsed_filters} <- parse_filter_list(filter) do
      {:ok, %{type: :all, filters: parsed_filters}}
    end
  end

  defp parse_filter(filter) when is_map(filter) do
    cond do
      Map.has_key?(filter, "all") ->
        parse_logical_filter(filter, "all", :all)

      Map.has_key?(filter, "any") ->
        parse_logical_filter(filter, "any", :any)

      Map.has_key?(filter, "not") ->
        parse_not_filter(filter)

      Map.has_key?(filter, "field") ->
        parse_condition_filter(filter)

      true ->
        {:error, {:unsupported_issue_filter_shape, Map.keys(filter)}}
    end
  end

  defp parse_filter(other), do: {:error, {:invalid_issue_filter, other}}

  defp parse_logical_filter(filter, key, type) do
    with :ok <- ensure_only_keys(filter, [key]),
         {:ok, child_filters} <- parse_filter_children(Map.get(filter, key)) do
      {:ok, %{type: type, filters: child_filters}}
    end
  end

  defp parse_not_filter(filter) do
    with :ok <- ensure_only_keys(filter, ["not"]),
         {:ok, child_filter} <- parse_filter(Map.get(filter, "not")) do
      {:ok, %{type: :not, filter: child_filter}}
    end
  end

  defp parse_filter_children(children) when is_list(children) do
    parse_filter_list(children)
  end

  defp parse_filter_children(other), do: {:error, {:invalid_issue_filter_children, other}}

  defp parse_filter_list(children) when is_list(children) do
    if children == [] do
      {:error, :empty_issue_filter_list}
    else
      Enum.reduce_while(children, {:ok, []}, fn child, {:ok, acc} ->
        case parse_filter(child) do
          {:ok, parsed_child} ->
            {:cont, {:ok, [parsed_child | acc]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, parsed_children} -> {:ok, Enum.reverse(parsed_children)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp parse_condition_filter(filter) do
    raw_value = if Map.has_key?(filter, "value"), do: Map.get(filter, "value"), else: :missing

    with :ok <- ensure_only_keys(filter, ["field", "op", "value"]),
         {:ok, field_path} <- parse_field_path(Map.get(filter, "field")),
         {:ok, op} <- parse_operator(Map.get(filter, "op", "eq")),
         {:ok, value} <- parse_condition_value(op, raw_value) do
      {:ok, %{type: :condition, field_path: field_path, op: op, value: value}}
    end
  end

  defp parse_field_path(path) when is_binary(path) do
    path
    |> String.split(".", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> {:error, {:invalid_issue_filter_field, path}}
      segments -> {:ok, segments}
    end
  end

  defp parse_field_path(path) when is_list(path) do
    path
    |> Enum.reduce_while([], fn segment, acc ->
      case normalize_field_segment(segment) do
        {:ok, normalized_segment} ->
          {:cont, [normalized_segment | acc]}

        :error ->
          {:halt, :error}
      end
    end)
    |> case do
      :error -> {:error, {:invalid_issue_filter_field, path}}
      [] -> {:error, {:invalid_issue_filter_field, path}}
      segments -> {:ok, Enum.reverse(segments)}
    end
  end

  defp parse_field_path(path) do
    case normalize_field_segment(path) do
      {:ok, segment} -> {:ok, [segment]}
      :error -> {:error, {:invalid_issue_filter_field, path}}
    end
  end

  defp normalize_field_segment(segment) do
    normalized =
      segment
      |> to_string()
      |> String.trim()

    if normalized == "", do: :error, else: {:ok, normalized}
  rescue
    _ -> :error
  end

  defp parse_operator(op) do
    op
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> case do
      "eq" -> {:ok, :eq}
      "=" -> {:ok, :eq}
      "neq" -> {:ok, :neq}
      "ne" -> {:ok, :neq}
      "not_eq" -> {:ok, :neq}
      "!=" -> {:ok, :neq}
      "in" -> {:ok, :in}
      "not_in" -> {:ok, :not_in}
      "nin" -> {:ok, :not_in}
      "includes" -> {:ok, :includes}
      "includes_any" -> {:ok, :includes_any}
      "includes_all" -> {:ok, :includes_all}
      "contains" -> {:ok, :contains}
      "starts_with" -> {:ok, :starts_with}
      "ends_with" -> {:ok, :ends_with}
      "gt" -> {:ok, :gt}
      "gte" -> {:ok, :gte}
      "lt" -> {:ok, :lt}
      "lte" -> {:ok, :lte}
      "exists" -> {:ok, :exists}
      other -> {:error, {:invalid_issue_filter_operator, other}}
    end
  end

  defp parse_condition_value(:exists, :missing), do: {:ok, true}
  defp parse_condition_value(:exists, value) when is_boolean(value), do: {:ok, value}

  defp parse_condition_value(:exists, value),
    do: {:error, {:invalid_issue_filter_value, :exists, value}}

  defp parse_condition_value(op, value)
       when op in [:in, :not_in, :includes_any, :includes_all] and not is_list(value) do
    {:error, {:invalid_issue_filter_value, op, value}}
  end

  defp parse_condition_value(_op, :missing), do: {:error, {:missing_issue_filter_value, :value}}

  defp parse_condition_value(_op, value), do: {:ok, normalize_keys(value)}

  defp evaluate_condition(%Issue{} = issue, %{field_path: field_path, op: op, value: expected}) do
    values = extract_field_values(issue, field_path)

    case op do
      :eq -> Enum.any?(values, &values_equal?(&1, expected))
      :neq -> Enum.all?(values, &(not values_equal?(&1, expected)))
      :in -> Enum.any?(values, &value_in_expected_list?(&1, expected))
      :not_in -> Enum.all?(values, &(not value_in_expected_list?(&1, expected)))
      :includes -> Enum.any?(values, &values_equal?(&1, expected))
      :includes_any -> expected |> Enum.any?(fn value -> Enum.any?(values, &values_equal?(&1, value)) end)
      :includes_all -> expected |> Enum.all?(fn value -> Enum.any?(values, &values_equal?(&1, value)) end)
      :contains -> Enum.any?(values, &binary_contains?(&1, expected))
      :starts_with -> Enum.any?(values, &binary_starts_with?(&1, expected))
      :ends_with -> Enum.any?(values, &binary_ends_with?(&1, expected))
      :gt -> Enum.any?(values, &compare_order(&1, expected, :gt))
      :gte -> Enum.any?(values, &compare_order(&1, expected, :gte))
      :lt -> Enum.any?(values, &compare_order(&1, expected, :lt))
      :lte -> Enum.any?(values, &compare_order(&1, expected, :lte))
      :exists -> expected == Enum.any?(values, &value_present?/1)
    end
  end

  defp extract_field_values(value, []), do: leaf_values(value)

  defp extract_field_values(value, [segment | rest]) do
    value
    |> next_values_for_segment(segment)
    |> Enum.flat_map(&extract_field_values(&1, rest))
  end

  defp next_values_for_segment(nil, _segment), do: []

  defp next_values_for_segment(values, segment) when is_list(values) do
    case parse_list_index(segment) do
      {:ok, index} ->
        case Enum.at(values, index) do
          nil -> []
          value -> [value]
        end

      :error ->
        Enum.flat_map(values, &next_values_for_segment(&1, segment))
    end
  end

  defp next_values_for_segment(%_{} = struct, segment) do
    struct
    |> Map.from_struct()
    |> next_values_for_segment(segment)
  end

  defp next_values_for_segment(%{} = map, segment) do
    case fetch_map_value(map, segment) do
      :missing -> []
      value -> [value]
    end
  end

  defp next_values_for_segment(_value, _segment), do: []

  defp leaf_values(nil), do: []
  defp leaf_values(values) when is_list(values), do: Enum.flat_map(values, &leaf_values/1)
  defp leaf_values(value), do: [value]

  defp fetch_map_value(map, segment) do
    case Map.fetch(map, segment) do
      {:ok, value} ->
        value

      :error ->
        normalized_segment = normalize_key_segment(segment)

        Enum.find_value(map, :missing, fn {key, value} ->
          if normalize_key_segment(key) == normalized_segment, do: value, else: false
        end)
    end
  end

  defp parse_list_index(segment) do
    case Integer.parse(String.trim(to_string(segment))) do
      {parsed, ""} when parsed >= 0 -> {:ok, parsed}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp value_in_expected_list?(actual, expected) when is_list(expected) do
    Enum.any?(expected, &values_equal?(actual, &1))
  end

  defp value_in_expected_list?(_actual, _expected), do: false

  defp binary_contains?(actual, expected) do
    with {:ok, actual_binary} <- as_normalized_binary(actual),
         {:ok, expected_binary} <- as_normalized_binary(expected) do
      String.contains?(actual_binary, expected_binary)
    else
      :error -> false
    end
  end

  defp binary_starts_with?(actual, expected) do
    with {:ok, actual_binary} <- as_normalized_binary(actual),
         {:ok, expected_binary} <- as_normalized_binary(expected) do
      String.starts_with?(actual_binary, expected_binary)
    else
      :error -> false
    end
  end

  defp binary_ends_with?(actual, expected) do
    with {:ok, actual_binary} <- as_normalized_binary(actual),
         {:ok, expected_binary} <- as_normalized_binary(expected) do
      String.ends_with?(actual_binary, expected_binary)
    else
      :error -> false
    end
  end

  defp compare_order(actual, expected, operator) do
    case comparable_values(actual, expected) do
      {:ok, :number, actual_value, expected_value} ->
        compare_numbers(actual_value, expected_value, operator)

      {:ok, :datetime, %DateTime{} = actual_value, %DateTime{} = expected_value} ->
        compare_datetimes(actual_value, expected_value, operator)

      _ ->
        false
    end
  end

  defp compare_numbers(actual, expected, :gt), do: actual > expected
  defp compare_numbers(actual, expected, :gte), do: actual >= expected
  defp compare_numbers(actual, expected, :lt), do: actual < expected
  defp compare_numbers(actual, expected, :lte), do: actual <= expected

  defp compare_datetimes(actual, expected, :gt), do: DateTime.compare(actual, expected) == :gt

  defp compare_datetimes(actual, expected, :gte) do
    DateTime.compare(actual, expected) in [:gt, :eq]
  end

  defp compare_datetimes(actual, expected, :lt), do: DateTime.compare(actual, expected) == :lt

  defp compare_datetimes(actual, expected, :lte) do
    DateTime.compare(actual, expected) in [:lt, :eq]
  end

  defp comparable_values(actual, expected) when is_number(actual) do
    case parse_number(expected) do
      {:ok, parsed} -> {:ok, :number, actual, parsed}
      :error -> :error
    end
  end

  defp comparable_values(%DateTime{} = actual, expected) do
    case parse_datetime(expected) do
      {:ok, parsed} -> {:ok, :datetime, actual, parsed}
      :error -> :error
    end
  end

  defp comparable_values(_actual, _expected), do: :error

  defp values_equal?(actual, expected) do
    expected = coerce_expected(actual, expected)

    cond do
      is_binary(actual) and is_binary(expected) ->
        normalize_binary(actual) == normalize_binary(expected)

      is_number(actual) and is_number(expected) ->
        actual == expected

      match?(%DateTime{}, actual) and match?(%DateTime{}, expected) ->
        DateTime.compare(actual, expected) == :eq

      true ->
        actual == expected
    end
  end

  defp coerce_expected(actual, expected) when is_number(actual) do
    case parse_number(expected) do
      {:ok, parsed} -> parsed
      :error -> expected
    end
  end

  defp coerce_expected(%DateTime{}, expected) do
    case parse_datetime(expected) do
      {:ok, parsed} -> parsed
      :error -> expected
    end
  end

  defp coerce_expected(_actual, expected), do: expected

  defp parse_number(value) when is_integer(value), do: {:ok, value}
  defp parse_number(value) when is_float(value), do: {:ok, value}

  defp parse_number(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Integer.parse(trimmed) do
      {parsed, ""} ->
        {:ok, parsed}

      _ ->
        case Float.parse(trimmed) do
          {parsed, ""} -> {:ok, parsed}
          _ -> :error
        end
    end
  end

  defp parse_number(_value), do: :error

  defp parse_datetime(%DateTime{} = value), do: {:ok, value}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, parsed, _offset} -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_datetime(_value), do: :error

  defp value_present?(nil), do: false
  defp value_present?(value) when is_binary(value), do: String.trim(value) != ""
  defp value_present?(value) when is_list(value), do: value != []
  defp value_present?(value) when is_map(value), do: map_size(value) > 0
  defp value_present?(_value), do: true

  defp as_normalized_binary(value) when is_binary(value), do: {:ok, normalize_binary(value)}
  defp as_normalized_binary(_value), do: :error

  defp normalize_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp ensure_only_keys(map, allowed_keys) do
    unknown_keys =
      map
      |> Map.keys()
      |> Enum.reject(&(&1 in allowed_keys))

    if unknown_keys == [] do
      :ok
    else
      {:error, {:unsupported_issue_filter_keys, Enum.sort(unknown_keys)}}
    end
  end

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested_value}, acc ->
      Map.put(acc, normalize_key(key), normalize_keys(nested_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp normalize_key_segment(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/u, "")
  end
end
