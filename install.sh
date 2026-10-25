#!/bin/bash
# Maestro — Setup
#
# Two jobs, with two names:
#   - Install: the tools (gh, uv, and optionally gitleaks and swiftlint) and Maestro itself
#     (~/.maestro, slash commands, subagent, SessionStart hook, shared rules in ~/.claude/CLAUDE.md).
#   - Link: connect Maestro with one iOS project repo (Jira account, GitHub or Bitbucket repo,
#     Claude login). The installer checks a project before it saves anything for it.
#
# After each successful install or link, the installer asks "Link Maestro with another project?".
# A failed install or link stops the installer.
#
# Tokens go only to the macOS login Keychain. ~/.maestro/.env holds non-secret settings.
set -e

MAESTRO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # shared code (agents, commands, hook) — read-only
# Per-account state lives under the current Mac account's $HOME, never inside the shared repo.
# This keeps credentials and config isolated per account.
MAESTRO_STATE="$HOME/.maestro"
LAUNCHER="$MAESTRO_STATE/bin/mcp-with-secrets.sh"
# Migrate older installs that symlinked ~/.maestro → the repo: replace the symlink with a real dir.
[ -L "$MAESTRO_STATE" ] && rm -f "${MAESTRO_STATE:?}"

GREEN='\033[0;32m'; NC='\033[0m'
ok()        { printf "${GREEN}✓${NC} %s\n" "$1"; }
warn()      { printf "⚠️ %s\n" "$1"; }
ask()       { read -rp  "$1" "$2"; }
askp()      { read -rsp "$1" "$2"; echo; }
slugify()   { echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]-'; }
envkey()    { echo "$1" | tr '[:lower:]' '[:upper:]' | tr '-' '_'; }
capitalize(){ first=$(echo "${1:0:1}" | tr '[:lower:]' '[:upper:]'); echo "${first}${1:1}"; }

derive_jira_nick() {
  local url="$1"
  local host
  host="${url#*://}"
  host="${host%%/*}"
  host="${host#www.}"
  host="${host//./-}"
  host="$(slugify "$host")"
  if [ -z "$host" ]; then
    host="jira"
  fi
  echo "$host"
}

# Asks until the answer is not blank. Pass "secret" as $3 to hide the input.
ask_value() {
  while true; do
    if [ "${3:-}" = "secret" ]; then askp "$1" "$2"; else ask "$1" "$2"; fi
    [ -n "${!2}" ] && return 0
    echo "  This value cannot be blank."
  done
}

# Asks until the answer is a number from 1 to $2, then stores it in the variable named $3.
choose() {
  local reply
  while true; do
    ask "$1" reply
    if [[ "$reply" =~ ^[0-9]+$ ]] && [ "$reply" -ge 1 ] && [ "$reply" -le "$2" ]; then
      printf -v "$3" '%s' "$reply"
      return 0
    fi
    echo "  Enter a number from 1 to $2."
  done
}

# Secrets live in the macOS login Keychain, never in plaintext on disk. keychain_set upserts a
# generic password under a service name; keychain_get reads it back. A blank secret is a no-op.
keychain_set() { [ -n "${2:-}" ] && security add-generic-password -s "$1" -a "maestro" -w "$2" -U >/dev/null 2>&1 || true; }
keychain_get() { security find-generic-password -s "$1" -a "maestro" -w 2>/dev/null || true; }

# Ignores $2 in repo $1 via .git/info/exclude — NEVER the tracked .gitignore. That file is
# committed and can differ between branches; editing it leaves an uncommitted local change that
# later blocks `git checkout <other-branch>`. info/exclude is local-only, per-repo, and never
# diffs or conflicts with a branch switch.
git_exclude_add() {
  local path="$1" pattern="$2"
  [ -d "$path/.git" ] || return 0
  local exclude_file="$path/.git/info/exclude"
  mkdir -p "$(dirname "$exclude_file")"
  touch "$exclude_file"
  grep -qxF "$pattern" "$exclude_file" 2>/dev/null || printf '%s\n' "$pattern" >> "$exclude_file"
}

