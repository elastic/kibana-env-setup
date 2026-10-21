# Kibana Local Dev Environment — Setup Summary

## Overview

A tmux + git worktrees setup that eliminates context-switching overhead, runs multiple Kibana instances simultaneously, and automates the full bootstrap → ES → Kibana startup sequence.

**Key scripts:**
- `~/dev-start.sh` — master orchestrator
- `~/bin/kbn-start.sh` — ES + Kibana auto-launcher (called per session)

---

## Machine Setup

**Paths (specific to this machine):**
```
Kibana main repo:    ~/Documents/Development/kibana
Worktrees base:      ~/Documents/Development/worktrees/
Dev setup files:     ~/Documents/Dev_setup/
State file:          ~/.kibana-dev-state
```

**`~/.kibana-dev-state`** — tracks current kibana-feat branch:
```bash
FEAT_BRANCH=slo-embeddables-scout-tests
FEAT_DIR=/Users/pamitsop/Documents/Development/worktrees/slo-embeddables-scout-tests
```

**`/etc/hosts`** — required entries:
```
127.0.0.1 kibana-main.local
127.0.0.1 kibana-feat.local
```

---

## tmux Config (`~/.tmux.conf`)

```bash
unbind-key C-b
set -g prefix C-a          # PREFIX IS Ctrl-a
bind-key C-a send-prefix
set -g mouse on
set -g mode-keys vi
bind r source-file ~/.tmux.conf \; display-message "Reloaded!"
bind | split-window -h
bind - split-window -v
bind -T copy-mode-vi v send -X begin-selection
bind -T copy-mode-vi y send -X copy-pipe-and-cancel "pbcopy"
bind -T copy-mode-vi MouseDragEnd1Pane send -X copy-pipe-and-cancel "pbcopy"
```

**Key shortcuts:**
| Shortcut | Action |
|---|---|
| `Ctrl-a s` | Session switcher |
| `Ctrl-a w` | Window overview |
| `Ctrl-a d` | Detach (sessions keep running) |
| `Ctrl-a [` | Scroll / copy mode |
| `Ctrl-a 0-9` | Jump to window by number |
| `Ctrl-a \|` | Split pane vertical |
| `Ctrl-a -` | Split pane horizontal |

---

## Session Structure

### 2 Permanent Sessions

**`kibana-feat`** — your active feature branch, default ports:
| # | Window | Panes |
|---|---|---|
| 0 | servers | left: ES · right: Kibana (auto-started) |
| 1 | cursor | left: cursor-agent · right: shell |
| 2 | scripts | left: synthetics · right: inject |
| 3 | git | single pane |
| 4 | editor | single pane |
| 5 | tests | top: unit · bottom: scout |
| 6 | ftr | left: server · right: runner |

**`kibana-main`** — same window structure, kept clean for checking main branch status.

### Temporary Sessions (`kibana-<branch>`)

Created on demand with `~/dev-start.sh new <branch>` for PR reviews, hotfixes, testing:
| # | Window | Panes |
|---|---|---|
| 0 | servers | left: ES · right: Kibana |
| 1 | cursor | left: cursor-agent · right: shell |
| 2 | scripts | left: synthetics · right: inject |
| 3 | git | single pane |
| 4 | editor | single pane |

---

## Port Assignments

| Session | Kibana Port | ES Port | Host |
|---|---|---|---|
| kibana-feat | 5601 | 9200 | kibana-feat.local |
| kibana-main | 5602 | 9201 | kibana-main.local |
| kibana-\<branch\> | 5603+ (auto) | 9202+ (auto) | localhost |

**Design rationale:** `kibana-feat` always gets the default ports (5601/9200) because that's where active development happens. No port memorization needed. When you switch to a new feature branch via `switch`, the new branch inherits the default ports automatically.

---

## Generated Files Per Worktree

On session creation the script auto-generates:

**`config/kibana.dev.yml`** — copied from `~/Documents/Dev_setup/kibana.dev.yml` template with port substitution:
```yaml
server:
  port: __KIBANA_PORT__     ← replaced with actual port
elasticsearch.hosts:
  - http://localhost:__ES_PORT__   ← replaced with actual port
```
> Only generated if the file doesn't already exist. If ports are wrong, run `~/dev-start.sh switch <branch>` to regenerate.

