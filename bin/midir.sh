#!/usr/bin/env bash
set -euo pipefail

# --- Config ---
# This script lives in <repo>/bin, so the repo root (Docker build context,
# version file, git checkout) is its parent directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTAINER="midir"
# Persistent data (SQLite DB, settings, session logs) lives here and is
# bind-mounted into the container at /app. Kept off the repo/OS disk on the
# md0 RAID array; override with MIDIR_RUNTIME_DIR if needed.
RUNTIME_DIR="${MIDIR_RUNTIME_DIR:-/mnt/md0/Midir/runtime}"
VERSION_FILE="$REPO_ROOT/.midir-version"

# Image tag the container runs. Pinned to the version recorded by `update` so a
# rebuild of a newer version never replaces what is currently deployed. Falls
# back to :latest if no version has been recorded yet.
if [[ -f "$VERSION_FILE" ]]; then
  IMAGE="midir:$(cat "$VERSION_FILE")"
else
  IMAGE="midir:latest"
fi

run_container() {
  mkdir -p "$RUNTIME_DIR/logs"
  docker run -d \
    --name "$CONTAINER" \
    --restart unless-stopped \
    --network host \
    --cap-add NET_RAW \
    --cap-add NET_ADMIN \
    -v "$RUNTIME_DIR:/app" \
    "$IMAGE"
}

exists() { docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; }
running() { docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; }

start() {
  if running; then
    echo "Midir is already running."
  elif exists; then
    echo "Starting existing Midir container..."
    docker start "$CONTAINER"
  else
    echo "Creating and starting Midir container..."
    run_container
  fi
  status
}

stop() {
  if exists; then
    echo "Stopping Midir container..."
    docker stop "$CONTAINER" >/dev/null
    docker rm "$CONTAINER" >/dev/null
    echo "Stopped and removed."
  else
    echo "Midir container does not exist."
  fi
}

restart() {
  stop
  start
}

status() {
  if running; then
    docker ps --filter "name=^/${CONTAINER}$" --format 'table {{.Names}}\t{{.Status}}'
    echo "Dashboard: http://$(hostname -I | awk '{print $1}'):8030"
  elif exists; then
    echo "Midir exists but is stopped."
  else
    echo "Midir container does not exist."
  fi
}

logs() { docker logs -f "$CONTAINER"; }

update() {
  echo "Pulling latest source..."
  git -C "$REPO_ROOT" pull --ff-only

  local version
  version="$(git -C "$REPO_ROOT" describe --tags --always)"
  echo "Building midir:$version (also tagging :latest)..."
  docker build -t "midir:$version" -t "midir:latest" "$REPO_ROOT"

  echo "$version" > "$VERSION_FILE"
  IMAGE="midir:$version"
  echo "Recorded current version: $version"

  restart
}

sync() {
  # Pull the latest release/changes from the upstream repo (Marcentus/Midir)
  # into your fork. This does NOT build or deploy — run `update` afterward.
  if ! git -C "$REPO_ROOT" remote get-url upstream >/dev/null 2>&1; then
    echo "No 'upstream' remote configured. Add it with:"
    echo "  git -C \"$REPO_ROOT\" remote add upstream https://github.com/Marcentus/Midir.git"
    exit 1
  fi

  local branch
  branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
  if [[ "$branch" != "master" ]]; then
    echo "You are on '$branch', not master. Switch to master before syncing upstream:"
    echo "  git -C \"$REPO_ROOT\" checkout master"
    exit 1
  fi

  if ! git -C "$REPO_ROOT" diff --quiet || ! git -C "$REPO_ROOT" diff --cached --quiet; then
    echo "Working tree has uncommitted changes. Commit or stash them first."
    exit 1
  fi

  echo "Fetching upstream..."
  git -C "$REPO_ROOT" fetch upstream --tags

  echo "Merging upstream/master into master..."
  if git -C "$REPO_ROOT" merge --no-edit upstream/master; then
    echo "Pushing to your fork (origin/master)..."
    git -C "$REPO_ROOT" push origin master
    echo "Done. Run '$0 update' to build & redeploy the new version."
  else
    echo
    echo "Merge hit conflicts. Resolve them, then:"
    echo "  git -C \"$REPO_ROOT\" add <files> && git -C \"$REPO_ROOT\" commit && git -C \"$REPO_ROOT\" push origin master"
    echo "  (to abort instead: git -C \"$REPO_ROOT\" merge --abort)"
    exit 1
  fi
}

versions() {
  echo "Built Midir images:"
  docker images "midir" --format 'table {{.Tag}}\t{{.CreatedSince}}\t{{.Size}}'
  if [[ -f "$VERSION_FILE" ]]; then
    echo
    echo "Currently deployed: $(cat "$VERSION_FILE")"
  fi
}

case "${1:-}" in
  start)    start ;;
  stop)     stop ;;
  restart)  restart ;;
  status)   status ;;
  logs)     logs ;;
  update)   update ;;
  sync)     sync ;;
  versions) versions ;;
  *)
    echo "Usage: $0 {start|stop|restart|status|logs|update|sync|versions}"
    exit 1
    ;;
esac
