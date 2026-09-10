# Agent Guidelines — Omarchy Omar

## Overview
Omarchy customization repository — Hyprland dotfiles, monitor layout, power management.

## Core Rules
1. **Fix root causes, not symptoms** — trace down to the config or system unit.
2. **Verify with real tool output** — every claim backed by a command.
3. **Backup before destructive edits** — never rm a config without a copy.
4. **Score every change** — begin_change → work → feedback → end_change.
5. **Test the deployed path** — editing the source file is not the same as testing what runs.

## Known Domains (docs-first — read before touching)
- **Headless boot / LUKS** — `docs/06-headless-boot.md` (`scripts/fix-headless-luks.sh`).
  Boot-gate fixes must survive initramfs regeneration; verify with `lsinitcpio`,
  never `bsdtar`. A LUKS keyfile is not a fix unless it survives a real reboot.
- **SDDM greeter idle / blank-screen** — `docs/07-sddm-greeter-idle.md`
  (`scripts/fix-greeter-idle.sh`). SDDM reads EVERY file in `/etc/sddm.conf.d/` —
  never leave backup/disabled files inside that dir (a `.bak` overrides the live
  config, same class as the autologin bug). Greeter idle needs `ignore_inhibit`,
  and legacy `hyprctl dispatch dpms off` fails on Lua-dispatcher Hyprland 0.55+.
- **Power / suspend** — `docs/02-power-fixes.md`.
- **Doc index** — `docs/DOCS-INDEX.md` is the navigation index; add new docs there.

## Change Discipline for This Repo
- Edits here touch a live desktop — test on the actual host, not in a throwaway.
- Doc changes are first-class: every fix lands as a doc + script pair.
- Greeter/display changes need the reboot test confirmed by the user before closing.

<!-- Hermes fleet efficiency block (additive — safe to ignore, safe to remove) -->
<!-- Managed by apply-repo-efficiency.sh; re-running never duplicates. -->

## Session Efficiency (Hermes fleet — additive guidance)

These are cost/throughput principles for AI coding agents working in this
repo. They change nothing about the repo's own rules; they only tell the
agent how to spend its own tokens efficiently.

- **Batch independent tool calls** in one turn; prefer fewer, larger
  operations over many tiny round-trips. Each call re-sends context —
  cache-hit, but still billed; output tokens are the real cost.
- **Don't re-derive established facts** — reference prior conclusions in one
  clause and advance. Re-reading files to re-learn what a prior turn already
  established burns tokens.
- **Keep the session alive for related work** — continuing one session beats
  starting fresh (history re-sends are cache hits; a new session pays a cold
  system-prompt start and re-explains context).
- **Compact responses** — deliver the answer, not the process. No status
  narration, no "let me" preambles.
- **Thinking economy** — match reasoning depth to task difficulty; don't
  over-deliberate simple lookups or mechanical edits.
- **Ask once, act twice** — prefer acting on an obvious default over
  clarifying questions that only burn a round-trip.