**`.cursor/mcp.json`** — sets `KIBANA_URL` for playwright-mcp scoped to the correct host:port for this worktree.

---

## `dev-start.sh` Command Reference

```bash
~/dev-start.sh                          # start/attach all sessions + recover orphaned worktrees
~/dev-start.sh switch <branch>          # replace kibana-feat with a new branch
~/dev-start.sh new <branch>             # spin up temporary session (PR review, hotfix, etc.)
~/dev-start.sh new <branch> --full      # temporary session with full 7-window layout
~/dev-start.sh kill <branch>            # kill session + remove worktree
~/dev-start.sh kill-all                 # kill all kibana-* sessions
~/dev-start.sh recover                  # recreate sessions for orphaned worktrees
~/dev-start.sh list                     # show sessions, worktrees, port assignments + mismatch warnings
~/dev-start.sh attach <branch>          # attach to existing temporary session
~/dev-start.sh help                     # usage
```

### `switch` vs `new`

| Command | Use when |
|---|---|
| `switch <branch>` | Starting a new feature (every few days/weeks). Replaces kibana-feat. New branch runs on default ports automatically. |
| `new <branch>` | Need to run another branch alongside your current work — PR review, hotfix, testing a colleague's branch. Reuses existing worktree if already checked out. |

---

## `kbn-start.sh` — What It Does

Called automatically in the left pane of every servers window:

1. Loads `nvm` and switches to the correct Node version (reads `.nvmrc`)
2. Runs `yarn kbn bootstrap` — or `pnpm kbn bootstrap` on pnpm branches (auto-detected from `package.json` / `pnpm-lock.yaml`; runs `corepack enable` if pnpm is missing)
3. Starts `yarn es snapshot --license trial` (`pnpm es snapshot` on pnpm branches) with correct ports and data path
4. Watches `/tmp/es-<name>.log` for ES ready signal
5. When ES is ready → sends `nvm use` + `yarn start` (or `pnpm start`) to the right pane automatically, including `--xpack.security.cookieName=sid-<kibana-port>` so instances on `localhost` don't share the default `sid` cookie and log each other out

**Synthetics private locations with several Kibanas:** `run-data synthetics` derives the Fleet Server host port from the Kibana port (`8220 + port − 5601`; 5607 → 8226). Every instance (5601 included) gets its own `fleet-server-<port>` / `elastic-agent-<port>` containers with `--restart unless-stopped`, so they survive Docker restarts (the stock Kibana script uses `--rm` and a fixed port 8220; `--legacy` falls back to it). `run-data synthetics reset`, `dev-start.sh kill` and `switch` remove only that instance's containers. `dev-start.sh` also writes this port into `xpack.fleet.fleetServerHosts` in `kibana.dev.yml` (`__FLEET_SERVER_PORT__`); older worktrees still have `8220` and need it edited plus a Kibana restart.

**Manual usage:**
```bash
kbn-start.sh <data-folder> --kibana-port 5601 --es-port 9200 --host kibana-feat.local
kbn-start.sh <data-folder> --kibana-port 5601 --es-port 9200 -E xpack.foo=bar
```

---

## Daily Workflow

**Morning:**
```bash
~/dev-start.sh    # recreates sessions if gone, attaches if already running
```

**Switch between sessions (no restarts):**
```
Ctrl-a s → select kibana-main or kibana-feat
```

**Review a colleague's PR:**
```bash
~/dev-start.sh new feat/colleague-branch
# done reviewing:
~/dev-start.sh kill colleague-branch
```

**Start a new feature:**
```bash
~/dev-start.sh switch feature/new-feature-branch
# kibana-feat now runs the new branch on default ports, fully configured
```

**End of day:**
```
Ctrl-a d    # detach — everything keeps running
```

---

## Known Behaviours & Gotchas

