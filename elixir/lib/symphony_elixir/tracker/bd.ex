defmodule SymphonyElixir.Tracker.Bd do
  @moduledoc """
  Local beads/bd tracker adapter for Ubuntu-first Symphony workflows.
  """

  alias SymphonyElixir.{Config, Linear.Issue}

  @ready_state "Todo"
  @in_progress_state "In Progress"
  @blocked_state "Blocked"
  @done_state "Done"

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    with {:ok, ready_entries} <- run_json(["ready", "--json", "--limit", "0"]),
         {:ok, in_progress_entries} <- run_json(["list", "--json", "--status", "in_progress", "--limit", "0"]),
         issue_ids <- unique_issue_ids(ready_entries ++ in_progress_entries),
         {:ok, issues} <- fetch_issue_details(issue_ids) do
      {:ok, issues}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    with {:ok, entries} <- run_json(["list", "--json", "--all", "--limit", "0"]),
         issues <- entries |> Enum.map(&issue_from_summary/1) |> Enum.filter(&match_state?(&1, state_names)),
         {:ok, detailed_issues} <- fetch_issue_details(Enum.map(issues, & &1.id)) do
      {:ok, Enum.filter(detailed_issues, &match_state?(&1, state_names))}
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    fetch_issue_details(issue_ids)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    case run_json(["comments", "add", issue_id, body, "--json"]) do
      {:ok, _payload} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) when is_binary(issue_id) and is_binary(state_name) do
    case run_json(["update", issue_id, "--status", bd_status_for_state(state_name), "--json"]) do
      {:ok, _payload} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_issue_details([]), do: {:ok, []}

  defp fetch_issue_details(issue_ids) when is_list(issue_ids) do
    args = ["show" | issue_ids] ++ ["--json"]

    with {:ok, payload} <- run_json(args) do
      {:ok,
       payload
       |> List.wrap()
       |> Enum.map(&issue_from_detail/1)
       |> Enum.filter(&match?(%Issue{id: id} when is_binary(id), &1))}
    end
  end

  defp run_json(args) do
    command = build_command(args)

    case System.cmd("sh", ["-lc", command], cd: repo_root(), stderr_to_stdout: true) do
      {output, 0} ->
        decode_json(output)

      {output, status} ->
        {:error, {:bd_command_failed, status, String.trim(output)}}
    end
  rescue
    error ->
      {:error, {:bd_command_failed, Exception.message(error)}}
  end

  defp build_command(args) do
    ([Config.bd_command()] ++ Enum.map(args, &shell_escape/1))
    |> Enum.join(" ")
  end

  defp repo_root do
    Config.bd_repo_root() || File.cwd!()
  end

  defp decode_json(output) do
    trimmed = String.trim(output)

    case Jason.decode(trimmed) do
      {:ok, payload} -> {:ok, payload}
      {:error, reason} -> {:error, {:invalid_bd_json, Exception.message(reason), trimmed}}
    end
  end

  defp unique_issue_ids(entries) do
    entries
    |> List.wrap()
    |> Enum.map(fn entry -> Map.get(entry, "id") || Map.get(entry, :id) end)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp match_state?(%Issue{state: state_name}, states) when is_binary(state_name) and is_list(states) do
    normalized = normalize_state(state_name)
    Enum.any?(states, &(normalize_state(&1) == normalized))
  end

  defp match_state?(_, _), do: false

  defp issue_from_summary(payload) do
    %Issue{
      id: Map.get(payload, "id"),
      identifier: Map.get(payload, "id"),
      title: Map.get(payload, "title"),
      description: Map.get(payload, "description"),
      priority: Map.get(payload, "priority"),
      state: state_from_bd_status(Map.get(payload, "status")),
      url: "bd://" <> to_string(Map.get(payload, "id")),
      created_at: parse_datetime(Map.get(payload, "created_at")),
      updated_at: parse_datetime(Map.get(payload, "updated_at")),
      blocked_by: []
    }
  end

  defp issue_from_detail(payload) do
    dependencies = Map.get(payload, "dependencies") || []

    %Issue{
      id: Map.get(payload, "id"),
      identifier: Map.get(payload, "id"),
      title: Map.get(payload, "title"),
      description: Map.get(payload, "description"),
      priority: Map.get(payload, "priority"),
      state: state_from_bd_status(Map.get(payload, "status")),
      assignee_id: Map.get(payload, "assignee") || Map.get(payload, "owner"),
      url: "bd://" <> to_string(Map.get(payload, "id")),
      created_at: parse_datetime(Map.get(payload, "created_at")),
      updated_at: parse_datetime(Map.get(payload, "updated_at")),
      labels: List.wrap(Map.get(payload, "labels") || []),
      blocked_by: Enum.map(dependencies, &dependency_to_blocker/1)
    }
  end

  defp dependency_to_blocker(payload) do
    %{
      id: Map.get(payload, "id"),
      identifier: Map.get(payload, "id"),
      title: Map.get(payload, "title"),
      state: state_from_bd_status(Map.get(payload, "status"))
    }
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> parsed
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp state_from_bd_status(status) when is_binary(status) do
    case normalize_state(status) do
      "open" -> @ready_state
      "in_progress" -> @in_progress_state
      "blocked" -> @blocked_state
      "deferred" -> @blocked_state
      "closed" -> @done_state
      other -> other
    end
  end

  defp state_from_bd_status(_status), do: @ready_state

  defp bd_status_for_state(state_name) when is_binary(state_name) do
    case normalize_state(state_name) do
      "todo" -> "open"
      "in progress" -> "in_progress"
      "blocked" -> "blocked"
      "rework" -> "open"
      "human review" -> "in_progress"
      "merging" -> "in_progress"
      "done" -> "closed"
      "closed" -> "closed"
      "cancelled" -> "closed"
      "canceled" -> "closed"
      "duplicate" -> "closed"
      _ -> "open"
    end
  end

  defp shell_escape(value) when is_binary(value) do
    escaped = String.replace(value, "'", "'\\''")
    "'#{escaped}'"
  end

  defp normalize_state(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_value), do: ""
end
