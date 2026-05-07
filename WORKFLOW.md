---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: "REPLACE-ME"
  active_states: ["Todo", "In Progress"]
  terminal_states: ["Done", "Closed", "Cancelled", "Duplicate"]

polling:
  interval_ms: 30000

workspace:
  root: ~/code/symphony_workspaces

hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .

agent:
  max_concurrent_agents: 4
  max_turns: 20

codex:
  command: codex app-server
  turn_timeout_ms: 3600000
  stall_timeout_ms: 300000
---

You are working on Linear issue {{ issue.identifier }}.

Title: {{ issue.title }}

{% if issue.description %}
Description:
{{ issue.description }}
{% endif %}

{% if attempt %}
This is retry/continuation attempt {{ attempt }}. Continue from prior turn state.
{% endif %}

Land a PR that closes this issue. Comment on the Linear ticket with the PR
link when ready, then mark the issue as `Human Review`.