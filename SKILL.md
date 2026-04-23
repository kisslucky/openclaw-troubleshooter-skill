---
name: openclaw-troubleshooter
description: Diagnose and repair OpenClaw on Windows when the gateway hangs, the desktop client stops responding, models time out, fallbacks loop, ports stop listening, proxies or network routes changed, provider quota or connectivity errors appear, or local OpenClaw logs and model routing need to be inspected. Use when Codex should actively fix safe issues instead of only giving advice.
---

# OpenClaw Troubleshooter

Use this skill from any `SKILL.md`-compatible agent runtime that can execute local terminal commands on Windows, including OpenClaw and Hermes.

- The managed system is a local OpenClaw installation on Windows.
- The invoking runtime is intentionally decoupled from the managed system.
- Do not treat it as a generic chat or model troubleshooting skill. It is specifically for local OpenClaw gateway, model routing, proxy, and scheduled-task issues.

## Quick Start

Run `scripts/openclaw-diagnose.ps1 -AsJson` first.

Use the diagnosis output as the source of truth for the current machine state before proposing or applying repairs.

## Workflow

1. Run `scripts/openclaw-diagnose.ps1 -AsJson`.
2. Read `references/repair-matrix.md` only when the diagnosis contains unfamiliar finding IDs or ambiguous repair choices.
3. Apply safe repairs with `scripts/openclaw-repair.ps1 -RepairAllSafe -AsJson`.
4. Re-run diagnosis after every repair wave.
5. If the diagnosis shows proxy-dependent model failures or route drift, ask once, then install or update the supervisor by using the sibling `openclaw-supervisor-installer` skill when it is available.

## Repair Policy

Apply these repairs without stopping for confirmation when the user asked to fix the system:

- Restart the gateway.
- Restart or run the `OpenClaw Gateway` scheduled task.
- Start the gateway launcher directly when the task is missing but the local launcher exists.
- Re-run diagnosis and summarize what changed.

Ask before these durable changes:

- Installing or updating the supervisor.
- Changing persistent model routing.
- Replacing the scheduled task target when the user did not explicitly ask for continuity automation.
- Editing global Windows proxy settings.

## Practical Rules

- Prefer the bundled scripts over ad hoc shell snippets.
- Treat the diagnosis JSON as the canonical machine snapshot.
- Call out quota failures separately from network failures. They are different repairs.
- When OpenAI or Codex models fail only on direct egress but the local proxy is healthy, treat that as a routing problem, not a model outage.
- If the bundled repair script cannot perform a durable fix alone, escalate into the sibling `openclaw-supervisor-installer` skill instead of leaving the user with manual steps.
- If the user is actively using the desktop client, avoid durable route rewrites unless they explicitly asked for continuity automation.

## Resources

- `scripts/openclaw-diagnose.ps1`
  Collect gateway status, scheduled task state, listener state, proxy settings, provider reachability, model routing, and recent log findings.
- `scripts/openclaw-repair.ps1`
  Apply safe repairs and optionally chain into the supervisor installer.
- `references/repair-matrix.md`
  Map diagnosis findings to the correct repair strategy.
- `references/output-fields.md`
  Explain the structure of the diagnosis JSON.

## Typical Requests

- "OpenClaw has no response. Diagnose it and repair what you can."
- "The gateway is alive but GPT-5.4 times out. Fix the routing."
- "Check whether this is quota, proxy, or a dead port."
- "Repair the machine, not just the app config."
