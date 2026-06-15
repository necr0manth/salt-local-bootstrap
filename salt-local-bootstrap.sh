#!/usr/bin/env bash
set -Eeuo pipefail

# -----------------------------------------------------------------------------
# Salt machine bootstrap
# -----------------------------------------------------------------------------
# What it does:
#   1. Downloads a pinned Salt bootstrap script.
#   2. Verifies it against a hardcoded SHA256 checksum.
#   3. Installs Salt.
#   4. Installs git through Salt pkg.installed, not through apt/yum directly.
#   5. Creates or reuses an SSH key and prints the public key.
#   6. Waits for a repository URL.
#   7. Converts HTTPS Git URLs to SSH-style URLs.
#   8. Clones the repo into the current directory and initializes submodules.
#   9. Resolves and runs a dependency state for the cloned repo.
#
# Expected repo convention:
#   salt/<repo_name>/dependencies.sls
# or:
#   salt/<repo_name>/dependencies/init.sls
#
# Optional explicit metadata file inside repo:
#   .salt-bootstrap-state
# containing for example:
#   salt_vps1.dependencies
#
# Typical use:
#   mkdir -p /srv/salt-vps1
#   cd /srv/salt-vps1
#   bash /tmp/salt-machine-bootstrap.sh
#
# Non-interactive use:
#   REPO_URL=https://github.com/you/salt-vps1.git \
#   INSTALL_STATE=salt_vps1.dependencies \
#   bash /tmp/salt-machine-bootstrap.sh
# -----------------------------------------------------------------------------

# -----------------------------
# Configurable defaults
# -----------------------------

SALT_BOOTSTRAP_VERSION="${SALT_BOOTSTRAP_VERSION:-v2026.05.20}"
SALT_BOOTSTRAP_SHA256="${SALT_BOOTSTRAP_SHA256:-4d0b2bd70c4a8e33d58f7caf2148bde736949b515a707a7a13a7b173aa035dd5}"
SALT_BOOTSTRAP_URL="${SALT_BOOTSTRAP_URL:-https://github.com/saltstack/salt-bootstrap/releases/download/${SALT_BOOTSTRAP_VERSION}/bootstrap-salt.sh}"

# -X = do not start daemons after installation.
# -P = allow pip fallback when packages are unavailable.
# stable = install stable Salt.
SALT_BOOTSTRAP_ARGS="${SALT_BOOTSTRAP_ARGS:--X -P stable}"

# Ask for target directory in interactive mode unless TARGET_DIR is set.
TARGET_DIR="${TARGET_DIR:-}"

# auto       -> resolve automatically from repo convention / metadata / prompt
# none|skip  -> skip dependency state
# anything else -> exact state name, e.g. salt_vps1.dependencies
INSTALL_STATE="${INSTALL_STATE:-auto}"
BOOTSTRAP_STATE_FILE="${BOOTSTRAP_STATE_FILE:-.salt-bootstrap-state}"

SALT_ID="${SALT_ID:-$(hostname -f 2>/dev/null || hostname)}"

# Default pillar root inside the cloned repo.
PILLAR_ROOT="${PILLAR_ROOT:-}"

# Extra roots are colon-separated.
# Example:
#   EXTRA_FILE_ROOTS=/srv/salt-lib:/srv/salt-formula
EXTRA_FILE_ROOTS="${EXTRA_FILE_ROOTS:-}"
EXTRA_PILLAR_ROOTS="${EXTRA_PILLAR_ROOTS:-}"

# Sync custom _states, _modules, etc. before applying the dependency state.
SYNC_SALT_EXTENSIONS="${SYNC_SALT_EXTENSIONS:-1}"

# Convert submodule HTTPS URLs from the same host to SSH using local git config.
CONVERT_SUBMODULE_HTTPS_TO_SSH="${CONVERT_SUBMODULE_HTTPS_TO_SSH:-1}"

