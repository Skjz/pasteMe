# AGENTS.md

## Architecture

Before changing code under `Sources/` or `Tests/`, read `docs/architecture.md`: which target owns what, the seams and their test fakes, which planned modules still live in older code, and how to run the app against a throwaway history to verify a change.

## UI performance

Before calling a change to the panel, cards or cursor smooth, or when the user reports stutter, measure it with `scripts/bench-panel.sh` following `docs/agents/ui-performance.md`.

## Agent skills

### Issue tracker

Issues are tracked in this repo's GitHub Issues via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `GLOSSARY.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
