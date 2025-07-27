#!/bin/bash

# Always run from the script's directory (repo root)
cd "$(dirname "$0")"
echo "Script path: $(pwd)/$(basename "$0")"

echo "🏠 Starting OpenHands in Local mode..."
export RUNTIME=local
export INSTALL_DOCKER=0
# export SANDBOX_VOLUMES=/Users/reactivedev/projects:/workspace:rw
# export RUNTIME_MOUNT=/Users/reactivedev/projects:/workspace:rw

# Use local config if provided, else default
echo "Using config: ${OPENHANDS_CONFIG:-$(pwd)/config.template.toml}"

make run CONFIG_FILE="${OPENHANDS_CONFIG:-$(pwd)/config.template.toml}"
