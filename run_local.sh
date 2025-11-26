#!/bin/bash

# OpenHands local run script for MacOS with custom ports and workspace
# Workspace will be $HOME/projects/mono (created if missing)
set -e

# Always run from the script's directory (repo root)
cd "$(dirname "$0")"
echo "Script path: $(pwd)/$(basename "$0")"

# Create workspace if missing
mkdir -p "$HOME/projects/mono"

# Build all necessary components
make build

# Export ports for backend/frontend/runtime
export BACKEND_PORT=60001
export FRONTEND_PORT=60002
export VSCODE_PORT=60003
export RUNTIME_PORT=60004

# Export OpenHands config file
export OPENHANDS_CONFIG="$(pwd)/config.template.toml"

# Export workspace envs for plugins (if needed)
export WORKSPACE_BASE="$HOME/projects/mono"
export WORKSPACE_MOUNT_PATH_IN_SANDBOX="$HOME/projects/mono"

# Run OpenHands backend (example)
nohup env port=$BACKEND_PORT poetry run python -m openhands.server > backend.log 2>&1 &

# Run OpenHands runtime (example)
nohup poetry run python -m openhands.runtime.action_execution_server $RUNTIME_PORT > runtime.log 2>&1 &

# Run OpenHands frontend (example)
cd frontend
nohup npm run dev -- --port $FRONTEND_PORT --host 0.0.0.0 > ../frontend.log 2>&1 &
cd ..

echo "OpenHands backend running on port $BACKEND_PORT"
echo "\nValidating services..."

# Validate backend
curl -sSf http://localhost:$BACKEND_PORT/health || echo "Backend not responding on port $BACKEND_PORT"

# Validate runtime (file viewer server)
RUNTIME_HEALTH_URL=$(grep -o 'http://localhost:[0-9]\+' runtime.log | tail -1)/health
if [ -n "$RUNTIME_HEALTH_URL" ]; then
  curl -sSf "$RUNTIME_HEALTH_URL" || echo "Runtime not responding at $RUNTIME_HEALTH_URL"
else
  echo "Runtime health URL not found in runtime.log"
fi

# Validate frontend
FRONTEND_PORT_USED=$FRONTEND_PORT
if grep -q 'Port [0-9]\+ is in use, trying another one' frontend.log; then
  FRONTEND_PORT_USED=$(grep -o 'Local:   http://localhost:[0-9]\+' frontend.log | tail -1 | grep -o '[0-9]\+')
fi
curl -sSf http://localhost:$FRONTEND_PORT_USED/ || echo "Frontend not responding on port $FRONTEND_PORT_USED"

echo "OpenHands runtime running on port $RUNTIME_PORT"
echo "OpenHands frontend running on port $FRONTEND_PORT"
echo "Workspace: $HOME/projects/mono (host and sandbox)"
