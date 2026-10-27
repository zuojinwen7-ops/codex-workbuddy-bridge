# Codex WorkBuddy Bridge

[中文文档](README.md)

A Windows filesystem workflow for **Codex to assign and review work, while desktop WorkBuddy executes it**.

Tasks enter `inbox`, WorkBuddy claims them with an atomic move, writes real artifacts, and reports to `results`. A filesystem watcher then uses `codex queue` to ask the original Codex chat to review the output. Reviews include concrete evidence and SHA-256 hashes.

Author: [zuojinwen7-ops](https://github.com/zuojinwen7-ops). MIT license. Experimental v0.1.0.

## Requirements

- Windows, PowerShell 5.1 or 7, and a project on a local filesystem.
- Signed-in desktop WorkBuddy with working tools and permissions.
- Signed-in Codex and a native `codex.exe` supporting `queue --thread --message`.
- An existing Codex chat UUID, with access to the authorized project directory.

## Setup

```powershell
git clone https://github.com/zuojinwen7-ops/codex-workbuddy-bridge.git
cd codex-workbuddy-bridge
.\scripts\initialize.ps1 -WorkspaceRoot 'C:\Projects\demo' -ThreadId 'YOUR-CODEX-CHAT-UUID'
```

Initialization checks CLI help without sending messages. It refuses to overwrite existing configuration or a runtime directory. Give the generated `WORKBUDDY-PROMPT.md` to WorkBuddy and `CODEX-PROMPT.md` to the chosen Codex chat. Start the results watcher explicitly:

```powershell
.\scripts\manage-results-watch.ps1 -Action Start
.\scripts\doctor.ps1
.\scripts\submit-task.ps1 -Instruction 'Create hello.txt containing Hello.' -WorkDir 'C:\Projects\demo' -AllowedScope write_file -Checks 'hello.txt contains exactly Hello.'
```

See [WORKFLOW.md](docs/WORKFLOW.md) for claim, report, and review commands. Optional Codex skill: `skills/codex-workbuddy-bridge`.

Choose the WorkBuddy project/session before starting its listener. A task's work directory does not switch the native session. Each runtime routes review events to one configured Codex chat, regardless of which chat submitted a task. Other active monitors or follow-ups can produce replies in a second chat. Use a separate queue and review chat for each project. This release is a separate copy; changes to a local prototype do not sync automatically.

```powershell
.\tests\run-tests.ps1
.\scripts\manage-results-watch.ps1 -Action Stop
```

## Boundaries

This is a local transport, not a model, free quota provider, execution sandbox, or authenticated proof of model provenance. Both apps can still use their own cloud services. Scope fields are instructions, not OS enforcement. Atomic moves do not guarantee exactly-once external effects. Keep the applications available and verify a real task on each new setup. Background command completion must actually wake the WorkBuddy session; the bridge cannot create that native capability.

Dry-run tests use synthetic fixtures and never call a model. See [validation](docs/VALIDATION.md), [recovery](docs/TROUBLESHOOTING.md), and [security](SECURITY.md).
