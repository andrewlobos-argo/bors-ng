defmodule Aelita2.Attemptor do
  @moduledoc """
  An "Attemptor" manages the set of running attempts (that is, "try jobs").
  It implements this set of rules:

    * When a patch is tried,
      We immediately merge it with master into the trying branch.
    * The project's CI is occasionally polled,
      if a attempt is currently running.
      After polling, the completion logic is run.
    * If a notification related to the underlying CI is received,
      the completion logic is run.
    * When the completion logic is run, the either succeeded or failed.
  """

  use GenServer

  alias Aelita2.Attempt
  alias Aelita2.AttemptStatus
  alias Aelita2.Repo
  alias Aelita2.Patch
  alias Aelita2.Project
  alias Aelita2.GitHub

  # Every half-hour
  @poll_period 30 * 60 * 1000

  # Public API

  def start_link(project_id) do
    GenServer.start_link(__MODULE__, project_id)
  end

  def tried(pid, patch_id, arguments) when is_integer(patch_id) do
    GenServer.cast(pid, {:tried, patch_id, arguments})
  end

  def status(pid, stat) do
    GenServer.cast(pid, {:status, stat})
  end

  # Server callbacks

  def init(project_id) do
    Process.send_after(self(), :poll, @poll_period)
    {:ok, project_id}
  end

  def handle_cast(args, project_id) do
    Repo.transaction(fn -> do_handle_cast(args, project_id) end)
    {:noreply, project_id}
  end

  def do_handle_cast({:tried, patch_id, arguments}, project_id) do
    patch = Repo.get!(Patch, patch_id)
    ^project_id = patch.project_id
    project = Repo.get!(Project, project_id)
    case Repo.one(Attempt.all_for_patch(patch_id, :incomplete)) do
      nil ->
        # There is no currently running attempt
        # Start one
        patch_id
        |> Attempt.new()
        |> Repo.insert!()
        |> start_attempt(project, patch, arguments)
      _attempt ->
        # There is already a running attempt
        project
        |> get_repo_conn()
        |> send_message(patch, :not_awaiting_review)
    end
  end

  def do_handle_cast({:status, {commit, identifier, state, url}}, project_id) do
    attempt = Repo.all(Attempt.get_by_commit(commit, :incomplete))
    state = AttemptStatus.numberize_state(state)
    case attempt do
      [attempt] ->
        patch = Repo.get!(Patch, attempt.patch_id)
        ^project_id = patch.project_id
        project = Repo.get!(Project, project_id)
        attempt.id
        |> AttemptStatus.get_for_attempt(identifier)
        |> Repo.update_all([set: [state: state, url: url]])
        if attempt.state == Attempt.numberize_state(:running) do
          maybe_complete_attempt(attempt, project, patch)
        end
      [] -> :ok
    end
  end

  def handle_info(:poll, project_id) do
    Repo.transaction(fn -> poll(project_id) end)
    Process.send_after(self(), :poll, @poll_period)
    {:noreply, project_id}
  end

  # Private implementation details

  defp poll(project_id) do
    project = Repo.get(Project, project_id)
    project_id
    |> Attempt.all_for_project(:incomplete)
    |> Repo.all()
    |> Enum.filter(&Attempt.next_poll_is_past(&1, project))
    |> Enum.map(&poll_attempt(&1, project))
  end

  defp start_attempt(attempt, project, patch, arguments) do
    stmp = "#{project.trying_branch}.tmp"
    repo_conn = get_repo_conn(project)
    GitHub.copy_branch!(
      repo_conn,
      project.master_branch,
      stmp)
    merged = GitHub.merge_branch!(
      repo_conn,
      %{
        from: patch.commit,
        to: stmp,
        commit_message: "Try \##{patch.pr_xref}:#{arguments}"})
    case merged do
      :conflict ->
        send_message(repo_conn, patch, {:conflict, :failed})
        err = Attempt.numberize_state(:error)
        attempt
        |> Attempt.changeset(%{state: err})
        |> Repo.update!()
      _ ->
        commit = GitHub.copy_branch!(
          repo_conn,
          stmp,
          project.trying_branch)
        state = setup_statuses(repo_conn, attempt, project, patch)
        state = Attempt.numberize_state(state)
        now = DateTime.to_unix(DateTime.utc_now(), :seconds)
        attempt
        |> Attempt.changeset(%{state: state, commit: commit, last_polled: now})
        |> Repo.update!()
    end
  end

  defp setup_statuses(repo_conn, attempt, project, patch) do
    toml = GitHub.get_file!(
      repo_conn,
      project.trying_branch,
      "bors.toml")
    case toml do
      nil ->
        setup_statuses_error(
          repo_conn,
          attempt,
          patch,
          :fetch_failed)
        :error
      toml ->
        case Aelita2.Batcher.BorsToml.new(toml) do
          {:ok, toml} ->
            toml.status
            |> Enum.map(&%AttemptStatus{
                attempt_id: attempt.id,
                identifier: &1,
                url: nil,
                state: AttemptStatus.numberize_state(:running)})
            |> Enum.each(&Repo.insert!/1)
            now = DateTime.to_unix(DateTime.utc_now(), :seconds)
            attempt
            |> Attempt.changeset(%{timeout_at: now + toml.timeout_sec})
            |> Repo.update!()
            :running
          {:error, message} ->
            setup_statuses_error(repo_conn,
              attempt,
              patch,
              message)
            :error
        end
    end
  end

  defp setup_statuses_error(repo_conn, attempt, patch, message) do
    message = Aelita2.Batcher.Message.generate_bors_toml_error(message)
    err = Attempt.numberize_state(:error)
    attempt
    |> Attempt.changeset(%{state: err})
    |> Repo.update!()
    send_message(repo_conn, patch, {:config, message})
  end

  defp poll_attempt(attempt, project) do
    patch = Repo.get!(Patch, attempt.patch_id)
    now = DateTime.to_unix(DateTime.utc_now(), :seconds)
    if attempt.timeout_at < now do
      timeout_attempt(attempt, project, patch)
    else
      gh_statuses = project
      |> get_repo_conn()
      |> GitHub.get_commit_status!(attempt.commit)
      |> Enum.map(&{elem(&1, 0), AttemptStatus.numberize_state(elem(&1, 1))})
      |> Map.new()
      attempt.id
      |> AttemptStatus.all_for_attempt()
      |> Repo.all()
      |> Enum.filter(&Map.has_key?(gh_statuses, &1.identifier))
      |> Enum.map(&{&1, %{state: Map.fetch!(gh_statuses, &1.identifier)}})
      |> Enum.map(&AttemptStatus.changeset(elem(&1, 0), elem(&1, 1)))
      |> Enum.each(&Repo.update!/1)
      maybe_complete_attempt(attempt, project, patch)
    end
  end

  defp maybe_complete_attempt(attempt, project, patch) do
    statuses = Repo.all(AttemptStatus.all_for_attempt(attempt.id))
    state = Aelita2.Batcher.State.summary_statuses(statuses)
    maybe_complete_attempt(state, project, patch, statuses)
    state = Attempt.numberize_state(state)
    now = DateTime.to_unix(DateTime.utc_now(), :seconds)
    attempt
    |> Attempt.changeset(%{state: state, last_polled: now})
    |> Repo.update!()
  end

  defp maybe_complete_attempt(:ok, project, patch, statuses) do
    repo_conn = get_repo_conn(project)
    send_message(repo_conn, patch, {:succeeded, statuses})
  end

  defp maybe_complete_attempt(:error, project, patch, statuses) do
    repo_conn = get_repo_conn(project)
    erred = Enum.filter(
      statuses,
      &(&1.state == AttemptStatus.numberize_state(:error)))
    send_message(repo_conn, patch, {:failed, erred})
  end

  defp maybe_complete_attempt(:running, _project, _patch, _statuses) do
    :ok
  end

  defp timeout_attempt(attempt, project, patch) do
    project
    |> get_repo_conn()
    |> send_message(patch, {:timeout, :failed})
    err = Attempt.numberize_state(:error)
    attempt
    |> Attempt.changeset(%{state: err})
    |> Repo.update!()
  end

  defp send_message(repo_conn, patch, message) do
    body = Aelita2.Batcher.Message.generate_message(message)
    GitHub.post_comment!(
      repo_conn,
      patch.pr_xref,
      body)
  end

  @spec get_repo_conn(%Project{}) :: {{:installation, number}, number}
  defp get_repo_conn(project) do
    Project.installation_connection(project.repo_xref, Repo)
  end
end