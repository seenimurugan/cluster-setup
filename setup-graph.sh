#!/usr/bin/env bash
set -euo pipefail
# Idempotent setup for graphify + code-review-graph in this repo.
# Run once after `git clone` on a new machine.
command -v graphify >/dev/null || { echo "Install graphify first: pipx install graphifyy"; exit 1; }
command -v code-review-graph >/dev/null || { echo "Install crg first: pipx install code-review-graph"; exit 1; }
graphify hook install
code-review-graph install
code-review-graph build
echo "graph setup complete in $(pwd)"
