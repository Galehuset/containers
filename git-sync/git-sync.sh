#!/usr/bin/env bash
#
# two-way-git-sync-pat.sh
#
# Hardened two-way Git sync using a Personal Access Token (PAT) for HTTPS auth.
# Now supports --init: perform initial clone/sync once and exit (useful in initContainers).
#
# Usage:
#  ./two-way-git-sync-pat.sh [--init]     # --init does an initial clone/pull then exits
#  ./two-way-git-sync-pat.sh              # runs continuous watch/poll + commit/push loop
#
set -euo pipefail

# CLI flags
INIT_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --init) INIT_ONLY=1 ;;
    --help|-h)
      cat <<'USAGE'
Usage: two-way-git-sync-pat.sh [--init] [--help]

--init    Perform initial clone/fetch and branch checkout into REPO_DIR, then exit.
--help    Show this help and exit.

Environment variables:
  REPO_DIR, GIT_URL, REMOTE, BRANCH, GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL,
  POLL_INTERVAL, DEBOUNCE_SECONDS, LOCKFILE, COMMIT_PREFIX,
  SYNC_CONFLICT_STRATEGY, ALLOW_FORCE_PUSH, MAX_PUSH_RETRIES, BACKOFF_BASE,
  GIT_TOKEN_FILE, GIT_USER_FILE, GIT_AUTH_TOKEN, GIT_AUTH_USERNAME, NETRC_PATH
USAGE
      exit 0
      ;;
    *) ;;
  esac
done

# --- Configurable defaults ---
REPO_DIR="${REPO_DIR:-/repo}"
GIT_URL="${GIT_URL:-}"              # optional: clone URL if repo empty (can be ssh or https)
REMOTE="${REMOTE:-origin}"
BRANCH="${BRANCH:-main}"
GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-auto-sync-bot}"
GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-auto-sync@example.com}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"
DEBOUNCE_SECONDS="${DEBOUNCE_SECONDS:-2}"
LOCKFILE="${LOCKFILE:-/tmp/git-sync.lock}"
COMMIT_PREFIX="${COMMIT_PREFIX:-[auto-sync]}"
SYNC_CONFLICT_STRATEGY="${SYNC_CONFLICT_STRATEGY:-abort}" # abort | prefer-remote | prefer-local
ALLOW_FORCE_PUSH="${ALLOW_FORCE_PUSH:-false}"
MAX_PUSH_RETRIES="${MAX_PUSH_RETRIES:-4}"
BACKOFF_BASE="${BACKOFF_BASE:-2}"

# Auth inputs (PAT)
GIT_TOKEN_FILE="${GIT_TOKEN_FILE:-/etc/git-secret/token}"
GIT_USER_FILE="${GIT_USER_FILE:-/etc/git-secret/username}"
NETRC_PATH="${NETRC_PATH:-/root/.netrc}"

