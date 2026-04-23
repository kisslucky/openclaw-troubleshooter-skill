# OpenClaw Troubleshooter

Diagnose and repair OpenClaw on Windows when the gateway hangs, the desktop client stops responding, model requests time out, fallbacks loop, ports stop listening, proxies changed, or provider quota and connectivity errors need to be separated and fixed.

## What It Does

- collects a machine snapshot with gateway state, scheduled task state, listener state, proxy settings, routing, and recent log findings
- distinguishes quota failures from network failures
- applies safe repairs such as gateway restarts and task restarts
- escalates cleanly into the companion supervisor installer when the durable fix is route continuity across proxy changes

## Runtime Support

- Host runtimes: OpenClaw, Hermes, or any `SKILL.md`-compatible runtime with terminal access
- Managed target: OpenClaw on Windows
- Shell: PowerShell 5+
- Primary use: local repair on the machine that runs OpenClaw

## Hermes Compatibility

No special Hermes fork is required. The same skill folder works in Hermes because it follows the `SKILL.md` convention and relies on bundled terminal scripts.

The key boundary is not "OpenClaw runtime vs Hermes runtime". The key boundary is "host runtime" vs "managed system". This skill manages an OpenClaw installation from whichever compatible host runtime invokes it.

## Contents

- `SKILL.md`
- `agents/openai.yaml`
- `scripts/openclaw-diagnose.ps1`
- `scripts/openclaw-repair.ps1`
- `references/repair-matrix.md`
- `references/output-fields.md`

## Validation

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\openclaw-diagnose.ps1 -AsJson
powershell -ExecutionPolicy Bypass -File .\scripts\openclaw-repair.ps1 -RepairAllSafe -AsJson
```

Successful validation produces JSON output and leaves the gateway listening again after any restart-based repair.

## License

MIT