valid_url() {
  [[ "$1" =~ ^https?://[^[:space:]]+$ ]]
}

valid_email() {
  [[ "$1" =~ ^[^[:space:]]+@[^[:space:]]+\.[^[:space:]]+$ ]]
}

expand_path() {
  local p="${1#[\'\"]}"
  p="${p%[\'\"]}"
  printf '%s\n' "${p/#\~/$HOME}"
}

parse_github_url() {
  local url="$1"
  if [[ "$url" =~ ^https://github\.com/([^/]+)/([^/]+)(\.git)?/?$ ]]; then
    GH_OWNER="${BASH_REMATCH[1]}"
    GH_REPO="${BASH_REMATCH[2]%.git}"
    return 0
  elif [[ "$url" =~ ^git@github\.com:([^/]+)/([^/]+)(\.git)?$ ]]; then
    GH_OWNER="${BASH_REMATCH[1]}"
    GH_REPO="${BASH_REMATCH[2]%.git}"
    return 0
  elif [[ "$url" =~ ^([^/]+)/([^/]+)$ ]]; then
    GH_OWNER="${BASH_REMATCH[1]}"
    GH_REPO="${BASH_REMATCH[2]%.git}"
    return 0
  fi
  return 1
}

parse_bitbucket_url() {
  local url="$1"
  if [[ "$url" =~ ^https://bitbucket\.org/([^/]+)/([^/]+)(\.git)?/?$ ]]; then
    BB_WORKSPACE="${BASH_REMATCH[1]}"
    BB_REPO="${BASH_REMATCH[2]%.git}"
    return 0
  elif [[ "$url" =~ ^git@bitbucket\.org:([^/]+)/([^/]+)(\.git)?$ ]]; then
    BB_WORKSPACE="${BASH_REMATCH[1]}"
    BB_REPO="${BASH_REMATCH[2]%.git}"
    return 0
  elif [[ "$url" =~ ^([^/]+)/([^/]+)$ ]]; then
    BB_WORKSPACE="${BASH_REMATCH[1]}"
    BB_REPO="${BASH_REMATCH[2]%.git}"
    return 0
  fi
  return 1
}

# Sets JIRA_NICKS from the Jira accounts in ~/.maestro/.env.
load_jira_nicks() {
  JIRA_NICKS=()
  [ -f "$MAESTRO_STATE/.env" ] || return 0
  local line
  while IFS= read -r line; do
    if [[ "$line" =~ ^JIRA_URL_([A-Z0-9_]+)= ]]; then
      JIRA_NICKS+=("$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]' | tr '_' '-')")
    fi
  done < "$MAESTRO_STATE/.env"
}

nick_is_known() {
  local n
  for n in "${JIRA_NICKS[@]}"; do
    [ "$n" = "$1" ] && return 0
  done
  return 1
}

get_jira_credentials() {
  local key
  key=$(envkey "$1")
  JIRA_URL=$(grep "^JIRA_URL_${key}=" "$MAESTRO_STATE/.env" 2>/dev/null | cut -d'=' -f2-)
  JIRA_USER=$(grep "^JIRA_USERNAME_${key}=" "$MAESTRO_STATE/.env" 2>/dev/null | cut -d'=' -f2-)
  JIRA_TOKEN=$(keychain_get "maestro-jira-${key}")
}

# Writes the project's .mcp.json with one MCP server: the Jira server for the project's own Jira
# account. Claude Code loads a project-root .mcp.json by itself, and each project sees only its
# own credentials. The token is not in the file: the launcher reads it from the Keychain when the
# server starts. Servers that Maestro did not write stay in the file. Old Maestro servers (GitHub,
# git, other Jira accounts) go away. The file is ignored through .git/info/exclude, because it
# holds this Mac account's absolute launcher path.
generate_project_mcp_json() {
  local path="$1" nick="$2" nick_key jira_url jira_user
  nick_key=$(envkey "$nick")
  jira_url=$(grep "^JIRA_URL_${nick_key}=" "$MAESTRO_STATE/.env" 2>/dev/null | cut -d'=' -f2-)
  jira_user=$(grep "^JIRA_USERNAME_${nick_key}=" "$MAESTRO_STATE/.env" 2>/dev/null | cut -d'=' -f2-)
  python3 - "$path/.mcp.json" "$LAUNCHER" "$nick" "$nick_key" "$jira_url" "$jira_user" << 'PYEOF'
import json, sys

out_path, launcher, nick, nick_key, jira_url, jira_user = sys.argv[1:7]

try:
    with open(out_path) as f:
        old = json.load(f).get('mcpServers') or {}
except (OSError, ValueError, AttributeError):
    old = {}
if not isinstance(old, dict):
    old = {}

servers = {}
for name, spec in old.items():
    text = json.dumps(spec)
    if name.startswith('atlassian-'):
        continue
    if name == 'github' and ('mcp-with-secrets.sh' in text or 'server-github' in text):
        continue
    if name == 'git' and 'mcp-server-git' in text:
        continue
    servers[name] = spec

servers['atlassian-' + nick] = {
    'command': launcher,
    'args': [
        'JIRA_API_TOKEN=maestro-jira-' + nick_key,
        '--',
        'uvx', '--with', 'mcp-atlassian', 'mcp-atlassian'
    ],
    'env': {
        'JIRA_URL':      jira_url,
        'JIRA_USERNAME': jira_user
    }
}

with open(out_path, 'w') as f:
    json.dump({'mcpServers': servers}, f, indent=2)
    f.write('\n')
PYEOF
  chmod 600 "$path/.mcp.json" 2>/dev/null || true
  git_exclude_add "$path" ".mcp.json"
}

validate_jira_connection() {
  local jira_url="$1"
  local jira_user="$2"
  local jira_token="$3"
  if [ -z "$jira_url" ] || [ -z "$jira_user" ] || [ -z "$jira_token" ]; then
    warn "Jira credentials missing"
    return 1
  fi
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -u "$jira_user:$jira_token" -H "Accept: application/json" "$jira_url/rest/api/3/myself")
  if [ "$http_code" = "200" ]; then
    ok "Jira login"
    return 0
  fi
  warn "Jira login failed (HTTP $http_code)"
  return 1
}

validate_jira_project() {
  local jira_url="$1"
  local jira_user="$2"
  local jira_token="$3"
  local project_key="$4"
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -u "$jira_user:$jira_token" -H "Accept: application/json" "$jira_url/rest/api/3/project/$project_key")
  if [ "$http_code" = "200" ]; then
    ok "Jira project '$project_key'"
    return 0
  fi
  warn "Jira project '$project_key' not found or not allowed (HTTP $http_code)"
  return 1
}

validate_github_connection() {
  local owner="$1"
  local repo="$2"
  local token="$3"
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $token" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$owner/$repo")
  if [ "$http_code" = "200" ]; then
    ok "GitHub repo access"
    return 0
  fi
  warn "GitHub repo access failed for $owner/$repo (HTTP $http_code)"
  return 1
}

validate_bitbucket_connection() {
  local workspace="$1"
  local repo="$2"
  local user="$3"
  local token="$4"
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -u "$user:$token" \
    "https://api.bitbucket.org/2.0/repositories/$workspace/$repo")
  if [ "$http_code" = "200" ]; then
    ok "Bitbucket repo access"
    return 0
  fi
  warn "Bitbucket repo access failed for $workspace/$repo (HTTP $http_code)"
  return 1
}

# Validate an Anthropic API key by making one minimal Messages API call. Distinguishes a working
# key, a key whose account is out of credits, and an invalid key — so low balance is surfaced at
# link time instead of on the first real ticket. Non-blocking: the key is still stored.
# Cheapest current model; the check only needs a 1-token reply. Update when a newer Haiku ships.
ANTHROPIC_CHECK_MODEL="claude-haiku-5-5"

validate_anthropic_key() {
  local key="$1" label="$2"
  [ -z "$key" ] && return 0
  local resp http_code body
  resp=$(curl -s -w $'\n%{http_code}' https://api.anthropic.com/v1/messages \
    -H "x-api-key: $key" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d '{"model":"'"$ANTHROPIC_CHECK_MODEL"'","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' 2>/dev/null)
  http_code=$(printf '%s' "$resp" | tail -n1)
  body=$(printf '%s' "$resp" | sed '$d')
  case "$http_code" in
    200|429)
      ok "Anthropic key for '$label' (account has credits)"
      return 0 ;;
    400)
      if printf '%s' "$body" | grep -qi "credit balance is too low"; then
        warn "Anthropic key for '$label': credit balance is too low — top up at console.anthropic.com → Billing before running this project."
      else
        warn "Anthropic key for '$label': request rejected — $(printf '%s' "$body" | grep -oE '"message":"[^"]*"' | head -1)"
      fi
      return 1 ;;
    401|403)
      warn "Anthropic key for '$label': invalid or unauthorized key (HTTP $http_code)."
      return 1 ;;
    *)
      warn "Anthropic key for '$label': could not verify (HTTP ${http_code:-no response})."
      return 1 ;;
  esac
}

