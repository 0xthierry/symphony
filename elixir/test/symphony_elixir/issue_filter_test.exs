defmodule SymphonyElixir.IssueFilterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.IssueFilter
  alias SymphonyElixir.Linear.Issue

  @created_at ~U[2026-01-01 00:00:00Z]
  @updated_at ~U[2026-01-02 00:00:00Z]

  test "normalize accepts nil and matches all issues" do
    assert {:ok, nil} = IssueFilter.normalize(nil)
    assert IssueFilter.matches?(sample_issue(), nil)
  end

  test "normalize rejects invalid top-level values and empty lists" do
    assert {:error, {:invalid_issue_filter, "bad"}} = IssueFilter.normalize("bad")
    assert {:error, :empty_issue_filter_list} = IssueFilter.normalize([])
  end

  test "logical filters reject unsupported keys and invalid children" do
    assert {:error, {:unsupported_issue_filter_keys, ["extra"]}} =
             IssueFilter.normalize(%{all: [%{field: "priority", value: 2}], extra: true})

    assert {:error, {:invalid_issue_filter_children, "bad"}} =
             IssueFilter.normalize(%{any: "bad"})

    assert {:error, {:unsupported_issue_filter_keys, ["extra"]}} =
             IssueFilter.normalize(%{not: %{field: "priority", value: 2}, extra: true})
  end

  test "condition filters validate shape and value constraints" do
    assert {:error, {:missing_issue_filter_value, :value}} =
             IssueFilter.normalize(%{field: "priority"})

    assert {:error, {:invalid_issue_filter_operator, "unknown"}} =
             IssueFilter.normalize(%{field: "priority", op: "unknown", value: 1})

    assert {:error, {:invalid_issue_filter_value, :in, "bad"}} =
             IssueFilter.normalize(%{field: "priority", op: "in", value: "bad"})

    assert {:error, {:invalid_issue_filter_value, :exists, "bad"}} =
             IssueFilter.normalize(%{field: "priority", op: "exists", value: "bad"})

    assert {:error, {:invalid_issue_filter_field, " "}} =
             IssueFilter.normalize(%{field: " ", op: "eq", value: 1})

    assert {:error, {:invalid_issue_filter_field, []}} =
             IssueFilter.normalize(%{field: [], op: "eq", value: 1})
  end

  test "supports all/any/not composition with list shorthand" do
    filter = [
      %{field: "labels", op: "includes", value: "dev-agent"},
      %{
        any: [
          %{field: "priority", op: "eq", value: 1},
          %{not: %{field: "state", op: "eq", value: "done"}}
        ]
      }
    ]

    assert {:ok, normalized} = IssueFilter.normalize(filter)
    assert IssueFilter.matches?(sample_issue(), normalized)
  end

  test "eq and neq work with case-insensitive strings and scalar field fallback" do
    assert_match_filter(%{field: "state", op: "eq", value: "todo"})
    assert_match_filter(%{field: "state", op: "!=", value: "done"})
    refute_match_filter(%{field: "state", op: "neq", value: "todo"})

    refute_match_filter(%{field: "priority.missing", op: "eq", value: 2})
    assert_match_filter(%{field: "priority.missing", op: "neq", value: 2})
  end

  test "in and not_in evaluate expected lists" do
    assert_match_filter(%{field: "priority", op: "in", value: [1, 2, 3]})
    refute_match_filter(%{field: "priority", op: "in", value: [1, 3, 4]})
    assert_match_filter(%{field: "priority", op: "not_in", value: [1, 3, 4]})
    refute_match_filter(%{field: "priority", op: "nin", value: [1, 2, 3]})
  end

  test "includes operators evaluate list fields" do
    assert_match_filter(%{field: "labels", op: "includes", value: "dev-agent"})
    assert_match_filter(%{field: "labels", op: "includes_any", value: ["foo", "backend"]})
    assert_match_filter(%{field: "labels", op: "includes_all", value: ["backend", "dev-agent"]})
    refute_match_filter(%{field: "labels", op: "includes_all", value: ["backend", "missing"]})
  end

  test "contains/starts_with/ends_with evaluate binary values" do
    assert_match_filter(%{field: "title", op: "contains", value: "dispatch"})
    assert_match_filter(%{field: "title", op: "starts_with", value: "Pick"})
    assert_match_filter(%{field: "title", op: "ends_with", value: "Label"})

    refute_match_filter(%{field: "title", op: "contains", value: "missing"})
    refute_match_filter(%{field: "title", op: "starts_with", value: "missing"})
    refute_match_filter(%{field: "title", op: "ends_with", value: "missing"})

    refute_match_filter(%{field: "title", op: "contains", value: 123})
  end

  test "numeric comparison operators support string number coercion" do
    assert_match_filter(%{field: "priority", op: "gt", value: "1"})
    assert_match_filter(%{field: "priority", op: "gte", value: "2"})
    assert_match_filter(%{field: "priority", op: "lt", value: "3"})
    assert_match_filter(%{field: "priority", op: "lte", value: "2"})

    refute_match_filter(%{field: "priority", op: "gt", value: "9"})
    refute_match_filter(%{field: "priority", op: "lt", value: "1"})

    float_issue = %{sample_issue() | priority: 1.5}
    assert_match_filter(%{field: "priority", op: "eq", value: "1.5"}, float_issue)
  end

  test "datetime comparison and equality support ISO8601 coercion" do
    assert_match_filter(%{field: "created_at", op: "eq", value: "2026-01-01T00:00:00Z"})
    assert_match_filter(%{field: "updated_at", op: "gt", value: "2026-01-01T00:00:00Z"})
    assert_match_filter(%{field: "created_at", op: "lte", value: "2026-01-01T00:00:00Z"})

    refute_match_filter(%{field: "updated_at", op: "lt", value: "2026-01-01T00:00:00Z"})
    refute_match_filter(%{field: "created_at", op: "gt", value: "not-a-date"})
  end

  test "exists supports default true and explicit false" do
    assert_match_filter(%{field: "description", op: "exists"})
    assert_match_filter(%{field: "description", op: "exists", value: true})
    assert_match_filter(%{field: "missing_field", op: "exists", value: false})

    refute_match_filter(%{field: "missing_field", op: "exists"})
    refute_match_filter(%{field: "description", op: "exists", value: false})
  end

  test "field paths traverse nested lists and maps and support index segments" do
    assert_match_filter(%{field: "blocked_by.state", op: "includes", value: "In Progress"})
    assert_match_filter(%{field: ["blocked_by", "0", "identifier"], op: "eq", value: "MT-101"})
    assert_match_filter(%{field: "labels.0", op: "eq", value: "backend"})

    refute_match_filter(%{field: "blocked_by.state", op: "includes", value: "Canceled"})
    refute_match_filter(%{field: "labels.9", op: "eq", value: "backend"})
  end

  test "field key normalization matches snake_case and camelCase variants" do
    assert_match_filter(%{field: "branchName", op: "eq", value: "ticket-branch"})
    assert_match_filter(%{field: "branch_name", op: "eq", value: "ticket-branch"})
  end

  test "unsupported map shapes and fallback matches behavior" do
    assert {:error, {:unsupported_issue_filter_shape, ["bad"]}} =
             IssueFilter.normalize(%{bad: true})

    refute IssueFilter.matches?(%{}, %{type: :condition, field_path: ["state"], op: :eq, value: "todo"})
    refute IssueFilter.matches?(sample_issue(), %{type: :unknown})
  end

  defp assert_match_filter(filter, issue \\ sample_issue()) do
    assert {:ok, normalized} = IssueFilter.normalize(filter)
    assert IssueFilter.matches?(issue, normalized)
  end

  defp refute_match_filter(filter, issue \\ sample_issue()) do
    assert {:ok, normalized} = IssueFilter.normalize(filter)
    refute IssueFilter.matches?(issue, normalized)
  end

  defp sample_issue do
    %Issue{
      id: "issue-100",
      identifier: "MT-100",
      title: "Pick Dispatch Label",
      description: "Issue filter coverage",
      priority: 2,
      state: "Todo",
      branch_name: "ticket-branch",
      url: "https://example.test/issue/MT-100",
      assignee_id: "user-1",
      labels: ["backend", "dev-agent"],
      blocked_by: [
        %{id: "block-1", identifier: "MT-101", state: "In Progress"},
        %{id: "block-2", identifier: "MT-102", state: "Done"}
      ],
      assigned_to_worker: true,
      created_at: @created_at,
      updated_at: @updated_at
    }
  end
end
