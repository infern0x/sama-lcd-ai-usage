# CLAUDE.md

Context for Claude when working on this repository.

## What this is
A Windows-only tool that draws Claude Code and OpenAI Codex usage (5-hour and weekly limits, reset countdowns, animated logos) on the 720×720 LCD of a SAMA AIO cooler, which is a Turing/TURZX-based USB serial screen.

## Layout
- `src/sama-lcd-ai-usage.ps1` handles usage fetching, rendering the static part once a minute, the serial protocol and the main loop.
- `src/CoolerLcd.cs` holds the delta encoder (`Codec.Delta`) and the per-frame animated logos (`Animator`). It is compiled at runtime with `Add-Type`.
- `install.ps1` / `uninstall.ps1` copy the app to `%LOCALAPPDATA%\Programs\sama-lcd-ai-usage` and manage a logon Scheduled Task.
- `PROTOCOL.md` documents the wire format. Keep it in sync with any protocol change.

## Constraints
- Target **Windows PowerShell 5.1** and .NET Framework (`System.Drawing`, `System.IO.Ports`). Do not use PowerShell 7-only syntax (`??`, `?.`, ternary, `&&`). Add no external dependencies.
- C# in `CoolerLcd.cs` must compile with the .NET Framework compiler used by `Add-Type` (C# 5-level features).
- Never commit tokens, logs, or anything from `~/.claude` or `~/.codex`.
- The real device cannot be reached from CI. Changes to the protocol or encoder need testing on hardware by the maintainer, so say so in the PR.
- `-Demo -SavePng file.png` renders a preview with sample data and needs no device or login. Use it to show layout changes.
- Keep README.md bilingual (Chinese section first, then English), and update both sections together.
