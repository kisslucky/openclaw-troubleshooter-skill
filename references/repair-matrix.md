# Repair Matrix

Use this file when the diagnosis emits a finding ID that needs a repair decision.

## Findings

### `gateway.listener.missing`

- Meaning: The configured gateway port is not listening.
- First repair: Restart the gateway with `openclaw-repair.ps1 -RepairAllSafe`.
- Escalate: If the port stays down and the scheduled task exists, inspect the task target and launcher path.

### `gateway.launcher.missing`

- Meaning: `%USERPROFILE%\.openclaw\gateway.cmd` does not exist.
- Repair: Stop. Report that the local OpenClaw installation is incomplete or moved.

### `provider.quota.exhausted`

- Meaning: Recent logs contain `429` or quota exhaustion messages.
- Repair: Do not keep restarting as the primary fix. Switch to another supported model or restore provider quota.

### `network.openai.proxy_required`

- Meaning: The OpenAI or Codex endpoint fails on direct egress while the local proxy endpoint is healthy.
- Repair: Ask once, then install or update the supervisor so the gateway inherits the Windows proxy route.

### `network.openai.unreachable`

- Meaning: The OpenAI or Codex endpoint is unreachable and no working local proxy route was detected.
- Repair: Report it as an upstream connectivity issue. Restarting the gateway alone is not sufficient.

### `gateway.supervisor.installed`

- Meaning: The scheduled task already points to a supervisor-managed launcher.
- Repair: Prefer testing or updating the existing supervisor instead of replacing it with a direct gateway launch.

## Safe Repair Order

1. Restart the gateway.
2. Re-run diagnosis.
3. Restart the scheduled task if the listener is still absent.
4. Only after confirming a route problem, install or update the supervisor.
