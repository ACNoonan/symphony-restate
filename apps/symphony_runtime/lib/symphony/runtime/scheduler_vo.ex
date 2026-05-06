defmodule Symphony.Runtime.SchedulerVO do
  @moduledoc """
  Per-project poll-loop scheduler. One Virtual Object per Linear
  project slug — single-writer guarantees that only one tick is
  in-flight per project at a time.

  ## SPEC mapping

  This is the `SPEC.md` §8.1 poll loop. The reference Symphony
  impl runs it as an in-memory `GenServer.send_after` timer; we
  run it as a Restate VO that self-schedules its next tick via
  `ctx.send(invoke_at_ms:)`. Suspends to ~$0 between ticks (no
  process holds memory while waiting), survives node death, and
  resumes after a cluster restart with no scheduling state lost.

  ## Handlers

    * `start(%{interval_ms, project_slug?})` — boot the loop. Sets
      `running=true`, `interval_ms`, and dispatches the first
      `tick`. Idempotent: a second `start` while `running=true`
      is a no-op (the existing tick chain stays in flight).

    * `tick(_)` — one poll cycle. If `running=false`, exits without
      rescheduling (the chain dies). Otherwise:

        1. Fetch the project's issues (filtered by `active_states`
           from WORKFLOW.md) inside `ctx.run`.
        2. For each issue not currently `running`/`done`, fire a
           `send_async` to `IssueVO.dispatch` — fire-and-forget,
           because per-issue lifecycle is the issue's problem,
           not the scheduler's.
        3. Schedule the next tick via
           `ctx.send(self, "tick", nil, invoke_at_ms: now + interval_ms)`.

    * `stop(_)` — set `running=false`. The current in-flight tick
      (if any) will not reschedule the next one; the loop dies
      gracefully on the next tick boundary.

    * `reconcile(_)` — fan-out read of every issue's VO state via
      `call_async` + `Awaitable.all/2`. Returns a snapshot for the
      operator / dashboard. Does not dispatch anything.

  ## State

    * `running` — boolean
    * `interval_ms` — pos_integer
    * `last_tick_at_ms` — system time of last tick start, ms
    * `dispatched_total` — running counter of issues we've fanned
      out to (across all ticks)
    * `last_tick_dispatched` — list of identifiers dispatched on
      the last tick (for the demo UI)
    * `last_error` — last terminal error string, if any tick failed

  ## Why VO and not Workflow

  The poll loop is intentionally not a one-shot — it runs forever
  until `stop` is called. A Workflow is one-shot per key. A VO with
  `tick` self-rescheduling matches the lifecycle exactly and gets
  us the single-writer guard on `running` for free.
  """

  require Logger

  alias Restate.{Awaitable, Context}
  alias Symphony.Core.Workflow
  alias Symphony.Runtime.Linear

  @default_interval_ms :timer.seconds(30)
  @default_first 100
  @issue_vo_service "IssueVO"
  @issue_vo_dispatch "dispatch"
  @issue_vo_read_state "readState"
  @self_service "SchedulerVO"
  @self_tick_handler "tick"

  # ---------------------- Handlers ----------------------

  @doc "Start the poll loop. Idempotent."
  def start(%Context{} = ctx, input) when is_map(input) or is_nil(input) do
    project_slug = Context.key(ctx)
    interval_ms = positive_int(input["interval_ms"], @default_interval_ms)

    Logger.metadata(scheduler_project: project_slug)

    case Context.get_state(ctx, "running") do
      true ->
        %{
          "ok" => true,
          "already_running" => true,
          "project_slug" => project_slug,
          "interval_ms" => current_interval_ms(ctx, interval_ms)
        }

      _ ->
        Context.set_state(ctx, "running", true)
        Context.set_state(ctx, "interval_ms", interval_ms)
        Context.set_state(ctx, "dispatched_total", Context.get_state(ctx, "dispatched_total") || 0)
        Context.clear_state(ctx, "last_error")

        schedule_next_tick(ctx, project_slug, 0)

        %{
          "ok" => true,
          "already_running" => false,
          "project_slug" => project_slug,
          "interval_ms" => interval_ms
        }
    end
  end

  @doc "Stop the poll loop. The next tick exits without rescheduling."
  def stop(%Context{} = ctx, _input) do
    project_slug = Context.key(ctx)
    Context.set_state(ctx, "running", false)
    %{"ok" => true, "project_slug" => project_slug}
  end

  @doc "One poll cycle. Self-reschedules unless `running=false`."
  def tick(%Context{} = ctx, _input) do
    project_slug = Context.key(ctx)
    Logger.metadata(scheduler_project: project_slug)

    case Context.get_state(ctx, "running") do
      true ->
        interval_ms = Context.get_state(ctx, "interval_ms") || @default_interval_ms
        run_one_tick(ctx, project_slug, interval_ms)

      _ ->
        Logger.info(fn -> "scheduler tick: running=false; chain ends" end)
        %{"ok" => true, "halted" => true, "project_slug" => project_slug}
    end
  end

  @doc """
  Snapshot the VO state of every issue currently visible to this
  project. Reads via `call_async` + `Awaitable.all` so all N reads
  happen in parallel; total wall time is one Restate round-trip
  rather than N.
  """
  def reconcile(%Context{} = ctx, _input) do
    project_slug = Context.key(ctx)
    Logger.metadata(scheduler_project: project_slug)

    workflow = load_workflow(ctx)
    active_states = active_states_from_config(workflow["config"])

    issues =
      Context.run(ctx, fn ->
        Linear.list_issues_in_project!(project_slug, active_states, @default_first)
      end)

    if issues == [] do
      %{"ok" => true, "project_slug" => project_slug, "issues" => []}
    else
      handles =
        Enum.map(issues, fn %{"identifier" => identifier} ->
          Context.call_async(ctx, @issue_vo_service, @issue_vo_read_state, nil,
            key: identifier
          )
        end)

      states = Awaitable.all(ctx, handles)

      %{
        "ok" => true,
        "project_slug" => project_slug,
        "issues" =>
          Enum.zip_with(issues, states, fn issue, state ->
            Map.merge(issue, %{"vo_state" => state})
          end)
      }
    end
  end

  # ---------------------- Tick body ----------------------

  defp run_one_tick(ctx, project_slug, interval_ms) do
    started_at = system_time_ms_journaled(ctx)
    Context.set_state(ctx, "last_tick_at_ms", started_at)

    workflow = load_workflow(ctx)
    active_states = active_states_from_config(workflow["config"])

    {issues, dispatched, error} =
      try do
        issues =
          Context.run(ctx, fn ->
            Linear.list_issues_in_project!(project_slug, active_states, @default_first)
          end)

        dispatched =
          Enum.flat_map(issues, fn %{"identifier" => identifier} ->
            # Fire-and-forget. Per-issue lifecycle (claim, attempt
            # numbering, terminal-state break) is IssueVO's problem.
            # `send_async` skips the round-trip that returns the new
            # invocation id — we don't need it here.
            Context.send_async(ctx, @issue_vo_service, @issue_vo_dispatch, nil, key: identifier)
            [identifier]
          end)

        {issues, dispatched, nil}
      rescue
        e in Restate.TerminalError ->
          Logger.warning(fn -> "scheduler tick failed: #{Exception.message(e)}" end)
          {[], [], Exception.message(e)}
      end

    Context.set_state(ctx, "last_tick_dispatched", dispatched)

    Context.set_state(
      ctx,
      "dispatched_total",
      (Context.get_state(ctx, "dispatched_total") || 0) + length(dispatched)
    )

    if error do
      Context.set_state(ctx, "last_error", error)
    else
      Context.clear_state(ctx, "last_error")
    end

    schedule_next_tick(ctx, project_slug, interval_ms)

    %{
      "ok" => is_nil(error),
      "project_slug" => project_slug,
      "issues_seen" => length(issues),
      "issues_dispatched" => length(dispatched),
      "next_tick_in_ms" => interval_ms,
      "error" => error
    }
  end

  defp schedule_next_tick(ctx, project_slug, delay_ms) do
    invoke_at_ms = system_time_ms_journaled(ctx) + delay_ms

    Context.send_async(ctx, @self_service, @self_tick_handler, nil,
      key: project_slug,
      invoke_at_ms: invoke_at_ms
    )
  end

  # ---------------------- Helpers ----------------------

  # System time has to be journaled — naked `System.system_time/1`
  # would diverge across replays. Wrap in `ctx.run` so the value
  # is recorded.
  defp system_time_ms_journaled(ctx) do
    Context.run(ctx, fn -> System.system_time(:millisecond) end)
  end

  defp load_workflow(ctx) do
    workflow_path = Application.fetch_env!(:symphony_runtime, :workflow_path)

    Context.run(ctx, fn ->
      case Workflow.load(workflow_path) do
        {:ok, %{config: config, prompt_template: tmpl}} ->
          %{"config" => config, "prompt_template" => tmpl}

        {:error, reason} ->
          raise Restate.TerminalError,
            code: 500,
            message: "scheduler_workflow_load_failed: #{inspect(reason)}"
      end
    end)
  end

  defp active_states_from_config(config) when is_map(config) do
    case get_in(config, ["tracker", "active_states"]) do
      list when is_list(list) -> list
      _ -> nil
    end
  end

  defp active_states_from_config(_), do: nil

  defp positive_int(v, _default) when is_integer(v) and v > 0, do: v
  defp positive_int(_, default), do: default

  # Used only for the `start` response when `already_running=true`.
  defp current_interval_ms(ctx, fallback) do
    Context.get_state(ctx, "interval_ms") || fallback
  end
end