# Read-only: never fetches, never switches the branch, never touches the remote URL.
check_repo() {
  local path="$1" base="$2"
  if ! git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    warn "$path is not a git repository"
    return 1
  fi
  if git -C "$path" rev-parse --verify --quiet "refs/heads/$base" >/dev/null || \
     git -C "$path" rev-parse --verify --quiet "refs/remotes/origin/$base" >/dev/null; then
    ok "Local repo and base branch '$base'"
    return 0
  fi
  warn "Base branch '$base' not found in $path. Run 'git fetch' there, or check the branch name."
  return 1
}

# Prints the project folder of a VS Code workspace file (the folder that is not Maestro).
workspace_project_path() {
  python3 - "$1" "$MAESTRO_DIR" << 'PYEOF'
import json, os, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except (OSError, ValueError):
    sys.exit(0)
maestro = os.path.realpath(sys.argv[2])
for folder in data.get('folders') or []:
    p = folder.get('path') if isinstance(folder, dict) else None
    if isinstance(p, str) and p and os.path.realpath(os.path.expanduser(p)) != maestro:
        print(p)
        break
PYEOF
}

# Prints the names of the MCP servers that older Maestro versions registered at user scope.
old_user_mcp_names() {
  python3 - "$1" << 'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except (OSError, ValueError):
    sys.exit(0)
servers = data.get('mcpServers') if isinstance(data, dict) else None
for name, spec in (servers or {}).items():
    if not isinstance(spec, dict):
        continue
    text = ' '.join([str(spec.get('command', ''))] + [str(a) for a in spec.get('args') or []])
    launcher = 'mcp-with-secrets.sh' in text
    if (name.startswith('atlassian-') and (launcher or 'mcp-atlassian' in text)) \
            or (name == 'github' and (launcher or 'server-github' in text)) \
            or (name == 'git' and 'mcp-server-git' in text):
        print(name)
PYEOF
}

# Older versions registered the Jira, GitHub and git MCP servers for every repo (user scope) and
# wrote ~/.maestro/.mcp.json. Maestro now uses only the .mcp.json of each linked project.
remove_old_mcp_setup() {
  rm -f "${MAESTRO_STATE:?}/.mcp.json"
  [ -f "$HOME/.claude.json" ] || return 0
  local names name
  names="$(old_user_mcp_names "$HOME/.claude.json")"
  [ -n "$names" ] || return 0
  if ! command -v claude >/dev/null 2>&1; then
    warn "Old Maestro MCP servers are still in your Claude Code user settings: $(echo $names)"
    warn "Remove each one with: claude mcp remove <name> -s user"
    return 0
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if claude mcp remove "$name" -s user >/dev/null 2>&1; then
      ok "Removed the old MCP server '$name' from your Claude Code user settings"
    else
      warn "Could not remove the old MCP server '$name'. Run: claude mcp remove $name -s user"
    fi
  done <<< "$names"
}

