# Sim Lab — R770 Build Repo (Claude Code)

Everything needed to design, build, validate, and supply the air-gapped Dell PowerEdge R770 network simulation / packet-capture server, packaged as a Claude Code working directory.

## How to use

1. Put this directory on the **internet-connected staging host** (current host spec: `docs/plans/r770-dependency-manifest.md` §0) and `git init` it if it isn't already a repo.
2. Record the R770's SSH target and iDRAC address in `state/BUILD-STATE.md`.
3. Open Claude Code here. `CLAUDE.md` loads automatically and carries the operating rules and safety gates.
4. Start with `/discover` (read-only hardware discovery), then work phases in order with `/phase <n>`. Cut supply bundles with `/bundle`, import them with `/import-bundle`, prove things with `/validate`.

## What's here

| Path | What |
|---|---|
| `PRD.md` | The distilled product requirements — goals, non-goals, architecture, success criteria, risks |
| `CLAUDE.md` | Claude Code operating rules: run context (staging + SSH), safety gates, phase protocol |
| `.claude/commands/` | `/discover` `/phase` `/bundle` `/import-bundle` `/validate` `/wan` `/capture-check` `/status` |
| `.claude/agents/` | discovery-analyst · safety-reviewer · bundle-builder · validation-runner · capture-engineer |
| `.claude/settings.json` | Permission guardrails (destructive disk commands denied; ssh/sudo/docker always prompt) |
| `docs/plans/` | The four source plans: buildout, offline supply, dependency manifest, staging runbook |
| `docs/analyst-wiki/` | Analyst-facing wiki (becomes the portal's MkDocs site at build Phase 13) |
| `docs/superpowers/specs/` | Durable design specs (not one-shot work orders — those live in `work/plans/`) |
| `scripts/r770-offline-fetch.sh` | Bundle builder — run on staging, never on the R770 |
| `scripts/r770-bundle.sh` | Bundle manifest generation and integrity verification; ships inside the bundle itself |
| `scripts/r770-precheck.sh` | Read-only Phase 1 discovery — run on the R770 |
| `tests/` | `./tests/run.sh` — the repo's one check: shellcheck, lint, and bats suites, offline and read-only |
| `work/plans/active/` | In-progress one-shot plans |
| `work/plans/archive/` | Executed plans, kept as outcome records |
| `state/BUILD-STATE.md` | Phase tracker — the single source of build truth |
| `state/inventory/` | Discovery output, phase evidence, validation reports, bundle logs |

## The three machines

```
Staging host (internet)              ← Claude Code runs here; bundles built here
        │ SSH (gated commands)              │ checksummed ext4 media
        ▼                                   ▼
R770 (air-gapped, Ubuntu 24.04)      ← build target; no internet, ever
        ▲
iDRAC (out-of-band)                  ← recovery path; verify before touching networking
```

Never commit secrets, keys, or sensitive PCAP data to this repo.
