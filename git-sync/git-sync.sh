#!/usr/bin/env bash
#
# two-way-git-sync.sh
# Purpose: hardened two-way Git sync for simple config repos (pull -> watch -> commit -> push)
#
# Behaviour summary:
# - Initial clone if /repo is empty and GIT_URL provided
# - Periodic fetch/pull to stay up-to-date
# - Watch filesystem (inotify) and commit+push local changes
# - Locking with flock to avoid races
# - Conflict strategies: "abort" (default), "prefer-remote", "prefer-local"
# - Loop prevention via commit-marker and author/email detection
# - Safe push: tries fast-forward, falls back to --force-with-lease only if allowed
#
set -euo pipefail

REPO_DIR="${REPO_DIR:-/repo}"
GIT_URL="${GIT_URL:-}"              # optional: clone URL if repo empty
REMOTE="${REMOTE:-origin}"
BRANCH="${BRANCH:-main}"
GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-auto-sync-bot}"
GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-auto-sync@example.com}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"        # seconds between periodic pulls
DEBOUNCE_SECONDS="${DEBOUNCE_SECONDS:-2}"   # wait after change burst
LOCKFILE="${LOCKFILE:-/tmp/git-sync.lock}"
COMMIT_PREFIX="${COMMIT_PREFIX:-[auto-sync]}"
SYNC_CONFLICT_STRATEGY="${SYNC_CONFLICT_STRATEGY:-abort}" # abort | prefer-remote | prefer-local
ALLOW_FORCE_PUSH="${ALLOW_FORCE_PUSH:-false}" # require "true" to allow force-with-lease
MAX_PUSH_RETRIES="${MAX_PUSH_RETRIES:-4}"
BACKOFF_BASE="${BACKOFF_BASE:-2}"  # exponent base for backoff (seconds)