# Install again keeps the linked projects. Rewrite their .mcp.json so it holds only the Jira server.
refresh_linked_projects() {
  local ws path nick
  for ws in "$MAESTRO_STATE"/workspaces/*.code-workspace; do
    [ -f "$ws" ] || continue
    path="$(workspace_project_path "$ws")"
    [ -n "$path" ] && [ -f "$path/maestro.yaml" ] && [ -f "$path/.mcp.json" ] || continue
    nick=$(sed -n 's/^[[:space:]]*mcp_server:[[:space:]]*atlassian-//p' "$path/maestro.yaml" | head -1 | tr -d "\"' \r")
    [ -n "$nick" ] || continue
    if ! grep -q "^JIRA_URL_$(envkey "$nick")=" "$MAESTRO_STATE/.env" 2>/dev/null; then
      warn "$path: Jira account '$nick' is not set up. Link this project again."
      continue
    fi
    generate_project_mcp_json "$path" "$nick"
    ok "$path/.mcp.json (Jira server only)"
  done
}

# Writes the Maestro setup into ~/.claude. Every step is idempotent.
setup_claude_files() {
  # ~/.maestro is a real per-account directory: it holds this account's state (.env, workspaces/)
  # and links to the shared, read-only code (agents, hooks, bin, .claude) in the repo. This keeps
  # every `~/.maestro/agents/…` and the hook's `~/.maestro/.claude/…` reference valid while
  # keeping credentials isolated per Mac account.
  mkdir -p "$MAESTRO_STATE"
  ln -sfn "$MAESTRO_DIR/agents"  "$MAESTRO_STATE/agents"
  ln -sfn "$MAESTRO_DIR/hooks"   "$MAESTRO_STATE/hooks"
  ln -sfn "$MAESTRO_DIR/bin"     "$MAESTRO_STATE/bin"
  ln -sfn "$MAESTRO_DIR/.claude" "$MAESTRO_STATE/.claude"
  ok "~/.maestro (settings for this Mac account, with links to $MAESTRO_DIR)"

  # Global slash commands, so /maestro and the agent commands work in any repo.
  mkdir -p "$HOME/.claude/commands"
  local cmd
  for cmd in "$MAESTRO_DIR/.claude/commands/"*.md; do
    ln -sfn "$cmd" "$HOME/.claude/commands/$(basename "$cmd")"
  done
  ok "Slash commands in ~/.claude/commands"

  # Spawnable subagents: the harness registers files in ~/.claude/agents as real subagent_types.
  # Only true delegated workers belong here — the pipeline roles stay as commands because they
  # own HITL gates. red-tdd-developer.md already carries valid YAML frontmatter.
  mkdir -p "$HOME/.claude/agents"
  ln -sfn "$MAESTRO_DIR/agents/red-tdd-developer.md" "$HOME/.claude/agents/red-tdd-developer.md"
  ok "Subagent in ~/.claude/agents (red-tdd-developer)"

  # SessionStart hook: auto-activate Maestro only in repos that contain a maestro.yaml (idempotent merge)
  python3 - "$HOME/.claude/settings.json" << 'PYEOF'
import json, os, sys
path = sys.argv[1]
os.makedirs(os.path.dirname(path), exist_ok=True)
try:
    with open(path) as f:
        settings = json.load(f)
except (FileNotFoundError, ValueError):
    settings = {}
cmd = "bash ~/.maestro/hooks/session-start.sh"
sessions = settings.setdefault("hooks", {}).setdefault("SessionStart", [])
found = any(
    h.get("command") == cmd
    for group in sessions if isinstance(group, dict)
    for h in group.get("hooks", []) if isinstance(h, dict)
)
if not found:
    sessions.append({"hooks": [{"type": "command", "command": cmd}]})
with open(path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PYEOF
  ok "SessionStart hook registered in ~/.claude/settings.json"

  # Shared agent rules: install Maestro's CLAUDE.md into ~/.claude/CLAUDE.md as a managed,
  # idempotent block. Maestro's agents reference "as defined in CLAUDE.md" (SOLID, Architecture
  # Guide, Time Gap Check, Branch Verification, pipeline order, HITL rules); those rules must be
  # loaded in every repo where an agent runs — including spawned sub-agents, which auto-load
  # ~/.claude/CLAUDE.md, not this repo's copy. ~/.claude/CLAUDE.md is per-Mac-account (under
  # $HOME), so this stays per-user exactly like the settings.json / commands install above.
  # The MAESTRO:BEGIN/END markers make a re-run refresh only Maestro's block (never the user's
  # own notes), and the precedence clause ensures any competing orchestration left in the file
  # by a previous install cannot override Maestro *within maestro.yaml repos* — CLAUDE.md is
  # global, so the clause is explicitly scoped and stays inert everywhere else. Existing files
  # are backed up once to .bak.
  python3 - "$HOME/.claude/CLAUDE.md" "$MAESTRO_DIR/CLAUDE.md" << 'PYEOF'
import os, re, sys

target, source = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(target) or ".", exist_ok=True)

if not os.path.isfile(source):
    print(f"   ⚠️  shared-rules source not found ({source}); skipping CLAUDE.md install")
    sys.exit(0)

BEGIN = "<!-- MAESTRO:BEGIN (managed — do not edit; regenerated by install.sh) -->"
END   = "<!-- MAESTRO:END -->"

with open(source, encoding="utf-8") as f:
    shared_rules = f.read().strip()

precedence = (
    "> **Maestro precedence (managed).** Maestro is the authoritative orchestrator for any "
    "repo containing a `maestro.yaml`. The rules below — together with that repo's "
    "`maestro.yaml`, the SessionStart hook, and `~/.maestro/agents/*.md` — are authoritative "
    "for pipeline order, phase detection, HITL model, branching, and JIRA columns **when working "
    "in such a repo**. Ignore any competing pipeline, flow-mode, agent-routing, or checkpoint "
    "instructions defined elsewhere in this or any other memory file, but only for repos "
    "containing a `maestro.yaml` — this clause has no effect in any other repo."
)

block = f"{BEGIN}\n\n{precedence}\n\n{shared_rules}\n\n{END}"

try:
    with open(target, encoding="utf-8") as f:
        existing = f.read()
except FileNotFoundError:
    existing = None

if existing is None:
    new, outside = block + "\n", ""
elif BEGIN in existing and END in existing:
    # Refresh the managed block in place; lambda avoids escape interpretation in the replacement.
    new = re.sub(re.escape(BEGIN) + r".*?" + re.escape(END), lambda m: block,
                 existing, count=1, flags=re.DOTALL)
    outside = existing[:existing.index(BEGIN)] + existing[existing.index(END) + len(END):]
elif BEGIN in existing or END in existing:
    # Only one marker present — the file was hand-edited into a broken state. Prepending a
    # fresh block here would leave two mismatched markers, corrupting the next regex refresh.
    print(f"   ⚠️  {target} has a corrupted MAESTRO marker (found one of BEGIN/END, not both);")
    print(f"       leaving it untouched — fix or remove the stray marker, then re-run install.sh")
    sys.exit(0)
else:
    # First time managing an existing file: back it up once, then prepend the block.
    bak = target + ".bak"
    if not os.path.exists(bak):
        with open(bak, "w", encoding="utf-8") as f:
            f.write(existing)
        print(f"   backed up existing CLAUDE.md → {bak}")
    new, outside = block + "\n\n" + existing, existing

with open(target, "w", encoding="utf-8") as f:
    f.write(new)

# Warn (never delete) if competing orchestration lives outside the managed block, so the user
# can clean it up; Maestro's precedence clause already overrides it at runtime.
signals = ["Flow Mode", "HITL Checkpoint", "Agent Routing", "Orchestrator", "Pipeline Order"]
hits = sorted({s for s in signals if s.lower() in outside.lower()})
if hits:
    print("   ⚠️  competing orchestration text found outside the managed block: " + ", ".join(hits))
    print("       Maestro's precedence clause overrides it; review ~/.claude/CLAUDE.md to remove it.")
PYEOF
  ok "shared agent rules written to ~/.claude/CLAUDE.md (managed block)"
}

install_maestro() {
  echo ""
  echo "Installing the tools and Maestro for account '$(whoami)'..."

  # Homebrew installs the other tools. Look in the usual places in case PATH misses it.
  find_brew() {
    command -v brew >/dev/null 2>&1 && return 0
    local brew_bin
    for brew_bin in /opt/homebrew/bin/brew /usr/local/bin/brew; do
      if [ -x "$brew_bin" ]; then
        export PATH="$(dirname "$brew_bin"):$PATH"
        return 0
      fi
    done
    return 1
  }
  if ! find_brew; then
    local brew_choice
    echo "Homebrew is not installed. Maestro uses it to install the other tools."
    echo "    1. Install Homebrew with its official script (https://brew.sh). It may ask for your password."
    echo "    2. Stop. Install Homebrew yourself, then run ./install.sh again."
    choose "  Choose [1/2]: " 2 brew_choice
    if [ "$brew_choice" != "1" ]; then
      warn "Homebrew is not installed. Install it from https://brew.sh, then run ./install.sh again."
      return 1
    fi
    if ! /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
      warn "The Homebrew install failed. Fix the error above, then run ./install.sh again."
      return 1
    fi
    if ! find_brew; then
      warn "Homebrew installed, but 'brew' was not found. Open a new terminal, then run ./install.sh again."
      return 1
    fi
  fi
  ok "Homebrew"

  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 is not installed. Run 'xcode-select --install', then run ./install.sh again."
    return 1
  fi

  # gh: the PR agents use it with the Maestro GitHub token. uv: uvx starts the Jira MCP server.
  local tool
  for tool in gh uv; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "Installing $tool..."
      if ! brew install "$tool"; then
        warn "Could not install $tool. Fix the Homebrew error above, then run ./install.sh again."
        return 1
      fi
    fi
    ok "$tool"
  done

  # Security tools are optional. The Architect and the Security Agent scan with them, and the
  # Developer's quick secret check uses them (see agents/security_standards.md §4). We ask and
  # never force: a tool that is skipped shows as "Not run", and the install carries on.
  echo ""
  echo "Security tools (optional):"
  local sec_tool sec_choice
  for sec_tool in gitleaks swiftlint; do
    if command -v "$sec_tool" >/dev/null 2>&1; then
      ok "$sec_tool"
      continue
    fi
    echo "  $sec_tool is not installed."
    echo "    1. Install it with Homebrew"
    echo "    2. Skip it. The security checks that use it show 'Not run'."
    choose "  Choose [1/2]: " 2 sec_choice
    if [ "$sec_choice" = "1" ] && brew install "$sec_tool"; then
      ok "$sec_tool"
    else
      warn "$sec_tool skipped. The security checks that use it show 'Not run'."
    fi
  done

  # The first run downloads the Jira MCP server, so a later session starts it fast.
  echo ""
  echo "Checking the Jira MCP server..."
  if uvx --with mcp-atlassian mcp-atlassian --help >/dev/null 2>&1; then
    ok "Jira MCP server (mcp-atlassian)"
  else
    warn "The Jira MCP server does not start. Check: uvx --with mcp-atlassian mcp-atlassian --help"
    return 1
  fi

  echo ""
  echo "Setting up Maestro..."
  setup_claude_files
  remove_old_mcp_setup
  refresh_linked_projects

  # The .env file marks Maestro as installed, so write it last.
  if [ ! -f "$MAESTRO_STATE/.env" ]; then
    {
      echo "# Maestro — written by install.sh. No secrets: tokens are in the Keychain."
      echo ""
    } > "$MAESTRO_STATE/.env"
  fi
  chmod 600 "$MAESTRO_STATE/.env"

  echo ""
  ok "Maestro is installed."
}

# Asks for one project, checks it, and saves it only when every check passes.
link_project() {
  local pick reuse i existing_gh repo_url base_nick claude_login jira_label
  while true; do   # "Enter this project again" starts here
    SLUG=""; JIRA_NICK=""; JIRA_URL=""; JIRA_USER=""; JIRA_TOKEN=""; JIRA_KEY=""; JIRA_IS_NEW=1
    REPO_PROVIDER=""; OWNER=""; REPO=""
    GH_TOKEN=""; GH_IS_NEW=0; GH_OWNER=""; GH_REPO=""
    BB_USER=""; BB_TOKEN=""; BB_WORKSPACE=""; BB_REPO=""
    REPO_PATH=""; BASE_BRANCH=""; BRANCH_PREFIX=""; ANTHROPIC_KEY=""

    echo ""
    echo "─── Link a project ───"

    # ── Jira ──────────────────────────────────────────────
    echo ""
    echo "  Jira:"
    load_jira_nicks
    if [ ${#JIRA_NICKS[@]} -gt 0 ]; then
      echo "  Jira accounts already set up: ${JIRA_NICKS[*]}"
      echo "    1. Use one of them"
      echo "    2. Add a new Jira account"
      choose "  Choose [1/2]: " 2 reuse
      if [ "$reuse" = "1" ]; then
        JIRA_IS_NEW=0
        if [ ${#JIRA_NICKS[@]} -eq 1 ]; then
          JIRA_NICK="${JIRA_NICKS[0]}"
        else
          for i in "${!JIRA_NICKS[@]}"; do
            echo "    $((i+1)). ${JIRA_NICKS[$i]}"
          done
          choose "  Choose [1-${#JIRA_NICKS[@]}]: " "${#JIRA_NICKS[@]}" pick
          JIRA_NICK="${JIRA_NICKS[$((pick-1))]}"
        fi
        get_jira_credentials "$JIRA_NICK"   # URL and email from .env, token from the Keychain
        echo "  Using the Jira account '$JIRA_NICK'"
      fi
    fi
    if [ "$JIRA_IS_NEW" = "1" ]; then
      while true; do
        ask_value "  Jira URL (e.g. https://acme.atlassian.net): " JIRA_URL
        valid_url "$JIRA_URL" && break
        echo "  Enter a full URL, like https://acme.atlassian.net"
      done
      JIRA_NICK=$(derive_jira_nick "$JIRA_URL")
      base_nick="$JIRA_NICK"
      while nick_is_known "$JIRA_NICK"; do
        JIRA_NICK="${base_nick}-$((RANDOM % 1000 + 1))"
      done
      echo "  → Jira account name: $JIRA_NICK"
      while true; do
        ask_value "  Your Jira email: " JIRA_USER
        valid_email "$JIRA_USER" && break
        echo "  Enter a valid email."
      done
      ask_value "  Jira API token: " JIRA_TOKEN secret
    fi
    ask_value "  Jira project key (e.g. ABC): " JIRA_KEY

    # ── Git provider ──────────────────────────────────────
    echo ""
    echo "  Git provider:"
    echo "    1. GitHub"
    echo "    2. Bitbucket"
    choose "  Choose [1/2]: " 2 pick
    if [ "$pick" = "1" ]; then REPO_PROVIDER="github"; else REPO_PROVIDER="bitbucket"; fi

    if [ "$REPO_PROVIDER" = "github" ]; then
      echo ""
      echo "  GitHub:"
      # One GitHub token serves every GitHub project (Keychain service maestro-github).
      existing_gh=$(keychain_get "maestro-github")
      GH_IS_NEW=1
      if [ -n "$existing_gh" ]; then
        echo "    1. Use the GitHub token that Maestro already has"
        echo "    2. Enter a new GitHub token. It replaces the old one for all projects."
        choose "  Choose [1/2]: " 2 pick
        if [ "$pick" = "1" ]; then
          GH_TOKEN="$existing_gh"
          GH_IS_NEW=0
        fi
      fi
      [ "$GH_IS_NEW" = "1" ] && ask_value "  GitHub token: " GH_TOKEN secret
      while true; do
        ask_value "  GitHub repo URL (https://github.com/owner/repo): " repo_url
        parse_github_url "$repo_url" && break
        echo "  Use https://github.com/owner/repo or owner/repo."
      done
      OWNER="$GH_OWNER"; REPO="$GH_REPO"
    else
      echo ""
      echo "  Bitbucket:"
      # Bitbucket uses its OWN credentials: Atlassian issues separate API tokens for Jira and
      # Bitbucket. The email is usually the same Atlassian account, so offer to reuse it.
      if [ -n "$JIRA_USER" ]; then
        echo "    1. Use the Jira email ($JIRA_USER)"
        echo "    2. Enter another email"
        choose "  Choose [1/2]: " 2 pick
        [ "$pick" = "1" ] && BB_USER="$JIRA_USER"
      fi
      while [ -z "$BB_USER" ] || ! valid_email "$BB_USER"; do
        ask "  Bitbucket email: " BB_USER
      done
      ask_value "  Bitbucket API token: " BB_TOKEN secret
      while true; do
        ask_value "  Bitbucket repo URL (https://bitbucket.org/workspace/repo): " repo_url
        parse_bitbucket_url "$repo_url" && break
        echo "  Use https://bitbucket.org/workspace/repo or workspace/repo."
      done
      OWNER="$BB_WORKSPACE"; REPO="$BB_REPO"
    fi
    SLUG=$(slugify "$OWNER-$REPO")

    # ── Local repo ────────────────────────────────────────
    echo ""
    while true; do
      ask_value "  Path of your local clone of $OWNER/$REPO: " REPO_PATH
      REPO_PATH=$(expand_path "$REPO_PATH")
      [ -d "$REPO_PATH" ] && break
      echo "  Folder not found: $REPO_PATH. Clone the repo first, or check the path."
    done
    REPO_PATH="$(cd "$REPO_PATH" && pwd)"
    ask "  Base branch [main]: " BASE_BRANCH
    BASE_BRANCH="${BASE_BRANCH:-main}"
    ask_value "  Branch prefix (e.g. ABC): " BRANCH_PREFIX

    # ── Claude login ──────────────────────────────────────
    # A separate API key bills this project's Claude usage to that key's Anthropic account.
    # The key goes to the Keychain; the repo gets only an apiKeyHelper pointer.
    echo ""
    echo "  Claude login for this project:"
    echo "    1. My Claude subscription (Pro/Max)"
    echo "    2. A separate Anthropic API key. Usage is billed to that key's account."
    choose "  Choose [1/2]: " 2 claude_login
    if [ "$claude_login" = "2" ]; then
      ask_value "  Anthropic API key for '$SLUG': " ANTHROPIC_KEY secret
    fi

    # ── Review ────────────────────────────────────────────
    if [ "$JIRA_IS_NEW" = "1" ]; then
      jira_label="$JIRA_NICK (new: $JIRA_URL, $JIRA_USER)"
    else
      jira_label="$JIRA_NICK"
    fi
    echo ""
    echo "  ─── Review ───"
    printf "    %-16s %s\n" "Project:"       "$SLUG"
    printf "    %-16s %s\n" "Jira account:"  "$jira_label"
    printf "    %-16s %s\n" "Project key:"   "$JIRA_KEY"
    printf "    %-16s %s\n" "Repo:"          "$REPO_PROVIDER $OWNER/$REPO"
    [ "$REPO_PROVIDER" = "bitbucket" ] && printf "    %-16s %s\n" "Bitbucket email:" "$BB_USER"
    printf "    %-16s %s\n" "Local path:"    "$REPO_PATH"
    printf "    %-16s %s\n" "Base branch:"   "$BASE_BRANCH"
    printf "    %-16s %s\n" "Branch prefix:" "$BRANCH_PREFIX"
    if [ -n "$ANTHROPIC_KEY" ]; then
      printf "    %-16s %s\n" "Claude login:" "separate API key"
    else
      printf "    %-16s %s\n" "Claude login:" "subscription"
    fi
    echo ""
    echo "    1. Looks good"
    echo "    2. Enter this project again"
    choose "  Choose [1/2]: " 2 pick
    [ "$pick" = "1" ] && break
  done

  # ── Check (nothing is saved yet) ──────────────────────
  echo ""
  echo "  Checking '$SLUG'..."
  local failed=0
  validate_jira_connection "$JIRA_URL" "$JIRA_USER" "$JIRA_TOKEN" || failed=1
  if [ "$failed" = "0" ]; then
    validate_jira_project "$JIRA_URL" "$JIRA_USER" "$JIRA_TOKEN" "$JIRA_KEY" || failed=1
  fi
  if [ "$REPO_PROVIDER" = "github" ]; then
    validate_github_connection "$GH_OWNER" "$GH_REPO" "$GH_TOKEN" || failed=1
  else
    validate_bitbucket_connection "$BB_WORKSPACE" "$BB_REPO" "$BB_USER" "$BB_TOKEN" || failed=1
  fi
  check_repo "$REPO_PATH" "$BASE_BRANCH" || failed=1
  if [ -n "$ANTHROPIC_KEY" ]; then
    validate_anthropic_key "$ANTHROPIC_KEY" "$SLUG" || true   # a warning only
  fi
  if [ "$failed" = "1" ]; then
    echo ""
    warn "Linking '$SLUG' failed. Nothing was saved for this project."
    echo "   Fix the problems above, then run ./install.sh and choose 'Link a project'."
    return 1
  fi

  save_project
  LINKED_SLUGS+=("$SLUG")
  echo ""
  ok "Maestro is linked with '$SLUG'."
}

save_project() {
  local nick_key ws_key svc settings name yaml
  echo ""
  echo "  Saving '$SLUG'..."

  # Jira URL and email are not secrets, so they go to .env. The API token goes to the Keychain.
  if [ "$JIRA_IS_NEW" = "1" ]; then
    nick_key=$(envkey "$JIRA_NICK")
    {
      echo "JIRA_URL_${nick_key}=${JIRA_URL}"
      echo "JIRA_USERNAME_${nick_key}=${JIRA_USER}"
      echo ""
    } >> "$MAESTRO_STATE/.env"
    keychain_set "maestro-jira-${nick_key}" "$JIRA_TOKEN"
    ok "Jira account '$JIRA_NICK' (token in the Keychain)"
  fi

  if [ "$REPO_PROVIDER" = "github" ]; then
    if [ "$GH_IS_NEW" = "1" ]; then
      keychain_set "maestro-github" "$GH_TOKEN"
      ok "GitHub token in the Keychain"
    fi
  else
    # The Bitbucket email stays in .env, keyed by workspace. The token goes to the Keychain under
    # maestro-bitbucket-<workspace> (literal workspace name, as the PR agents read it).
    ws_key=$(envkey "$BB_WORKSPACE")
    grep -q "^BITBUCKET_USERNAME_${ws_key}=" "$MAESTRO_STATE/.env" 2>/dev/null || \
      echo "BITBUCKET_USERNAME_${ws_key}=${BB_USER}" >> "$MAESTRO_STATE/.env"
    keychain_set "maestro-bitbucket-${BB_WORKSPACE}" "$BB_TOKEN"
    ok "Bitbucket token in the Keychain"
  fi
  chmod 600 "$MAESTRO_STATE/.env" 2>/dev/null || true

  # ── Claude login ──────────────────────────────────────
  # Separate key  → key in the Keychain + a gitignored apiKeyHelper pointer. The key value is
  #                 NEVER written into the repo, only the Keychain reference.
  # Subscription  → no apiKeyHelper; strip any stale one a previous link left behind so it
  #                 cannot silently force API-credit billing.
  settings="$REPO_PATH/.claude/settings.local.json"
  if [ -n "$ANTHROPIC_KEY" ]; then
    svc="maestro-anthropic-${SLUG}"
    security delete-generic-password -a "$USER" -s "$svc" >/dev/null 2>&1 || true
    if security add-generic-password -a "$USER" -s "$svc" -w "$ANTHROPIC_KEY" -T /usr/bin/security >/dev/null 2>&1; then
      ok "Anthropic API key in the Keychain ($svc)"
    else
      warn "Could not store the Anthropic API key in the Keychain for $SLUG"
    fi

    mkdir -p "$REPO_PATH/.claude"
    python3 - "$settings" "security find-generic-password -a $USER -s $svc -w" << 'PYEOF'
import json, sys
path, helper = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = json.load(f)
except (FileNotFoundError, ValueError):
    data = {}
data["apiKeyHelper"] = helper
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
    git_exclude_add "$REPO_PATH" ".claude/settings.local.json"
    ok ".claude/settings.local.json → apiKeyHelper (this project uses API credits)"
  elif [ -f "$settings" ]; then
    python3 - "$settings" << 'PYEOF'
import json, sys
p = sys.argv[1]
try:
    with open(p) as f:
        data = json.load(f)
except (FileNotFoundError, ValueError):
    data = {}
if data.pop("apiKeyHelper", None) is not None:
    with open(p, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
PYEOF
  fi

  # ── MCP config, maestro.yaml, VS Code workspace ───────
  generate_project_mcp_json "$REPO_PATH" "$JIRA_NICK"
  ok "$REPO_PATH/.mcp.json (Jira server; ignored by git)"

  yaml="$REPO_PATH/maestro.yaml"
  if [ -f "$yaml" ]; then
    echo "  maestro.yaml already exists in $SLUG. The installer keeps it."
  else
    cat > "$yaml" << EOF
# Maestro — Project Configuration
# Generated by install.sh. Commit this file to your iOS repo.

project:
  name: $SLUG
  platform: ios

jira:
  mcp_server: atlassian-${JIRA_NICK}
  project_key: ${JIRA_KEY}
  qa_column: "Ready for QA"
  in_progress_column: "In Progress"
  done_column: "Done"
EOF
    if [ "$REPO_PROVIDER" = "github" ]; then
      cat >> "$yaml" << EOF

github:
  owner: ${OWNER}
  repo: ${REPO}
  base_branch: ${BASE_BRANCH}
  branch_prefix: "${BRANCH_PREFIX}"
  pr_draft: true
EOF
    else
      cat >> "$yaml" << EOF

bitbucket:
  workspace: ${OWNER}
  repo: ${REPO}
  jira_account: atlassian-${JIRA_NICK}
  base_branch: ${BASE_BRANCH}
  branch_prefix: "${BRANCH_PREFIX}"
  pr_draft: true
EOF
    fi
    cat >> "$yaml" << EOF

agent:
  loop_back_limit: 3
EOF
    ok "$SLUG/maestro.yaml"
  fi

  mkdir -p "$MAESTRO_STATE/workspaces"
  name=$(capitalize "$SLUG")
  cat > "$MAESTRO_STATE/workspaces/${SLUG}.code-workspace" << EOF
{
  "folders": [
    { "name": "Maestro", "path": "$MAESTRO_DIR" },
    { "name": "$name",   "path": "$REPO_PATH" }
  ]
}
EOF
  ok "~/.maestro/workspaces/${SLUG}.code-workspace"
}

open_in_vscode() {
  local n=${#LINKED_SLUGS[@]} i pick
  if ! command -v code >/dev/null 2>&1; then
    echo "Open a project: double-click its file in ~/.maestro/workspaces/"
    return 0
  fi
  echo "Open a project in VS Code?"
  for i in "${!LINKED_SLUGS[@]}"; do
    echo "  $((i+1)). ${LINKED_SLUGS[$i]}"
  done
  echo "  $((n+1)). No"
  choose "Choose [1-$((n+1))]: " "$((n+1))" pick
  if [ "$pick" -le "$n" ]; then
    code "$MAESTRO_STATE/workspaces/${LINKED_SLUGS[$((pick-1))]}.code-workspace" || true
  fi
}

# ─── Main ─────────────────────────────────────────────────
echo "=== Maestro — Setup ==="
LINKED_SLUGS=()

if [ -f "$MAESTRO_STATE/.env" ]; then
  echo ""
  echo "Maestro is already installed."
  echo "  1. Link a project"
  echo "  2. Install again (tools and Maestro). Your linked projects stay."
  echo "  3. Cancel"
  choose "Choose [1/2/3]: " 3 MODE_CHOICE
  case "$MODE_CHOICE" in
    1) link_project ;;
    2) install_maestro ;;
    *) echo "Cancelled. Nothing changed."; exit 0 ;;
  esac
else
  install_maestro
fi

# Reached only after a successful install or link: a failure stops the script above (set -e).
while true; do
  echo ""
  if [ ${#LINKED_SLUGS[@]} -eq 0 ]; then
    echo "Do you want to link Maestro with a project?"
  else
    echo "Do you want to link Maestro with another project?"
  fi
  echo "  1. Yes"
  echo "  2. No"
  choose "Choose [1/2]: " 2 MORE
  [ "$MORE" = "1" ] || break
  link_project
done

echo ""
if [ ${#LINKED_SLUGS[@]} -gt 0 ]; then
  open_in_vscode
  echo "Start a ticket:  /maestro <TICKET-ID>"
else
  echo "To link a project later, run ./install.sh and choose 'Link a project'."
fi
