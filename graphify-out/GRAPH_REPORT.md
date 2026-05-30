# Graph Report - cluster-setup  (2026-05-30)

## Corpus Check
- 58 files · ~33,582 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 469 nodes · 434 edges · 60 communities (38 shown, 22 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `63a4327d`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- [[_COMMUNITY_Community 0|Community 0]]
- [[_COMMUNITY_Community 1|Community 1]]
- [[_COMMUNITY_Community 2|Community 2]]
- [[_COMMUNITY_Community 3|Community 3]]
- [[_COMMUNITY_Community 4|Community 4]]
- [[_COMMUNITY_Community 5|Community 5]]
- [[_COMMUNITY_Community 6|Community 6]]
- [[_COMMUNITY_Community 7|Community 7]]
- [[_COMMUNITY_Community 8|Community 8]]
- [[_COMMUNITY_Community 9|Community 9]]
- [[_COMMUNITY_Community 10|Community 10]]
- [[_COMMUNITY_Community 11|Community 11]]
- [[_COMMUNITY_Community 12|Community 12]]
- [[_COMMUNITY_Community 13|Community 13]]
- [[_COMMUNITY_Community 14|Community 14]]
- [[_COMMUNITY_Community 15|Community 15]]
- [[_COMMUNITY_Community 16|Community 16]]
- [[_COMMUNITY_Community 17|Community 17]]
- [[_COMMUNITY_Community 18|Community 18]]
- [[_COMMUNITY_Community 19|Community 19]]
- [[_COMMUNITY_Community 20|Community 20]]
- [[_COMMUNITY_Community 21|Community 21]]
- [[_COMMUNITY_Community 22|Community 22]]
- [[_COMMUNITY_Community 23|Community 23]]
- [[_COMMUNITY_Community 24|Community 24]]
- [[_COMMUNITY_Community 25|Community 25]]
- [[_COMMUNITY_Community 26|Community 26]]
- [[_COMMUNITY_Community 27|Community 27]]
- [[_COMMUNITY_Community 28|Community 28]]
- [[_COMMUNITY_Community 29|Community 29]]
- [[_COMMUNITY_Community 30|Community 30]]
- [[_COMMUNITY_Community 31|Community 31]]
- [[_COMMUNITY_Community 32|Community 32]]
- [[_COMMUNITY_Community 33|Community 33]]
- [[_COMMUNITY_Community 34|Community 34]]
- [[_COMMUNITY_Community 35|Community 35]]
- [[_COMMUNITY_Community 36|Community 36]]
- [[_COMMUNITY_Community 37|Community 37]]
- [[_COMMUNITY_Community 38|Community 38]]
- [[_COMMUNITY_Community 39|Community 39]]
- [[_COMMUNITY_Community 40|Community 40]]
- [[_COMMUNITY_Community 41|Community 41]]
- [[_COMMUNITY_Community 42|Community 42]]
- [[_COMMUNITY_Community 43|Community 43]]
- [[_COMMUNITY_Community 44|Community 44]]
- [[_COMMUNITY_Community 45|Community 45]]
- [[_COMMUNITY_Community 46|Community 46]]
- [[_COMMUNITY_Community 47|Community 47]]
- [[_COMMUNITY_Community 48|Community 48]]
- [[_COMMUNITY_Community 49|Community 49]]
- [[_COMMUNITY_Community 50|Community 50]]
- [[_COMMUNITY_Community 51|Community 51]]
- [[_COMMUNITY_Community 52|Community 52]]
- [[_COMMUNITY_Community 53|Community 53]]
- [[_COMMUNITY_Community 54|Community 54]]
- [[_COMMUNITY_Community 55|Community 55]]
- [[_COMMUNITY_Community 56|Community 56]]
- [[_COMMUNITY_Community 57|Community 57]]
- [[_COMMUNITY_Community 58|Community 58]]
- [[_COMMUNITY_Community 59|Community 59]]

## God Nodes (most connected - your core abstractions)
1. `2026-05-26 — Migration to Pattern B (Tailscale in-cluster)` - 20 edges
2. `2026-05-26` - 15 edges
3. `Homelab maintenance — self-serve runbook` - 13 edges
4. `Add a new app to the homelab cluster` - 12 edges
5. `9. Managing content on the docs site` - 12 edges
6. `Keep the Mac always reachable (no sleep)` - 11 edges
7. `Command Log` - 11 edges
8. `cluster-setup` - 10 edges
9. `2026-05-27 — Migration off the HDD (Immich ENFILE root cause)` - 10 edges
10. `Homelab architecture — mental model` - 9 edges

## Surprising Connections (you probably didn't know these)
- None detected - all connections are within the same source files.

## Communities (60 total, 22 thin omitted)

### Community 0 - "Community 0"
Cohesion: 0.05
Nodes (41): 0. Quick health check (run first when anything seems wrong), 10. The "everything broke, start over" nuclear option, 11. Cheat sheet — most-used commands, 1. After a Mac reboot — what auto-recovers, 2. Where everything lives, 3. Restart things (smallest to biggest blast radius), 4. Scale things, 5. Where to find logs (+33 more)

### Community 1 - "Community 1"
Cohesion: 0.06
Nodes (30): 2026-05-26, 2026-05-27 — Migration off the HDD (Immich ENFILE root cause), 2026-05-28, Backup pattern: single tar.zst file, not rsync, Docsify with a `basePath` needs absolute sidebar links AND `relativePath: true`, File ownership note, HDD name has a space and apostrophe, Immich chart release 0.12.0 has broken release artifact (+22 more)

### Community 2 - "Community 2"
Cohesion: 0.08
Nodes (25): 7a. Add chart, discover bundled-Postgres absence, 7b. Deploy Postgres separately, 7c. Install Immich chart, 9a. Tailscale prep (manual, by user), 9b. Install Tailscale operator, 9c. First attempt: LoadBalancer with tailscale class, 9d. Switched to Tailscale Ingress for HTTPS, 9e. Cleanup: remove all Mac-side Tailscale (+17 more)

### Community 3 - "Community 3"
Cohesion: 0.08
Nodes (24): Check last run status, Clean up old Job records, Enable nightly automation later (when second HDD is in place), Expected backup log lines, Expected mover log lines, HDD space usage, If a PVC is recreated (SSD paths change), If the HDD is unmounted (e.g. Mac sleep/disconnect) (+16 more)

### Community 4 - "Community 4"
Cohesion: 0.10
Nodes (20): §1 — Deploy a pre-built image (simplest), §2 — Deploy your own code (Java/Python/Node/Go/…), 2a. Containerize your app, 2b. Get the image to the cluster, 2c. Deploy with the §1 template, §3 — Add a database for the app, §4 — Tailscale Ingress (HTTPS from any device on your tailnet), §5 — LAN + localhost access (optional) (+12 more)

### Community 5 - "Community 5"
Cohesion: 0.10
Nodes (20): Battery considerations, Change later — battery-only sleep / split AC vs battery / full revert, Clamshell mode (closed lid), How `pmset` flags work, Inspect what's currently set, Keep the Mac always reachable (no sleep), Mode A — current setup (Mac never sleeps, AC + battery), Mode B — sleep on battery only (preserves battery when unplugged) (+12 more)

### Community 6 - "Community 6"
Cohesion: 0.10
Nodes (19): External HDD (`/Volumes/Seeni's HDD`), Homelab architecture — mental model, How to extend the diagram, Internal SSD (where live data now lives), k3s cluster, launchd port-forward (Mac-local), Layers (outside → in), namespace `homelab` — where the actual apps live (+11 more)

### Community 7 - "Community 7"
Cohesion: 0.10
Nodes (20): 2026-05-26 — Migration to Pattern B (Tailscale in-cluster), After uninstalling Mac Tailscale, the Mac itself can't reach `.ts.net` hosts, Don't scale ML pods up *during* the bulk upload — only after, Helm `--set-string` with empty values DELETES Secret keys (gotcha), How to recover from accidentally-deleted operator-oauth Secret, HTTPS Certificates must be enabled in Tailscale admin, Immich job concurrency must be 1 because of exFAT bottleneck, Ingress can use `defaultBackend` for single-service exposure (+12 more)

### Community 8 - "Community 8"
Cohesion: 0.12
Nodes (15): 1. Prerequisites, 2. Format, 3. Create directory layout, 4. Housekeeping, 5. Sanity checks, 6. Troubleshooting, 7. What's next, Case-sensitivity (+7 more)

### Community 9 - "Community 9"
Cohesion: 0.13
Nodes (14): Adding a new app — pick the right DB, Backup approaches, Databases in the homelab, Inspect a database, Open Grocy's SQLite interactively, Open Immich's Postgres, Open shared Postgres, Real-world analogy (+6 more)

### Community 10 - "Community 10"
Cohesion: 0.13
Nodes (14): 1. Confirm the HDD is actually missing, 2. Check what macOS sees, 3. Mount the drive (most common fix — what just worked), 4. Filesystem repair (if mount fails), 5. Hardware troubleshooting (drive not detected at all), 6. Refresh the cluster — usually NOT needed anymore, 7. Verify, HDD recovery runbook (+6 more)

### Community 11 - "Community 11"
Cohesion: 0.31
Nodes (12): bool, Path, already_organized(), classify(), is_excluded(), is_inside_excluded_dir(), main(), plan_target() (+4 more)

### Community 12 - "Community 12"
Cohesion: 0.17
Nodes (12): 9. Managing content on the docs site, Add a new file, Caching gotcha, Delete a file, Embed Excel/Spreadsheet content nicely, File types & how they display, How URL routing works (so you can predict the URLs), Make a new markdown file appear in the sidebar (+4 more)

### Community 13 - "Community 13"
Cohesion: 0.18
Nodes (10): cluster-setup, Docs, Layout, Migrating to a new Mac, Prerequisites, Quick start, Tear-down, Useful commands once deployed (+2 more)

### Community 14 - "Community 14"
Cohesion: 0.20
Nodes (9): Caveats, Helm Upgrade Commands, Helm Value Patches — Tiered Storage HDD Mounts, Immich — `~/homelab/immich-values.yaml`, Jellyfin — `~/homelab/jellyfin-values.yaml`, Verification — rendered template, Verification — rendered template, What to add (+1 more)

### Community 15 - "Community 15"
Cohesion: 0.22
Nodes (8): Adding new informational content, Apps (grouped per-app — usage + maintenance + troubleshooting), Cluster-wide (one-stop), Documentation index, Homelab K8s Setup — Knowledge Base, Reference, Where files live, Workflow

### Community 16 - "Community 16"
Cohesion: 0.25
Nodes (7): args, command, cwd, env, type, mcpServers, code-review-graph

### Community 17 - "Community 17"
Cohesion: 0.25
Nodes (7): Backup TODO (deferred), Config files, Mac state, Session State, Storage layout (unchanged), What's left for the user (manual), What's running

### Community 18 - "Community 18"
Cohesion: 0.40
Nodes (4): Debug Issue, Steps, Tips, Token Efficiency Rules

### Community 19 - "Community 19"
Cohesion: 0.40
Nodes (4): Explore Codebase, Steps, Tips, Token Efficiency Rules

### Community 20 - "Community 20"
Cohesion: 0.40
Nodes (4): Refactor Safely, Safety Checks, Steps, Token Efficiency Rules

### Community 21 - "Community 21"
Cohesion: 0.40
Nodes (4): Output Format, Review Changes, Steps, Token Efficiency Rules

### Community 22 - "Community 22"
Cohesion: 0.40
Nodes (4): Key Tools, MCP Tools: code-review-graph, When to use graph tools FIRST, Workflow

### Community 23 - "Community 23"
Cohesion: 0.40
Nodes (4): Key Tools, MCP Tools: code-review-graph, When to use graph tools FIRST, Workflow

### Community 24 - "Community 24"
Cohesion: 0.40
Nodes (4): Key Tools, MCP Tools: code-review-graph, When to use graph tools FIRST, Workflow

### Community 25 - "Community 25"
Cohesion: 0.40
Nodes (4): Key Tools, MCP Tools: code-review-graph, When to use graph tools FIRST, Workflow

### Community 26 - "Community 26"
Cohesion: 0.40
Nodes (4): Debug Issue, Steps, Tips, Token Efficiency Rules

### Community 27 - "Community 27"
Cohesion: 0.40
Nodes (4): Explore Codebase, Steps, Tips, Token Efficiency Rules

### Community 28 - "Community 28"
Cohesion: 0.40
Nodes (4): Refactor Safely, Safety Checks, Steps, Token Efficiency Rules

### Community 29 - "Community 29"
Cohesion: 0.40
Nodes (4): Output Format, Review Changes, Steps, Token Efficiency Rules

### Community 30 - "Community 30"
Cohesion: 0.40
Nodes (4): Key Tools, MCP Tools: code-review-graph, When to use graph tools FIRST, Workflow

### Community 31 - "Community 31"
Cohesion: 0.40
Nodes (4): Key Tools, MCP Tools: code-review-graph, When to use graph tools FIRST, Workflow

### Community 32 - "Community 32"
Cohesion: 0.70
Nodes (3): log(), mv_to(), reorganize-personal.sh script

### Community 33 - "Community 33"
Cohesion: 0.50
Nodes (3): hooks, PostToolUse, SessionStart

### Community 34 - "Community 34"
Cohesion: 0.50
Nodes (3): hooks, AfterTool, SessionStart

### Community 35 - "Community 35"
Cohesion: 0.50
Nodes (3): hooks, PostToolUse, SessionStart

### Community 36 - "Community 36"
Cohesion: 0.83
Nodes (3): stream_e(), stream_f(), upload-drones-and-takeout.sh script

### Community 37 - "Community 37"
Cohesion: 0.83
Nodes (3): stream_c(), stream_d(), upload-mac-photos-to-immich.sh script

## Knowledge Gaps
- **311 isolated node(s):** `setup-graph.sh script`, `command`, `args`, `cwd`, `type` (+306 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **22 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Homelab maintenance — self-serve runbook` connect `Community 0` to `Community 12`?**
  _High betweenness centrality (0.011) - this node is a cross-community bridge._
- **Why does `Learnings` connect `Community 1` to `Community 7`?**
  _High betweenness centrality (0.008) - this node is a cross-community bridge._
- **Why does `2026-05-26 — Migration to Pattern B (Tailscale in-cluster)` connect `Community 7` to `Community 1`?**
  _High betweenness centrality (0.007) - this node is a cross-community bridge._
- **What connects `setup-graph.sh script`, `command`, `args` to the rest of the system?**
  _313 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Community 0` be split into smaller, more focused modules?**
  _Cohesion score 0.047619047619047616 - nodes in this community are weakly interconnected._
- **Should `Community 1` be split into smaller, more focused modules?**
  _Cohesion score 0.06451612903225806 - nodes in this community are weakly interconnected._
- **Should `Community 2` be split into smaller, more focused modules?**
  _Cohesion score 0.07692307692307693 - nodes in this community are weakly interconnected._