# --- Helpers ---
log() { echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ') [git-sync] $*"; }
fatal() { log "FATAL: $*"; exit 1; }

# Locking with flock on fd 9
acquire_lock() {
  exec 9>"$LOCKFILE"
  flock -n 9 || return 1
  return 0
}
release_lock() {
  flock -u 9 || true
  rm -f "$LOCKFILE" 2>/dev/null || true
}

# Read token & username from env or files
read_auth() {
  if [ -n "${GIT_AUTH_TOKEN-}" ]; then
    GIT_TOKEN="$GIT_AUTH_TOKEN"
  elif [ -f "$GIT_TOKEN_FILE" ]; then
    GIT_TOKEN="$(tr -d '\r\n' < "$GIT_TOKEN_FILE")"
  else
    GIT_TOKEN=""
  fi

  if [ -n "${GIT_AUTH_USERNAME-}" ]; then
    GIT_USER="$GIT_AUTH_USERNAME"
  elif [ -f "$GIT_USER_FILE" ]; then
    GIT_USER="$(tr -d '\r\n' < "$GIT_USER_FILE")"
  else
    GIT_USER="${GIT_USER:-x-access-token}"
  fi
}

# write .netrc for github.com (or other host if you change ssh_to_https)
write_netrc() {
  if [ -z "${GIT_TOKEN:-}" ]; then
    log "No GIT token provided; skipping .netrc creation."
    return 0
  fi
  umask 077
  cat > "$NETRC_PATH" <<EOF
machine github.com
login ${GIT_USER}
password ${GIT_TOKEN}
EOF
  chmod 600 "$NETRC_PATH"
  log ".netrc written to $NETRC_PATH (host=github.com)"
}

# Convert SSH-style GitHub (git@host:owner/repo.git) to https://host/owner/repo.git
ssh_to_https() {
  local url="$1"
  if [[ "$url" =~ ^git@([^:]+):(.+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    path="${BASH_REMATCH[2]}"
    echo "https://${host}/${path}"
  else
    echo "$url"
  fi
}

# --- Git utilities ---
# Ensure repo dir exists and git configured (global) for author
setup_git_config() {
  log "setting up git config"
  git config --global core.fileMode false || true
  git config --global user.name "$GIT_AUTHOR_NAME"
  git config --global user.email "$GIT_AUTHOR_EMAIL"
}

# Initialize or update repo (used by --init)
init_repo() {
  mkdir -p "$REPO_DIR"
  cd "$REPO_DIR" || fatal "cannot cd to $REPO_DIR"

  setup_git_config
  read_auth
  write_netrc

  if [ -z "$(ls -A "$REPO_DIR")" ] && [ -n "$GIT_URL" ]; then
    clone_url="$GIT_URL"
    if [ -n "${GIT_TOKEN:-}" ]; then
      clone_url="$(ssh_to_https "$GIT_URL")"
    fi
    log "Repo directory empty. Cloning ${clone_url} (branch ${BRANCH})..."
    if git clone --depth 1 --branch "$BRANCH" "$clone_url" .; then
      log "Shallow clone succeeded."
      return 0
    fi
    log "Shallow clone failed; trying full clone..."
    rm -rf ./* .git || true
    git clone --branch "$BRANCH" "$clone_url" . || fatal "Clone failed"
    log "Full clone succeeded."
    return 0
  fi

  # If directory already contains a git repo, try to ensure remote & branch are present
  if [ -d ".git" ]; then
    # convert remote to https if using token and remote is SSH
    if [ -n "${GIT_TOKEN:-}" ]; then
      current_remote_url="$(git remote get-url "$REMOTE" 2>/dev/null || true)"
      if [ -n "$current_remote_url" ]; then
        https_url="$(ssh_to_https "$current_remote_url")"
        if [ "$https_url" != "$current_remote_url" ]; then
          log "Converting remote $REMOTE from SSH to HTTPS: $https_url"
          git remote set-url "$REMOTE" "$https_url"
        fi
      fi
    fi

    # fetch and checkout branch (fast-forward if possible)
    log "Fetching ${REMOTE}/${BRANCH}..."
    git fetch "$REMOTE" "$BRANCH" --quiet || log "Fetch failed during init (network?)"
    # If branch exists remotely, check it out tracking remote
    if git show-ref --verify --quiet "refs/remotes/${REMOTE}/${BRANCH}"; then
      # checkout branch (create local tracking if needed) and fast-forward
      if git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
        log "Local branch $BRANCH exists; attempting fast-forward merge"
        if git merge --ff-only "${REMOTE}/${BRANCH}" >/dev/null 2>&1; then
          log "Fast-forwarded local $BRANCH to ${REMOTE}/${BRANCH}"
        else
          log "Fast-forward not possible for $BRANCH; leaving as-is per init"
        fi
      else
        log "Creating local branch $BRANCH tracking ${REMOTE}/${BRANCH}"
        git checkout -b "$BRANCH" "${REMOTE}/${BRANCH}"
      fi
    else
      log "Remote branch ${REMOTE}/${BRANCH} not present. If desired, push a branch from this repo later."
    fi

    return 0
  fi

  fatal "Directory exists and is not a git repo; please provide an empty REPO_DIR or a valid repo."
}

# Detect whether last commit was authored by the configured bot and contains the COMMIT_PREFIX marker
last_commit_is_bot() {
  # If no commits yet, return false
  if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
    return 1
  fi
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

# Safe pull handling (fast-forward preferred)
safe_pull() {
  acquire_lock || { log "safe_pull: lock busy"; return 1; }
  log "Fetching $REMOTE/$BRANCH..."
  if ! git fetch "$REMOTE" "$BRANCH" --quiet; then
    log "Fetch failed (network?)"
    release_lock
    return 1
  fi

  if git merge --ff-only "$REMOTE/$BRANCH" >/dev/null 2>&1; then
    log "Fast-forwarded to $REMOTE/$BRANCH"
    release_lock
    return 0
  fi

  log "Non-fast-forward detected. Strategy=$SYNC_CONFLICT_STRATEGY"
  case "$SYNC_CONFLICT_STRATEGY" in
    abort)
      log "Abort strategy: leaving local commits for manual resolution"
      release_lock
      return 2
      ;;
    prefer-remote)
      log "Prefer-remote: resetting local to remote (discarding local commits)"
      git reset --hard "$REMOTE/$BRANCH" || { log "Reset failed"; release_lock; return 1; }
      release_lock
      return 0
      ;;
    prefer-local)
      log "Prefer-local: will attempt to push local as canonical"
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

# Attempt to commit & push local changes
attempt_push() {
  # nothing to do if workspace clean (including untracked)
  if ! git status --porcelain | grep -q '^'; then
    return 0
  fi

  if last_commit_is_bot; then
    log "Last commit authored by bot with marker; avoid immediate re-commit to reduce loops."
    # continue to still try pull/push cycles
  fi

  acquire_lock || { log "attempt_push: lock busy"; return 1; }

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

  # fetch remote to know if push will be accepted
  if ! git fetch "$REMOTE" "$BRANCH" --quiet; then
    log "Fetch before push failed; leaving commit local."
    release_lock
    return 1
  fi

  local try=0
  while :; do
    try=$((try+1))
    if git push "$REMOTE" "HEAD:$BRANCH"; then
      log "Pushed changes to $REMOTE/$BRANCH"
      release_lock
      return 0
    fi

    log "Push failed (try $try)."
    if [ "$SYNC_CONFLICT_STRATEGY" = "prefer-local" ] && [ "$ALLOW_FORCE_PUSH" = "true" ]; then
      log "Attempting force-with-lease (allowed)."
      if git push --force-with-lease "$REMOTE" "HEAD:$BRANCH"; then
        log "Force-with-lease push succeeded."
        release_lock
        return 0
      fi
      log "Force-with-lease failed."
    else
      log "Not allowed to force push or strategy != prefer-local; will not overwrite remote."
    fi

    if [ "$try" -ge "$MAX_PUSH_RETRIES" ]; then
      log "Exceeded max push retries ($MAX_PUSH_RETRIES). Leaving commit local for manual resolution."
      release_lock
      return 1
    fi

    backoff=$(( BACKOFF_BASE ** try ))
    log "Backing off for $backoff s before retry..."
    sleep "$backoff"
  done

  release_lock
  return 1
}

# Background periodic sync
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

# --- Main execution ---
# If --init passed, run init_repo and exit (useful for initContainers)
if [ "$INIT_ONLY" -eq 1 ]; then
  log "Running in --init mode: will clone/fetch and exit."
  init_repo
  log "--init completed successfully."
  exit 0
fi

# Normal daemon mode
mkdir -p "$REPO_DIR"
cd "$REPO_DIR" || fatal "cannot cd to $REPO_DIR"

# verify .git exists, else try to init from GIT_URL automatically if provided
if [ ! -d ".git" ]; then
  if [ -n "$GIT_URL" ]; then
    log "No .git found in $REPO_DIR; performing initial clone as part of startup."
    init_repo
  else
    fatal "No .git found in $REPO_DIR and GIT_URL not set. Use --init with GIT_URL or mount a repo."
  fi
fi

# Ensure remote uses https when token is present
read_auth
if [ -n "${GIT_TOKEN:-}" ]; then
  current_remote_url="$(git remote get-url "$REMOTE" 2>/dev/null || true)"
  if [ -n "$current_remote_url" ]; then
    https_url="$(ssh_to_https "$current_remote_url")"
    if [ "$https_url" != "$current_remote_url" ]; then
      log "Converting remote $REMOTE from SSH to HTTPS: $https_url"
      git remote set-url "$REMOTE" "$https_url"
    fi
  fi
fi

setup_git_config
write_netrc

# Start background periodic sync
periodic_sync &

# Main watch loop (inotify if available, otherwise polling)
if command -v inotifywait >/dev/null 2>&1; then
  log "Using inotifywait to watch for changes (excluding .git)..."
  while true; do
    inotifywait -r -e modify,attrib,close_write,move,create,delete --exclude '\.git' "$REPO_DIR" >/dev/null 2>&1 || true
    sleep "$DEBOUNCE_SECONDS"
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