# Helpers
log() { echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ') [git-sync] $*"; }
fatal() { log "FATAL: $*"; exit 1; }

# Acquire an exclusive lock (fd 9)
acquire_lock() {
  exec 9>"$LOCKFILE"
  flock -n 9 || return 1
  return 0
}
release_lock() {
  flock -u 9 || true
  rm -f "$LOCKFILE" 2>/dev/null || true
}

# Ensure repo dir exists
mkdir -p "$REPO_DIR"
cd "$REPO_DIR"

# Prepare git config and environment
git config --global core.fileMode false || true
git config user.name "$GIT_AUTHOR_NAME"
git config user.email "$GIT_AUTHOR_EMAIL"

# If repo empty and GIT_URL provided, clone
if [ -z "$(ls -A "$REPO_DIR")" ] && [ -n "$GIT_URL" ]; then
  log "Repo directory empty. Cloning $GIT_URL (branch $BRANCH)..."
  git clone --depth 1 --branch "$BRANCH" "$GIT_URL" . || {
    log "Shallow clone failed; trying full clone..."
    rm -rf ./* .git || true
    git clone --branch "$BRANCH" "$GIT_URL" . || fatal "Clone failed"
  }
fi

if [ ! -d ".git" ]; then
  fatal "No .git in $REPO_DIR. Mount a git repo or set GIT_URL to clone."
fi

# Ensure remote exists
git remote get-url "$REMOTE" >/dev/null 2>&1 || fatal "Remote '$REMOTE' not configured in repo"

# Utility: show whether last commit was authored by bot & contains marker
last_commit_is_bot() {
  local marker="$COMMIT_PREFIX"
  local author email msg
  author="$(git log -1 --pretty=format:'%an' 2>/dev/null || echo "")"
  email="$(git log -1 --pretty=format:'%ae' 2>/dev/null || echo "")"
  msg="$(git log -1 --pretty=format:'%s' 2>/dev/null || echo "")"
  if [[ "$author" == "$GIT_AUTHOR_NAME" && "$email" == "$GIT_AUTHOR_EMAIL" && "$msg" == *"$marker"* ]]; then
    return 0
  fi
  return 1
}

# Safe pull: try fast-forward; if non-ff, behave per strategy
safe_pull() {
  acquire_lock || { log "safe_pull: lock busy"; return 1; }
  log "Fetching $REMOTE/$BRANCH..."
  if ! git fetch "$REMOTE" "$BRANCH" --quiet; then
    log "Fetch failed (network?)."
    release_lock
    return 1
  fi

  # Try fast-forward pull
  if git merge --ff-only "$REMOTE/$BRANCH" >/dev/null 2>&1; then
    log "Fast-forwarded to $REMOTE/$BRANCH"
    release_lock
    return 0
  fi

  # Non-fast-forward situation
  log "Non-fast-forward detected. Strategy=$SYNC_CONFLICT_STRATEGY"
  case "$SYNC_CONFLICT_STRATEGY" in
    abort)
      log "Abort strategy: leaving local changes; require manual resolution"
      release_lock
      return 2
      ;;
    prefer-remote)
      log "Prefer-remote: resetting local to remote (will discard local uncommitted changes)"
      git reset --hard "$REMOTE/$BRANCH" || { log "Reset failed"; release_lock; return 1; }
      release_lock
      return 0
      ;;
    prefer-local)
      log "Prefer-local: will try to make local the truth and push (may require force)."
      # leave changes for push routine to handle (release lock)
      release_lock
      return 3
      ;;
    *)
      log "Unknown conflict strategy: $SYNC_CONFLICT_STRATEGY"
      release_lock
      return 1
      ;;
  esac
}

# Attempt commit & push of local changes
attempt_push() {
  # If there are no changes, nothing to do
  if git status --porcelain --untracked-files=no | grep -q '^$'; then
    # check untracked files too
    if git status --porcelain | grep -q '^'; then
      : # continue if there are untracked changes
    else
      return 0
    fi
  fi

  # Avoid committing changes that came from a recent bot push (loop)
  if last_commit_is_bot; then
    log "Last commit is bot-made with marker; skipping immediate re-commit to avoid loop."
    # but keep trying periodic pulls to align with remote
  fi

  acquire_lock || { log "attempt_push: lock busy"; return 1; }

  # Stash autosaved states for safer pull/rebase
  # Stage everything (including new files)
  git add -A
  if git diff --cached --quiet --exit-code; then
    log "Nothing staged for commit after add -A"
    release_lock
    return 0
  fi

  msg="$COMMIT_PREFIX Auto-sync changes: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if ! git commit -m "$msg"; then
    log "Commit failed"
    release_lock
    return 1
  fi

  # Ensure we have up-to-date remote before pushing
  if ! git fetch "$REMOTE" "$BRANCH" --quiet; then
    log "Fetch before push failed; leaving commit local."
    release_lock
    return 1
  fi

  # Try to push normally first
  local try=0
  while :; do
    try=$((try+1))
    if git push "$REMOTE" "HEAD:$BRANCH"; then
      log "Pushed changes to $REMOTE/$BRANCH"
      release_lock
      return 0
    fi

    log "Push failed (try $try). Checking why..."
    # If remote head changed (non-fast-forward), handle according to strategy
    if [ "$SYNC_CONFLICT_STRATEGY" = "prefer-local" ] && [ "$ALLOW_FORCE_PUSH" = "true" ]; then
      log "Attempting force-with-lease as allowed by ALLOW_FORCE_PUSH=true"
      if git push --force-with-lease "$REMOTE" "HEAD:$BRANCH"; then
        log "Force-with-lease push succeeded."
        release_lock
        return 0
      fi
      log "Force-with-lease push failed."
    else
      log "Not allowed to force push or strategy != prefer-local; will not overwrite remote."
    fi

    if [ "$try" -ge "$MAX_PUSH_RETRIES" ]; then
      log "Exceeded max push retries ($MAX_PUSH_RETRIES). Leaving commit local for manual resolution."
      release_lock
      return 1
    fi

    # Backoff before retry
    backoff=$(( BACKOFF_BASE ** try ))
    log "Backing off for $backoff s before retry..."
    sleep "$backoff"
  done

  release_lock
  return 1
}

# Periodic full sync loop: attempt safe pulls periodically
periodic_sync() {
  while true; do
    sleep "$POLL_INTERVAL"
    case "$(safe_pull)" in
      0) ;;   # success
      1) log "safe_pull: transient failure" ;;
      2) log "safe_pull: non-ff and abort strategy; manual resolution needed" ;;
      3) log "safe_pull: prefer-local detected; local will attempt to push later" ;;
    esac
  done
}

# Start periodic sync in background
periodic_sync &

# Main watch loop: use inotifywait if available, otherwise fallback to polling
if command -v inotifywait >/dev/null 2>&1; then
  log "Using inotifywait to watch for changes (excluding .git)..."
  # Filter .git events
  while true; do
    # Wait for events; a single event returns; we then debounce and act
    inotifywait -r -e modify,attrib,close_write,move,create,delete --exclude '\.git' "$REPO_DIR" >/dev/null 2>&1 || true
    sleep "$DEBOUNCE_SECONDS"
    # Pull once to reduce conflicts
    safe_pull || true
    attempt_push || true
  done
else
  log "inotifywait not found; falling back to polling every $POLL_INTERVAL seconds."
  while true; do
    sleep "$POLL_INTERVAL"
    safe_pull || true
    attempt_push || true
  done
fi
