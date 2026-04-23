# Diagnosis Output Fields

`openclaw-diagnose.ps1 -AsJson` returns a machine-readable snapshot with these top-level fields:

- `timestamp`
- `computer_name`
- `openclaw_home`
- `paths`
- `cli`
- `gateway`
- `proxy`
- `models`
- `providers`
- `logs`
- `findings`
- `recommended_repairs`

## Key Paths

- `paths.gateway_launcher.path`
- `paths.openclaw_config.path`
- `paths.agent_models.path`
- `paths.log_dir.path`

## Key Gateway Fields

- `gateway.listener.listening`
- `gateway.listener.process_id`
- `gateway.task.exists`
- `gateway.task.action`
- `gateway.supervisor.installed`

## Key Proxy Fields

- `proxy.internet_settings.summary`
- `proxy.internet_settings.environment.HTTP_PROXY`
- `proxy.internet_settings.environment.HTTPS_PROXY`
- `proxy.local_proxy_processes`

## Key Model Fields

- `models.primary`
- `models.fallbacks`
- `models.route_checks`

## Findings

Each entry in `findings` includes:

- `id`
- `severity`
- `message`
- `suggested_actions`

Use `id` for repair branching. Do not pattern-match on the human-readable message when a finding ID is present.
