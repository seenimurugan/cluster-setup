#!/usr/bin/env bash
# 00-prereqs.sh — install command-line tools needed by deploy.sh.
# Idempotent: brew skips already-installed formulae.
set -euo pipefail

if ! command -v brew &>/dev/null; then
  echo "ERROR: Homebrew not found. Install it first: https://brew.sh"
  exit 1
fi

REQUIRED=(kubectl helm gh jq gettext git zstd tailscale immich-go age kubeseal)

echo "[prereqs] Ensuring brew packages: ${REQUIRED[*]}"
for pkg in "${REQUIRED[@]}"; do
  if brew list --formula "$pkg" &>/dev/null; then
    echo "  ✓ $pkg already installed"
  else
    echo "  → installing $pkg"
    brew install "$pkg"
  fi
done

# gettext provides envsubst but is keg-only; expose it on PATH for this shell.
if ! command -v envsubst &>/dev/null; then
  GETTEXT_PREFIX="$(brew --prefix gettext 2>/dev/null || true)"
  if [ -n "$GETTEXT_PREFIX" ] && [ -x "$GETTEXT_PREFIX/bin/envsubst" ]; then
    export PATH="$GETTEXT_PREFIX/bin:$PATH"
  fi
fi
if ! command -v envsubst &>/dev/null; then
  echo "ERROR: envsubst still not on PATH after brew install gettext."
  echo "       Run: echo 'export PATH=\"\$(brew --prefix gettext)/bin:\$PATH\"' >> ~/.zshrc"
  exit 1
fi

echo "[prereqs] All set."
