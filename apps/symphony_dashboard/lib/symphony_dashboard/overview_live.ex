defmodule Symphony.Dashboard.OverviewLive do
  @moduledoc """
  Single-page LiveView for the slice-4 dashboard.

  Reads:

    * Project slug from `WORKFLOW.md` (`tracker.project_slug`).
      Loaded once at mount; user can override via `?project=<slug>`
      query param.
    * Current scheduler + per-issue state via
      `Symphony.Dashboard.RestateClient.scheduler_reconcile/1`. Lazily
      drills into per-attempt state via
      `RestateClient.attempt_read_state/2` when a row is expanded.

  ## Refresh

    * Auto-refreshes every `:refresh_interval_ms` (default 2s) via a
      `Process.send_after/3` self-message — only when the LiveView is
      `connected?`. The first render after `mount/3` is a static page;
      the refresh loop kicks in once the WebSocket upgrade completes.
    * On RestateClient error the dashboard shows the last good
      snapshot with a "stale" badge — failure to reach Restate is
      part of the demo (the chaos beats).

  ## Expand-on-click

  Clicking an issue row toggles its detail row. The first expand
  fires `phx-click="expand"` with the issue identifier; the LV
  fetches the most recent attempt's workflow state lazily and
  caches the result in `assigns.attempts`. Subsequent refreshes
  re-fetch the expanded attempts to keep the conversation live.
  """

  use Phoenix.LiveView, layout: {Symphony.Dashboard.Layouts, :root}

  alias Symphony.Core.Workflow
  alias Symphony.Dashboard.RestateClient

  @impl true
  def mount(params, _session, socket) do
    project_slug = params["project"] || project_slug_from_workflow()
    interval_ms = Application.get_env(:symphony_dashboard, :refresh_interval_ms, 2_000)

    if connected?(socket), do: schedule_refresh(interval_ms)

    socket =
      socket
      |> assign(:project_slug, project_slug)
      |> assign(:interval_ms, interval_ms)
      |> assign(:expanded, MapSet.new())
      |> assign(:attempts, %{})
      |> assign(:last_error, nil)
      |> assign(:last_refresh_at, nil)
      |> assign(:reconcile, %{"issues" => [], "ok" => false})
      |> refresh_reconcile()

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh(socket.assigns.interval_ms)

    socket =
      socket
      |> refresh_reconcile()
      |> refresh_expanded_attempts()

    {:noreply, socket}
  end

  @impl true
  def handle_event("expand", %{"identifier" => identifier}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded, identifier) do
        MapSet.delete(socket.assigns.expanded, identifier)
      else
        MapSet.put(socket.assigns.expanded, identifier)
      end

    socket =
      socket
      |> assign(:expanded, expanded)
      |> refresh_one_attempt(identifier)

    {:noreply, socket}
  end

  # ---------------------- Refresh helpers ----------------------

  defp schedule_refresh(interval_ms) do
    Process.send_after(self(), :refresh, interval_ms)
  end

  defp refresh_reconcile(socket) do
    case RestateClient.scheduler_reconcile(socket.assigns.project_slug) do
      {:ok, %{} = data} ->
        socket
        |> assign(:reconcile, data)
        |> assign(:last_error, nil)
        |> assign(:last_refresh_at, DateTime.utc_now())

      {:error, reason} ->
        # Keep the prior reconcile so the page doesn't blank out.
        assign(socket, :last_error, format_error(reason))
    end
  end

  # On each refresh, re-fetch attempt state for every expanded row.
  defp refresh_expanded_attempts(socket) do
    Enum.reduce(socket.assigns.expanded, socket, fn id, acc ->
      refresh_one_attempt(acc, id)
    end)
  end

  defp refresh_one_attempt(socket, identifier) do
    if MapSet.member?(socket.assigns.expanded, identifier) do
      case attempt_n_for(socket.assigns.reconcile, identifier) do
        nil ->
          socket

        n when is_integer(n) and n > 0 ->
          case RestateClient.attempt_read_state(identifier, n) do
            {:ok, attempt} ->
              update(socket, :attempts, fn cache ->
                Map.put(cache, identifier, %{"attempt_n" => n, "data" => attempt})
              end)

            {:error, _reason} ->
              socket
          end
      end
    else
      socket
    end
  end

  defp attempt_n_for(%{"issues" => issues}, identifier) when is_list(issues) do
    case Enum.find(issues, fn i -> i["identifier"] == identifier end) do
      %{"vo_state" => %{"last_attempt_n" => n}} when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  defp attempt_n_for(_, _), do: nil

  defp project_slug_from_workflow do
    workflow_path = Application.fetch_env!(:symphony_dashboard, :workflow_path)

    case Workflow.load(workflow_path) do
      {:ok, %{config: config}} ->
        get_in(config, ["tracker", "project_slug"]) || "REPLACE-ME"

      _ ->
        "REPLACE-ME"
    end
  end

  defp format_error({:restate_status, status, body}),
    do: "restate ingress HTTP #{status}: #{inspect(body)}"

  defp format_error({:restate_request, msg}), do: "restate ingress unreachable: #{msg}"

  defp format_error(other), do: inspect(other)

  # ---------------------- Render ----------------------

  @impl true
  def render(assigns) do
    ~H"""
    <header class="app">
      <h1>🎼 symphony-restate · dashboard</h1>
      <span class="muted">project: {@project_slug}</span>
      <span class="muted">·</span>
      <span class="muted">refresh: every {@interval_ms}ms</span>
      <span :if={@last_refresh_at} class="muted">·</span>
      <span :if={@last_refresh_at} class="muted">last: {format_at(@last_refresh_at)}</span>
      <span :if={@last_error} class="stale">· stale ({@last_error})</span>
    </header>

    <main class="app">
      <section class="panel">
        <h2>scheduler</h2>
        <div class="kv">
          <div class="k">project_slug</div>
          <div class="v code">{@project_slug}</div>
          <div class="k">issues seen</div>
          <div class="v">{Enum.count(@reconcile["issues"] || [])}</div>
          <div class="k">ok</div>
          <div class="v">{format_bool(@reconcile["ok"])}</div>
        </div>
      </section>

      <section class="panel">
        <h2>issues</h2>
        <%= if Enum.empty?(@reconcile["issues"] || []) do %>
          <p class="muted">No issues returned. Either the project is empty, or the SchedulerVO has not run a tick yet — try <code>mix symphony.scheduler tick {@project_slug} --exec</code>.</p>
        <% else %>
          <table class="issues">
            <thead>
              <tr>
                <th>identifier</th>
                <th>title</th>
                <th>tracker state</th>
                <th>claim</th>
                <th>attempt</th>
                <th>worker node</th>
              </tr>
            </thead>
            <tbody>
              <%= for issue <- @reconcile["issues"] || [] do %>
                <tr class="row" phx-click="expand" phx-value-identifier={issue["identifier"]}>
                  <td><strong>{issue["identifier"]}</strong></td>
                  <td>{issue["title"]}</td>
                  <td>{issue["state"]}</td>
                  <td><.claim_badge status={issue["vo_state"]["claim_status"]} /></td>
                  <td>{issue["vo_state"]["last_attempt_n"]}</td>
                  <td><code>{issue["vo_state"]["worker_node"]}</code></td>
                </tr>
                <%= if MapSet.member?(@expanded, issue["identifier"]) do %>
                  <tr>
                    <td colspan="6">
                      <.attempt_panel issue={issue} cached={Map.get(@attempts, issue["identifier"])} />
                    </td>
                  </tr>
                <% end %>
              <% end %>
            </tbody>
          </table>
        <% end %>
      </section>

      <div class="footer">
        Read via Restate ingress at <code>{Application.fetch_env!(:symphony_dashboard, :restate_ingress)}</code>.
        State surfaces from <code>SchedulerVO.reconcile</code>, <code>IssueVO.readState</code>, and
        <code>RunAttemptWorkflow.readState</code> — exactly what any other Restate client would see.
      </div>
    </main>
    """
  end

  # Function components — invoked via `<.component_name attr={...} />` from
  # the main render template. Each takes a single `assigns` map; HEEx fills in
  # the attrs at the call site.

  attr :status, :any, required: true

  defp claim_badge(%{status: nil} = assigns) do
    ~H"""
    <span class="badge unclaimed">unclaimed</span>
    """
  end

  defp claim_badge(%{status: "running"} = assigns) do
    ~H"""
    <span class="badge running">running</span>
    """
  end

  defp claim_badge(%{status: "done"} = assigns) do
    ~H"""
    <span class="badge done">done</span>
    """
  end

  defp claim_badge(%{status: "failed"} = assigns) do
    ~H"""
    <span class="badge failed">failed</span>
    """
  end

  defp claim_badge(assigns) do
    ~H"""
    <span class="badge">{@status}</span>
    """
  end

  attr :issue, :map, required: true
  attr :cached, :any, required: true

  defp attempt_panel(%{cached: %{"attempt_n" => _, "data" => %{}}} = assigns) do
    ~H"""
    <details class="attempt" open>
      <summary>
        attempt {@cached["attempt_n"]} · {Enum.count(@cached["data"]["conversation"] || [])} turns ·
        <span class="muted">workflow_content_hash: {short_hash(@cached["data"]["workflow_content_hash"])}</span>
      </summary>
      <div class="kv">
        <div class="k">workspace_path</div>
        <div class="v code">{@cached["data"]["workspace_path"]}</div>
        <div class="k">last_comment_id</div>
        <div class="v code">{@cached["data"]["last_comment_id"]}</div>
      </div>

      <%= for turn <- (@cached["data"]["conversation"] || []) do %>
        <div class="turn">
          <div class="role">turn {turn["turn"]} · prompt</div>
          <pre>{turn["prompt"]}</pre>
          <div class="role">turn {turn["turn"]} · response</div>
          <pre>{turn["response"]}</pre>
        </div>
      <% end %>
    </details>
    """
  end

  defp attempt_panel(assigns) do
    ~H"""
    <details class="attempt" open>
      <summary class="muted">loading attempt state for {@issue["identifier"]}…</summary>
    </details>
    """
  end

  defp short_hash(nil), do: "—"
  defp short_hash(hash) when is_binary(hash), do: String.slice(hash, 0, 12) <> "…"

  defp format_bool(true), do: "✓"
  defp format_bool(false), do: "✗"
  defp format_bool(_), do: "?"

  defp format_at(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