- **Branch names with dots** (e.g. `9.3`) — tmux can't use dots in session names (it interprets `.` as a separator). The script converts them to hyphens: `kibana-9-3`. The worktree folder keeps the original name `9.3`.
- **Branch names with underscores** — preserved as-is in session names.
- **`kibana.dev.yml` not regenerated on `new`** — if a worktree already has a `kibana.dev.yml` with wrong ports (e.g. from a previous `new` run), the script skips generation. Run `~/dev-start.sh list` to see mismatch warnings, then delete the file and re-run.
- **Sessions survive terminal close** — tmux keeps everything running. Only a machine reboot kills sessions.
- **Auto-recovery of orphaned sessions** — when you run `dev-start.sh` (no args), it automatically detects worktrees without a matching tmux session and recreates them with the same ports. Use `dev-start.sh recover` to do the same without restarting the permanent sessions.
- **`list` only shows active sessions in port assignments** — dead sessions are filtered out automatically.

---

## Files

| File | Location | Purpose |
|---|---|---|
| `dev-start.sh` | `~/dev-start.sh` → symlink | Master orchestrator |
| `kbn-start.sh` | `~/bin/kbn-start.sh` → symlink | ES + Kibana launcher |
| `kibana.dev.yml.template` | repo root — picked up automatically by `dev-start.sh` | Config template with `__KIBANA_PORT__` / `__ES_PORT__` placeholders |
| State file | `~/.kibana-dev-state` | Tracks current kibana-feat branch and path |
| tmux config | `~/.tmux.conf` | tmux settings, prefix Ctrl-a |
| Presentation | `kibana-dev-workflow.html` | Team presentation with dark/light theme switcher |
| `kibana-dev-env/` | `~/.claude/skills/kibana-dev-env` **and** `~/.cursor/skills/kibana-dev-env` → symlinks | Agent skill (SKILL.md + references), loaded by Claude and Cursor |
| `sync-skill.sh` | repo root | Copies skill to team repo (observability-dev) |

---

## Claude Desktop Project Setup

The scripts live in `~/Documents/Development/AI_projects/kibana-env-setup/` — this is the folder connected to the Claude Desktop Cowork project.

**Symlinks** point from the expected runtime locations to the actual files:
```bash
~/dev-start.sh          → ~/Documents/Development/AI_projects/kibana-env-setup/dev-start.sh
~/bin/kbn-start.sh      → ~/Documents/Development/AI_projects/kibana-env-setup/kbn-start.sh
```

This means:
- Scripts are always run from `~/` and `~/bin/` as usual — nothing changes
- Claude Desktop edits files directly in the project folder
- Changes are **instantly live** — no copying or syncing needed

**To set up symlinks on a new machine:**
```bash
mkdir -p ~/bin
ln -s ~/Documents/Development/AI_projects/kibana-env-setup/dev-start.sh ~/dev-start.sh
ln -s ~/Documents/Development/AI_projects/kibana-env-setup/kbn-start.sh ~/bin/kbn-start.sh
# Skill: symlink into BOTH agent skill dirs (Claude reads ~/.claude/skills, Cursor reads ~/.cursor/skills)
mkdir -p ~/.claude/skills ~/.cursor/skills
ln -sfn ~/Documents/Development/AI_projects/kibana-env-setup/kibana-dev-env ~/.claude/skills/kibana-dev-env
ln -sfn ~/Documents/Development/AI_projects/kibana-env-setup/kibana-dev-env ~/.cursor/skills/kibana-dev-env
chmod +x ~/Documents/Development/AI_projects/kibana-env-setup/dev-start.sh
chmod +x ~/Documents/Development/AI_projects/kibana-env-setup/kbn-start.sh
```

---

## Skill Development Workflow

The `kibana-dev-env` skill lives in three places:

| Location | Type | Purpose |
|---|---|---|
| `kibana-env-setup/kibana-dev-env/` | Source of truth | Develop and iterate here |
| `~/.claude/skills/kibana-dev-env` **+** `~/.cursor/skills/kibana-dev-env` | Symlinks → source | Instantly available in Claude and Cursor |
| `observability-dev/docs/actionable-obs/ai_helpers/skills/` | Copy | Team distribution |

**Workflow:**
1. Edit the skill in this repo (`kibana-dev-env/SKILL.md`, `references/`)
2. Changes are instantly live locally via the symlink
3. When ready to publish: `./sync-skill.sh` copies to the team repo
4. Review the diff in observability-dev, commit, push, create PR

