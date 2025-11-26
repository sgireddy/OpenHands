#!/bin/bash

# Always run from the script's directory (repo root)
cd "$(dirname "$0")"
echo "Script path: $(pwd)/$(basename "$0")"

# Ensure we are in a git repo (fixes OpenHands UI workspace warning)
if [ ! -d .git ]; then
  echo "No .git directory found. Initializing git repository..."
  git init
  git add .
  git commit -m "Initial commit (auto)"
fi

echo "🏠 Starting OpenHands in Local mode..."
export RUNTIME=local
export INSTALL_DOCKER=0
export VSCODE_URL="http://localhost:51062"

export SANDBOX_VOLUMES=~/projects:/workspace:rw
export RUNTIME_MOUNT=~/projects:/workspace:rw

# Use local config if provided, else default
echo "Using config: ${OPENHANDS_CONFIG:-$(pwd)/config.template.toml}"

make run CONFIG_FILE="${OPENHANDS_CONFIG:-$(pwd)/config.template.toml}"
