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

  @runtime_pubsub Symphony.Runtime.PubSub
  @stream_cap 100

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
      |> assign(:streams, %{})
      |> assign(:nudge_drafts, %{})
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

  def handle_info({:agent_event, identifier, payload}, socket) do
    if MapSet.member?(socket.assigns.expanded, identifier) do
      entry = %{
        at: System.system_time(:millisecond),
        method: Map.get(payload, "method"),
        params: Map.get(payload, "params")
      }

      streams =
        Map.update(socket.assigns.streams, identifier, [entry], fn buf ->
          [entry | buf] |> Enum.take(@stream_cap)
        end)

      {:noreply, assign(socket, :streams, streams)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel", %{"identifier" => identifier}, socket) do
    case RestateClient.issue_cancel(identifier) do
      {:ok, %{"ok" => true}} ->
        {:noreply, socket |> refresh_reconcile() |> refresh_one_attempt(identifier)}

      {:ok, %{"ok" => false} = resp} ->
        {:noreply, assign(socket, :last_error, "cancel rejected: " <> inspect(resp))}

      {:error, reason} ->
        {:noreply, assign(socket, :last_error, "cancel failed: " <> format_error(reason))}
    end
  end

  def handle_event("nudge_change", %{"identifier" => identifier, "text" => text}, socket) do
    drafts = Map.put(socket.assigns.nudge_drafts, identifier, text)
    {:noreply, assign(socket, :nudge_drafts, drafts)}
  end

  def handle_event(
        "nudge_submit",
        %{"identifier" => identifier, "text" => text, "action" => "now"},
        socket
      ) do
    submit_nudge(socket, identifier, text, &RestateClient.issue_nudge_now/2, "nudge_now")
  end

  def handle_event("nudge_submit", %{"identifier" => identifier, "text" => text}, socket) do
    submit_nudge(socket, identifier, text, &RestateClient.issue_nudge/2, "nudge")
  end

  def handle_event("expand", %{"identifier" => identifier}, socket) do
    was_expanded = MapSet.member?(socket.assigns.expanded, identifier)

    expanded =
      if was_expanded do
        unsubscribe_stream(identifier)
        MapSet.delete(socket.assigns.expanded, identifier)
      else
        subscribe_stream(identifier)
        MapSet.put(socket.assigns.expanded, identifier)
      end

    streams =
      if was_expanded do
        Map.delete(socket.assigns.streams, identifier)
      else
        Map.put_new(socket.assigns.streams, identifier, [])
      end

    socket =
      socket
      |> assign(:expanded, expanded)
      |> assign(:streams, streams)
      |> refresh_one_attempt(identifier)

    {:noreply, socket}
  end

  defp submit_nudge(socket, identifier, text, client_fun, label) do
    text = String.trim(text)

    cond do
      text == "" ->
        {:noreply, assign(socket, :last_error, "#{label} rejected: empty message")}

      true ->
        case client_fun.(identifier, text) do
          {:ok, %{"ok" => true}} ->
            drafts = Map.put(socket.assigns.nudge_drafts, identifier, "")
            {:noreply, socket |> assign(:nudge_drafts, drafts) |> assign(:last_error, nil)}

          {:ok, %{"ok" => false} = resp} ->
            {:noreply, assign(socket, :last_error, "#{label} rejected: " <> inspect(resp))}

          {:error, reason} ->
            {:noreply,
             assign(socket, :last_error, "#{label} failed: " <> format_error(reason))}
        end
    end
  end

  defp subscribe_stream(identifier) do
    Phoenix.PubSub.subscribe(@runtime_pubsub, "agent:" <> identifier)
  rescue
    _ -> :ok
  end

  defp unsubscribe_stream(identifier) do
    Phoenix.PubSub.unsubscribe(@runtime_pubsub, "agent:" <> identifier)
  rescue
    _ -> :ok
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
                <th>actions</th>
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
                  <td>
                    <.row_actions
                      identifier={issue["identifier"]}
                      claim_status={issue["vo_state"]["claim_status"]}
                    />
                  </td>
                </tr>
                <%= if MapSet.member?(@expanded, issue["identifier"]) do %>
                  <tr>
                    <td colspan="7">
                      <.attempt_panel
                        issue={issue}
                        cached={Map.get(@attempts, issue["identifier"])}
                        stream={Map.get(@streams, issue["identifier"], [])}
                        nudge_draft={Map.get(@nudge_drafts, issue["identifier"], "")}
                      />
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

  defp claim_badge(%{status: "cancelled"} = assigns) do
    ~H"""
    <span class="badge cancelled">cancelled</span>
    """
  end

  defp claim_badge(assigns) do
    ~H"""
    <span class="badge">{@status}</span>
    """
  end

  attr :identifier, :string, required: true
  attr :claim_status, :any, required: true

  defp row_actions(%{claim_status: "running"} = assigns) do
    ~H"""
    <button
      type="button"
      class="btn btn-cancel"
      phx-click="cancel"
      phx-value-identifier={@identifier}
      onclick="event.stopPropagation()"
    >cancel</button>
    """
  end

  defp row_actions(assigns) do
    ~H"""
    <span class="muted">—</span>
    """
  end

  attr :issue, :map, required: true
  attr :cached, :any, required: true
  attr :stream, :list, required: true
  attr :nudge_draft, :string, required: true

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

      <.live_stream stream={@stream} />
      <.nudge_form identifier={@issue["identifier"]} draft={@nudge_draft} />
    </details>
    """
  end

  defp attempt_panel(assigns) do
    ~H"""
    <details class="attempt" open>
      <summary class="muted">loading attempt state for {@issue["identifier"]}…</summary>
      <.live_stream stream={@stream} />
      <.nudge_form identifier={@issue["identifier"]} draft={@nudge_draft} />
    </details>
    """
  end

  attr :identifier, :string, required: true
  attr :draft, :string, required: true

  defp nudge_form(assigns) do
    ~H"""
    <form
      phx-submit="nudge_submit"
      phx-change="nudge_change"
      class="nudge-form"
      onclick="event.stopPropagation()"
    >
      <input type="hidden" name="identifier" value={@identifier} />
      <textarea
        name="text"
        rows="2"
        placeholder="Send a note to the agent. Next-turn nudge waits for the current turn to finish; interrupt-now aborts the in-flight turn (costs its tokens)."
      ><%= @draft %></textarea>
      <div class="nudge-buttons">
        <button type="submit" name="action" value="next" class="btn btn-nudge">
          send to agent (next turn)
        </button>
        <button type="submit" name="action" value="now" class="btn btn-nudge-now">
          send + interrupt now
        </button>
      </div>
    </form>
    """
  end

  attr :stream, :list, required: true

  defp live_stream(assigns) do
    ~H"""
    <div class="live-stream">
      <div class="role">live agent stream <span class="muted">· newest first · capped at 100</span></div>
      <%= if @stream == [] do %>
        <p class="muted">No events yet — events will appear here as the agent runs.</p>
      <% else %>
        <ul class="stream-events">
          <%= for event <- @stream do %>
            <li>
              <span class="muted">{format_at_ms(event.at)}</span>
              <code>{event.method || "(no method)"}</code>
              <%= if snippet = format_event_snippet(event.params) do %>
                <span class="muted">— {snippet}</span>
              <% end %>
            </li>
          <% end %>
        </ul>
      <% end %>
    </div>
    """
  end

  defp format_at_ms(ms) when is_integer(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.truncate(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp format_at_ms(_), do: "?"

  defp format_event_snippet(%{"text" => t}) when is_binary(t) and t != "",
    do: t |> String.slice(0, 120) |> String.replace(~r/\s+/, " ")

  defp format_event_snippet(%{"delta" => %{"text" => t}}) when is_binary(t) and t != "",
    do: t |> String.slice(0, 120) |> String.replace(~r/\s+/, " ")

  defp format_event_snippet(%{"name" => name}) when is_binary(name), do: "tool: " <> name
  defp format_event_snippet(_), do: nil

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