CURRENT_USER="$(id -un)"
DEFAULT_HOME="${HOME:-$(eval echo "~$CURRENT_USER")}"

SSH_KEY="${SSH_KEY:-$DEFAULT_HOME/.ssh/id_ed25519}"
SSH_KEY_COMMENT="${SSH_KEY_COMMENT:-${CURRENT_USER}@$(hostname)-salt-bootstrap}"

REPO_URL="${REPO_URL:-}"

RUNTIME_DIR=""

# -----------------------------
# Logging and command helpers
# -----------------------------

log() {
  printf '[bootstrap] %s\n' "$*" >&2
}

fail() {
  printf '[bootstrap] ERROR: %s\n' "$*" >&2
  exit 1
}

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    command -v sudo >/dev/null 2>&1 || fail "sudo is required when not running as root"
    sudo "$@"
  fi
}

trim_text() {
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

prompt_tty() {
  local __var_name="$1"
  local prompt_text="$2"
  local value=""

  if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
    fail "No interactive TTY available. Pass the required value through an environment variable."
  fi

  while [ -z "$value" ]; do
    printf '%s' "$prompt_text" > /dev/tty
    IFS= read -r value < /dev/tty
    value="$(printf '%s' "$value" | trim_text)"
  done

  printf -v "$__var_name" '%s' "$value"
}

# -----------------------------
# Download and checksum helpers
# -----------------------------

download_file() {
  local url="$1"
  local out="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --proto '=https' --tlsv1.2 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$url" "$out" <<'PY'
import sys
import urllib.request

url, out = sys.argv[1], sys.argv[2]
with urllib.request.urlopen(url) as response:
    data = response.read()
with open(out, "wb") as f:
    f.write(data)
PY
  else
    fail "Need curl, wget, or python3 to download files"
  fi
}

sha256_file() {
  local file="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file" | awk '{print $2}'
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$file" <<'PY'
import hashlib
import sys

path = sys.argv[1]
h = hashlib.sha256()
with open(path, "rb") as f:
    for chunk in iter(lambda: f.read(1024 * 1024), b""):
        h.update(chunk)
print(h.hexdigest())
PY
  else
    fail "Need sha256sum, shasum, openssl, or python3 to verify SHA256"
  fi
}

# -----------------------------
# Salt installation
# -----------------------------

find_salt_call() {
  local path

  if path="$(command -v salt-call 2>/dev/null)"; then
    printf '%s\n' "$path"
    return 0
  fi

  for path in \
    /usr/bin/salt-call \
    /usr/local/bin/salt-call \
    /opt/saltstack/salt/bin/salt-call
  do
    if [ -x "$path" ]; then
      printf '%s\n' "$path"
      return 0
    fi
  done

  return 1
}

install_salt() {
  if find_salt_call >/dev/null 2>&1; then
    log "salt-call is already installed"
    return
  fi

  local tmpdir script actual expected
  tmpdir="$(mktemp -d)"
  script="$tmpdir/bootstrap-salt.sh"

  log "Downloading Salt bootstrap: $SALT_BOOTSTRAP_URL"
  download_file "$SALT_BOOTSTRAP_URL" "$script"

  actual="$(sha256_file "$script" | tr '[:upper:]' '[:lower:]')"
  expected="$(printf '%s' "$SALT_BOOTSTRAP_SHA256" | tr '[:upper:]' '[:lower:]')"

  if [ "$actual" != "$expected" ]; then
    fail "Salt bootstrap checksum mismatch. Expected $expected, got $actual"
  fi

  log "Salt bootstrap checksum is valid"

  chmod 700 "$script"

  # Split SALT_BOOTSTRAP_ARGS intentionally. This variable is meant to contain shell-like words.
  # shellcheck disable=SC2206
  local args=( $SALT_BOOTSTRAP_ARGS )

  log "Installing Salt with args: ${args[*]}"
  run_root sh "$script" "${args[@]}"

  rm -rf "$tmpdir"

  hash -r || true
  find_salt_call >/dev/null 2>&1 || fail "Salt installation finished, but salt-call was not found"
}

# -----------------------------
# Git and SSH setup
# -----------------------------

install_git() {
  if command -v git >/dev/null 2>&1; then
    log "git is already installed"
    return
  fi

  local salt_call
  salt_call="$(find_salt_call)" || fail "salt-call is required to install git"

  log "Installing git through Salt pkg.installed"
  run_root "$salt_call" --local --retcode-passthrough \
    state.single pkg.installed name=git refresh=True

  hash -r || true
  command -v git >/dev/null 2>&1 || fail "git installation finished, but git was not found"
}

ensure_ssh_keygen() {
  if command -v ssh-keygen >/dev/null 2>&1; then
    return
  fi

  local salt_call pkg
  salt_call="$(find_salt_call)" || fail "salt-call is required to install ssh-keygen"

  log "ssh-keygen is missing; trying common OpenSSH client package names"

  for pkg in openssh-client openssh-clients openssh; do
    if run_root "$salt_call" --local --retcode-passthrough \
      state.single pkg.installed name="$pkg" refresh=True
    then
      hash -r || true
      if command -v ssh-keygen >/dev/null 2>&1; then
        return
      fi
    fi
  done

  fail "Could not install ssh-keygen automatically"
}

ensure_ssh_key() {
  ensure_ssh_keygen

  mkdir -p "$(dirname "$SSH_KEY")"
  chmod 700 "$(dirname "$SSH_KEY")"

  if [ ! -f "$SSH_KEY" ]; then
    log "Generating SSH key: $SSH_KEY"
    ssh-keygen -t ed25519 -C "$SSH_KEY_COMMENT" -f "$SSH_KEY" -N ""
  fi

  if [ ! -f "$SSH_KEY.pub" ]; then
    log "Regenerating public key from private key"
    ssh-keygen -y -f "$SSH_KEY" > "$SSH_KEY.pub"
  fi

  chmod 600 "$SSH_KEY" || true
  chmod 644 "$SSH_KEY.pub" || true
}

setup_git_ssh_wrapper() {
  [ -n "$RUNTIME_DIR" ] || fail "RUNTIME_DIR is not initialized"

  local wrapper="$RUNTIME_DIR/git-ssh"

  cat > "$wrapper" <<EOF
#!/usr/bin/env sh
exec ssh -i "${SSH_KEY}" -o IdentitiesOnly=yes "\$@"
EOF

  chmod 700 "$wrapper"
  export GIT_SSH="$wrapper"
}

show_pubkey_and_get_repo_url() {
  ensure_ssh_key
  setup_git_ssh_wrapper

  if [ -n "$REPO_URL" ]; then
    log "Using REPO_URL from environment"
    return
  fi

  {
    printf '\n'
    printf 'Add this SSH public key to GitHub/GitLab/etc. as a deploy key or user key:\n'
    printf '\n'
    cat "$SSH_KEY.pub"
    printf '\n\n'
    printf 'After granting repository access, paste the repository URL.\n'
    printf 'HTTPS URLs like https://github.com/user/repo.git will be converted to SSH style.\n'
    printf '\n'
  } > /dev/tty

  prompt_tty REPO_URL "Repository URL: "
}

default_target_dir_from_repo_url() {
  local url name

  url="$(printf '%s' "$REPO_URL" | trim_text)"
  url="${url%%\?*}"
  url="${url%%#*}"
  url="${url%/}"
  url="${url%.git}"

  name="${url##*/}"
  name="${name##*:}"

  [ -n "$name" ] || name="repo"

  printf '%s/%s\n' "$PWD" "$name"
}

prompt_target_dir() {
  local default_dir value

  if [ -n "$TARGET_DIR" ]; then
    return
  fi

  if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
    TARGET_DIR="$PWD"
    return
  fi

  default_dir="$(default_target_dir_from_repo_url)"

  printf 'Target directory [%s]: ' "$default_dir" > /dev/tty
  IFS= read -r value < /dev/tty
  value="$(printf '%s' "$value" | trim_text)"

  TARGET_DIR="${value:-$default_dir}"
}

# -----------------------------
# Git URL conversion and cloning
# -----------------------------

to_ssh_url() {
  local url="$1"
  local host path

  url="$(printf '%s' "$url" | trim_text)"

  if [[ "$url" =~ ^https?://([^/]+)/(.+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    path="${BASH_REMATCH[2]}"

    # Drop possible username from https://user@host/org/repo form.
    host="${host#*@}"

    # Remove query, fragment, and trailing slash.
    path="${path%%\?*}"
    path="${path%%#*}"
    path="${path%/}"

    if [[ "$path" != *.git ]]; then
      path="${path}.git"
    fi

    # host:port needs ssh:// form. Plain host can use scp-like Git syntax.
    if [[ "$host" == *:* ]]; then
      printf 'ssh://git@%s/%s\n' "$host" "$path"
    else
      printf 'git@%s:%s\n' "$host" "$path"
    fi
  else
    printf '%s\n' "$url"
  fi
}

git_host_from_url() {
  local url="$1"
  local host

  url="$(printf '%s' "$url" | trim_text)"

  if [[ "$url" =~ ^https?://([^/]+)/ ]]; then
    host="${BASH_REMATCH[1]}"
    host="${host#*@}"
    printf '%s\n' "$host"
    return 0
  fi

  if [[ "$url" =~ ^git@([^:]+): ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  if [[ "$url" =~ ^ssh://git@([^/]+)/ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

configure_submodule_url_rewrites() {
  [ "$CONVERT_SUBMODULE_HTTPS_TO_SSH" = "1" ] || return 0

  local host
  host="$(git_host_from_url "$REPO_URL" 2>/dev/null || true)"

  [ -n "$host" ] || return 0

  # Keep it simple: for host:port, leave submodules untouched.
  if [[ "$host" == *:* ]]; then
    return 0
  fi

  log "Configuring repo-local Git rewrite: https://$host/... -> git@$host:..."
  git -C "$TARGET_DIR" config "url.git@$host:.insteadOf" "https://$host/"
}

is_empty_dir() {
  local dir="$1"
  [ -d "$dir" ] || return 1
  [ -z "$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit)" ]
}

clone_repo() {
  local ssh_url
  ssh_url="$(to_ssh_url "$REPO_URL")"

  mkdir -p "$TARGET_DIR"
  TARGET_DIR="$(cd "$TARGET_DIR" && pwd -P)"
  PILLAR_ROOT="${PILLAR_ROOT:-$TARGET_DIR/pillar}"

  log "Target directory: $TARGET_DIR"
  log "Repository URL: $ssh_url"

  if [ -d "$TARGET_DIR/.git" ]; then
    log "Target is already a Git repository; updating it"

    if git -C "$TARGET_DIR" remote get-url origin >/dev/null 2>&1; then
      git -C "$TARGET_DIR" remote set-url origin "$ssh_url"
    fi

    configure_submodule_url_rewrites
    git -C "$TARGET_DIR" pull --ff-only
    git -C "$TARGET_DIR" submodule sync --recursive
    git -C "$TARGET_DIR" submodule update --init --recursive
    return
  fi

  if ! is_empty_dir "$TARGET_DIR"; then
    fail "Target directory is not empty and is not a Git repository: $TARGET_DIR"
  fi

  log "Cloning repository"
  git clone "$ssh_url" "$TARGET_DIR"

  configure_submodule_url_rewrites

  log "Initializing submodules"
  git -C "$TARGET_DIR" submodule sync --recursive
  git -C "$TARGET_DIR" submodule update --init --recursive
}

# -----------------------------
# Salt root discovery
# -----------------------------

FILE_ROOTS=()
PILLAR_ROOTS=()
FILE_ROOT_ARGS=()
PILLAR_ROOT_ARGS=()

_SEEN_FILE_ROOTS=""
_SEEN_PILLAR_ROOTS=""

add_file_root() {
  local dir="$1"

  [ -d "$dir" ] || return 0
  dir="$(cd "$dir" && pwd -P)"

  case ":$_SEEN_FILE_ROOTS:" in
    *":$dir:"*) return 0 ;;
  esac

  _SEEN_FILE_ROOTS="${_SEEN_FILE_ROOTS}:$dir"
  FILE_ROOTS+=("$dir")
  FILE_ROOT_ARGS+=(--file-root "$dir")
}

add_pillar_root() {
  local dir="$1"

  [ -d "$dir" ] || return 0
  dir="$(cd "$dir" && pwd -P)"

  case ":$_SEEN_PILLAR_ROOTS:" in
    *":$dir:"*) return 0 ;;
  esac

  _SEEN_PILLAR_ROOTS="${_SEEN_PILLAR_ROOTS}:$dir"
  PILLAR_ROOTS+=("$dir")
  PILLAR_ROOT_ARGS+=(--pillar-root "$dir")
}

build_salt_roots() {
  local path extra empty_pillar

  # Prefer the conventional layout:
  #   repo/salt/<state>.sls
  # Fall back to repo root if repo/salt does not exist.
  if [ -d "$TARGET_DIR/salt" ]; then
    add_file_root "$TARGET_DIR/salt"
  else
    add_file_root "$TARGET_DIR"
  fi

  # Add every submodule path as a file root.
  # This makes vendored salt-formula / bootstrap-lib states visible.
  if [ -f "$TARGET_DIR/.gitmodules" ]; then
    while IFS= read -r path; do
      add_file_root "$TARGET_DIR/$path"
    done < <(
      git -C "$TARGET_DIR" config --file .gitmodules \
        --get-regexp 'submodule\..*\.path' 2>/dev/null \
        | awk '{print $2}'
    )
  fi

  if [ -n "$EXTRA_FILE_ROOTS" ]; then
    IFS=':' read -r -a extra_file_roots <<< "$EXTRA_FILE_ROOTS"
    for extra in "${extra_file_roots[@]}"; do
      add_file_root "$extra"
    done
  fi

  if [ -d "$PILLAR_ROOT" ]; then
    add_pillar_root "$PILLAR_ROOT"
  else
    # Passing an explicit empty pillar root prevents accidental use of /srv/pillar.
    empty_pillar="$RUNTIME_DIR/empty-pillar"
    mkdir -p "$empty_pillar"
    add_pillar_root "$empty_pillar"
  fi

  if [ -n "$EXTRA_PILLAR_ROOTS" ]; then
    IFS=':' read -r -a extra_pillar_roots <<< "$EXTRA_PILLAR_ROOTS"
    for extra in "${extra_pillar_roots[@]}"; do
      add_pillar_root "$extra"
    done
  fi

  if [ "${#FILE_ROOTS[@]}" -eq 0 ]; then
    fail "No Salt file roots found"
  fi
}

# -----------------------------
# Dependency state resolver
# -----------------------------

normalize_state_name() {
  local state="$1"

  state="$(printf '%s' "$state" | trim_text)"

  # Accept user input like:
  #   salt://foo/bar.sls
  #   foo/bar.sls
  #   foo/bar/init.sls
  #   foo.bar
  state="${state#salt://}"
  state="${state%.sls}"
  state="${state%/init}"
  state="${state//\//.}"

  # Remove accidental leading/trailing dots.
  state="${state#.}"
  state="${state%.}"

  printf '%s\n' "$state"
}

state_to_relpath() {
  local state="$1"
  printf '%s\n' "${state//./\/}"
}

state_exists() {
  local state="$1"
  local rel root

  state="$(normalize_state_name "$state")"
  [ -n "$state" ] || return 1

  rel="$(state_to_relpath "$state")"

  for root in "${FILE_ROOTS[@]}"; do
    if [ -f "$root/$rel.sls" ]; then
      return 0
    fi

    if [ -f "$root/$rel/init.sls" ]; then
      return 0
    fi
  done

  return 1
}

show_state_search_paths() {
  local state="$1"
  local rel root

  state="$(normalize_state_name "$state")"
  rel="$(state_to_relpath "$state")"

  for root in "${FILE_ROOTS[@]}"; do
    printf '  %s\n' "$root/$rel.sls" >&2
    printf '  %s\n' "$root/$rel/init.sls" >&2
  done
}

repo_name_from_origin() {
  local url name

  url="$(git -C "$TARGET_DIR" remote get-url origin 2>/dev/null || true)"

  if [ -z "$url" ]; then
    name="$(basename "$TARGET_DIR")"
  else
    url="${url%/}"
    url="${url%.git}"
    url="${url%%\?*}"
    url="${url%%#*}"
    name="${url##*/}"
    name="${name##*:}"
  fi

  printf '%s\n' "$name"
}

safe_state_namespace_from_repo() {
  local name="$1"

  # Dots are awkward in Salt state-tree names because dots separate path components.
  # Keep hyphens, but also test an underscore variant separately.
  printf '%s\n' "$name" \
    | sed \
      -e 's/[.]/_/g' \
      -e 's/[^A-Za-z0-9_-]/_/g'
}

read_bootstrap_state_file() {
  local file="$TARGET_DIR/$BOOTSTRAP_STATE_FILE"

  [ -f "$file" ] || return 1

  # First non-empty, non-comment line.
  grep -v '^[[:space:]]*$' "$file" \
    | grep -v '^[[:space:]]*#' \
    | head -n 1 \
    | trim_text
}

try_state() {
  local state="$1"

  state="$(normalize_state_name "$state")"

  if state_exists "$state"; then
    printf '%s\n' "$state"
    return 0
  fi

  return 1
}

resolve_state_from_prompt() {
  local input="$1"
  local state

  state="$(normalize_state_name "$input")"
  [ -n "$state" ] || return 1

  # If user already entered something ending with .dependencies, treat it as exact.
  if [[ "$state" == *.dependencies ]]; then
    try_state "$state" && return 0
    return 1
  fi

  # User-requested behavior:
  #   prompt "foo" -> first try foo.dependencies, then foo itself.
  try_state "$state.dependencies" && return 0
  try_state "$state" && return 0

  return 1
}

resolve_install_state() {
  local explicit declared repo safe_repo underscore_repo candidate resolved input

  case "$INSTALL_STATE" in
    none|skip|false|0)
      printf '%s\n' ""
      return 0
      ;;
  esac

  # 1. Environment override.
  if [ -n "${INSTALL_STATE:-}" ] && [ "$INSTALL_STATE" != "auto" ]; then
    explicit="$(normalize_state_name "$INSTALL_STATE")"

    if state_exists "$explicit"; then
      printf '%s\n' "$explicit"
      return 0
    fi

    printf 'INSTALL_STATE was set to "%s", but the state was not found.\n' "$explicit" >&2
    printf 'Searched:\n' >&2
    show_state_search_paths "$explicit"
    fail "Explicit INSTALL_STATE does not exist"
  fi

  # 2. Repo metadata file.
  if declared="$(read_bootstrap_state_file)"; then
    declared="$(normalize_state_name "$declared")"

    if state_exists "$declared"; then
      printf '%s\n' "$declared"
      return 0
    fi

    printf '%s contains "%s", but the state was not found.\n' \
      "$BOOTSTRAP_STATE_FILE" "$declared" >&2
    printf 'Searched:\n' >&2
    show_state_search_paths "$declared"
    fail "Bootstrap state declared by repo does not exist"
  fi

  # 3. Convention: <git_repo_name>.dependencies.
  repo="$(repo_name_from_origin)"
  safe_repo="$(safe_state_namespace_from_repo "$repo")"
  underscore_repo="${safe_repo//-/_}"

  for candidate in \
    "$repo.dependencies" \
    "$safe_repo.dependencies" \
    "$underscore_repo.dependencies"
  do
    if resolved="$(try_state "$candidate")"; then
      printf '%s\n' "$resolved"
      return 0
    fi
  done

  # 4. Interactive fallback.
  if [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
    fail "Could not auto-detect dependency state and no TTY is available. Set INSTALL_STATE."
  fi

  {
    printf '\n'
    printf 'Could not auto-detect dependency state.\n'
    printf 'Expected one of these by convention:\n'
    printf '  %s.dependencies\n' "$repo"
    printf '  %s.dependencies\n' "$safe_repo"
    printf '  %s.dependencies\n' "$underscore_repo"
    printf '\n'
    printf 'You can enter either a namespace, like:\n'
    printf '  salt_vps1\n'
    printf 'or an exact state, like:\n'
    printf '  salt_vps1.dependencies\n'
    printf '  bootstrap.install\n'
    printf '\n'
  } > /dev/tty

  while true; do
    printf 'Dependency state or namespace: ' > /dev/tty
    IFS= read -r input < /dev/tty

    if resolved="$(resolve_state_from_prompt "$input")"; then
      printf '%s\n' "$resolved"
      return 0
    fi

    input="$(normalize_state_name "$input")"

    {
      printf 'State not found for "%s". Searched:\n' "$input"
      show_state_search_paths "$input.dependencies"
      show_state_search_paths "$input"
      printf '\n'
    } > /dev/tty
  done
}

# -----------------------------
# Run repo dependency state
# -----------------------------

run_repo_dependencies() {
  local salt_call resolved_install_state

  salt_call="$(find_salt_call)" || fail "salt-call is required to run dependency state"

  build_salt_roots

  log "Salt file roots:"
  for root in "${FILE_ROOTS[@]}"; do
    printf '  %s\n' "$root" >&2
  done

  log "Salt pillar roots:"
  for root in "${PILLAR_ROOTS[@]}"; do
    printf '  %s\n' "$root" >&2
  done

  resolved_install_state="$(resolve_install_state)"

  if [ -z "$resolved_install_state" ]; then
    log "Dependency state is disabled; skipping"
    return
  fi

  log "Resolved dependency state: $resolved_install_state"

  if [ "$SYNC_SALT_EXTENSIONS" = "1" ]; then
    log "Syncing Salt extension modules from file roots"
    run_root "$salt_call" --local --retcode-passthrough --id "$SALT_ID" \
      "${FILE_ROOT_ARGS[@]}" \
      "${PILLAR_ROOT_ARGS[@]}" \
      saltutil.sync_all
  fi

  log "Applying dependency state: $resolved_install_state"
  run_root "$salt_call" --local --retcode-passthrough --id "$SALT_ID" \
    "${FILE_ROOT_ARGS[@]}" \
    "${PILLAR_ROOT_ARGS[@]}" \
    state.apply "$resolved_install_state"
}

# -----------------------------
# Main
# -----------------------------

main() {
  RUNTIME_DIR="$(mktemp -d)"
  trap 'rm -rf "$RUNTIME_DIR"' EXIT

  if [ "$(id -u)" -eq 0 ]; then
    log "Running as root. SSH key and cloned repo will belong to root."
    log "For a normal admin-user-owned repo, run this script as that user and let it use sudo only when needed."
  fi

  install_salt
  install_git
  show_pubkey_and_get_repo_url
  prompt_target_dir
  clone_repo
  run_repo_dependencies

  log "Done"
  log "Next usual step: salt-call --local --retcode-passthrough state.apply"
}

main "$@"
