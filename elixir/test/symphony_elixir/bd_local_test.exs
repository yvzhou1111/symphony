defmodule SymphonyElixir.BdLocalTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Tracker.Bd

  test "config validates bd tracker repo root and command" do
    temp_root = Path.join(System.tmp_dir!(), "symphony-bd-config-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "bd",
      tracker_repo_root: temp_root,
      tracker_command: "bd",
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    assert Config.tracker_kind() == "bd"
    assert Config.bd_command() == "bd"
    assert Config.bd_repo_root() == temp_root
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "bd",
      tracker_repo_root: nil,
      tracker_command: "bd",
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    assert {:error, :missing_bd_repo_root} = Config.validate!()
  end

  test "bd tracker maps ready and in-progress issues and writes comments/state" do
    temp_root = Path.join(System.tmp_dir!(), "symphony-bd-adapter-#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_root)
    script_path = Path.join(temp_root, "fake-bd.sh")

    File.write!(script_path, """
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ "$1" == "ready" ]]; then
      printf '%s\n' '[{"id":"bd-1","title":"Ready task","description":"Ready desc","status":"open","priority":1,"created_at":"2026-03-09T00:00:00Z","updated_at":"2026-03-09T00:00:00Z"}]'
    elif [[ "$1" == "list" && "$4" == "in_progress" ]]; then
      printf '%s\n' '[{"id":"bd-2","title":"Active task","description":"Active desc","status":"in_progress","priority":2,"created_at":"2026-03-09T00:00:00Z","updated_at":"2026-03-09T00:00:00Z"}]'
    elif [[ "$1" == "list" && "$3" == "--all" ]]; then
      printf '%s\n' '[{"id":"bd-1","title":"Ready task","description":"Ready desc","status":"open","priority":1,"created_at":"2026-03-09T00:00:00Z","updated_at":"2026-03-09T00:00:00Z"},{"id":"bd-3","title":"Done task","description":"Done desc","status":"closed","priority":3,"created_at":"2026-03-09T00:00:00Z","updated_at":"2026-03-09T00:00:00Z"}]'
    elif [[ "$1" == "show" ]]; then
      if [[ "$*" == *"bd-3"* ]]; then
        printf '%s\n' '[{"id":"bd-3","title":"Done task","description":"Done desc","status":"closed","priority":3,"created_at":"2026-03-09T00:00:00Z","updated_at":"2026-03-09T00:00:00Z","labels":[],"dependencies":[]}]'
      else
        printf '%s\n' '[{"id":"bd-1","title":"Ready task","description":"Ready desc","status":"open","priority":1,"created_at":"2026-03-09T00:00:00Z","updated_at":"2026-03-09T00:00:00Z","labels":["local"],"dependencies":[{"id":"bd-x","title":"Closed dep","status":"closed"}]},{"id":"bd-2","title":"Active task","description":"Active desc","status":"in_progress","priority":2,"created_at":"2026-03-09T00:00:00Z","updated_at":"2026-03-09T00:00:00Z","labels":[],"dependencies":[]}]'
      fi
    elif [[ "$1" == "comments" ]]; then
      printf '%s\n' '{}'
    elif [[ "$1" == "update" ]]; then
      printf '%s\n' '{}'
    else
      echo "unexpected args: $*" >&2
      exit 1
    fi
    """)

    File.chmod!(script_path, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "bd",
      tracker_repo_root: temp_root,
      tracker_command: script_path,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    assert {:ok, issues} = Bd.fetch_candidate_issues()
    assert Enum.map(issues, & &1.id) == ["bd-1", "bd-2"]
    assert Enum.map(issues, & &1.state) == ["Todo", "In Progress"]
    assert {:ok, done_issues} = Bd.fetch_issues_by_states(["Done"])
    assert Enum.map(done_issues, & &1.id) == ["bd-3"]
    assert :ok = Bd.create_comment("bd-1", "hello")
    assert :ok = Bd.update_issue_state("bd-1", "Done")
  end

  test "symphony-local workflow and task commands prepare a repo" do
    repo_root = Path.join(System.tmp_dir!(), "symphony-local-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo_root)
    File.write!(Path.join(repo_root, "README.md"), "# test\n")
    System.cmd("git", ["-C", repo_root, "init", "-b", "main"])
    System.cmd("git", ["-C", repo_root, "config", "user.name", "Test User"])
    System.cmd("git", ["-C", repo_root, "config", "user.email", "test@example.com"])
    System.cmd("git", ["-C", repo_root, "add", "README.md"])
    System.cmd("git", ["-C", repo_root, "commit", "-m", "initial"])

    script = Path.expand("bin/symphony-local", File.cwd!())
    env = [{"PATH", System.get_env("PATH") <> ":/home/yilis/.local/bin:/home/yilis/.npm-global/bin"}, {"SYMPHONY_LOCAL_CODEX_COMMAND", "/bin/true"}]

    {workflow_path, 0} = System.cmd("bash", [script, "workflow", repo_root, "--port", "43155"], env: env)
    workflow_file = String.trim(workflow_path)
    assert File.exists?(workflow_file)
    workflow_content = File.read!(workflow_file)
    assert workflow_content =~ ~s(kind: "bd")
    assert workflow_content =~ ~s(port: 43155)

    {task_output, 0} = System.cmd("bash", [script, "task", repo_root, "Test local task", "--description", "demo body"], env: env)
    assert task_output =~ "Test local task"

    {show_output, 0} = System.cmd("bd", ["list", "--json", "--limit", "0"], cd: repo_root)
    assert show_output =~ "Test local task"
  end
end
