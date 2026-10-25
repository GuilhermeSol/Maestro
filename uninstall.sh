#!/bin/bash
# Maestro — Uninstall
#
# Removes what install.sh set up for the current Mac account, credentials included.
#
# The script finds every Maestro item and shows the list. Then you choose:
#   1. Delete everything in the list (one confirmation for all)
#   2. Delete one by one (one confirmation for each item)
#
# Order: the dependencies go first and ~/.maestro goes last. When an item fails to delete, the
# script continues with the next item, but it keeps ~/.maestro. Fix the problem, then run
# ./uninstall.sh again.
#
# The Maestro code (this repo) is never part of the list, not even for "delete everything".
# At the end, the script asks if it should also delete the code. It asks only when no item
# failed, so after a failure the code stays and the script can run again.
#
# Dependencies, in delete order:
#   - Claude Code MCP servers that install.sh registered (atlassian-*, github, git)
#   - Credentials: Keychain tokens (maestro-jira-*, maestro-github, maestro-bitbucket-*,
#     maestro-anthropic-*), git logins that git saved in the Keychain when install.sh used a
#     token, plaintext tokens that old installs wrote to files, tokens inside git remote URLs
#   - The SessionStart hook and the Maestro block in ~/.claude
#   - Slash command and subagent links in ~/.claude
#   - Maestro files in each project repo (.mcp.json, apiKeyHelper, .git/info/exclude lines)
#   - Homebrew packages that install.sh adds when they are missing
# Deleted last: ~/.maestro. Then the question about this repo.
#
# Usage:
#   ./uninstall.sh            find the items, then delete them (asks first)
#   ./uninstall.sh --dry-run  show the items and delete nothing
#
# The uninstall does not remove:
#   - maestro.yaml in each project repo. It is project content that git tracks.
#   - Homebrew, the Claude Code CLI, and your own Claude Code login.
#   - ~/.claude/CLAUDE.md.bak, the copy install.sh made before it first edited CLAUDE.md.
#
# Only functions are defined at the top level. The last line runs main and exits on the same
# line, so bash reads nothing more from this file after the step that deletes this repo.

MAESTRO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # same path form install.sh uses
MAESTRO_DIR_REAL="$(cd "$MAESTRO_DIR" && pwd -P)"             # symlinks resolved, for deletion
MAESTRO_STATE="$HOME/.maestro"
CLAUDE_HOME="$HOME/.claude"
CLAUDE_JSON="$HOME/.claude.json"            # Claude Code keeps its MCP server list here
HOOK_MARKER=".maestro/hooks/session-start.sh"
# Packages that install.sh adds when they are missing. A package comes before the packages it can use.
BREW_FORMULAS="mcp-atlassian gitleaks swiftlint gh uv node"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
ok()    { printf "${GREEN}✓${NC} %s\n" "$1"; }
warn()  { printf "⚠️  %s\n" "$1"; }
fail()  { printf "${RED}✗${NC} %s\n" "$1"; }
tilde() { case "$1" in "$HOME"/*) printf '~%s\n' "${1#"$HOME"}" ;; *) printf '%s\n' "$1" ;; esac; }

usage() {
  echo "Usage: ./uninstall.sh [--dry-run]"
  echo "  --dry-run  Show what the uninstall finds. Delete nothing."
}

# ─── Item list ────────────────────────────────────────────
# One entry per item, in delete order. GROUP is "dep" (dependency) or "maestro" (deleted last).
ITEM_KIND=(); ITEM_ARG=(); ITEM_LABEL=(); ITEM_GROUP=(); ITEM_SECTION=()
add_item() {
  ITEM_KIND+=("$1"); ITEM_ARG+=("$2"); ITEM_LABEL+=("$3"); ITEM_GROUP+=("$4"); ITEM_SECTION+=("$5")
}
NOTES=()
DELETED=(); KEPT=(); FAILED=(); BLOCKED=(); NOT_RUN=()
MODE=""; STOPPED=0; DRY_RUN=0; CHOICE=""; REPO_DELETED=0; REPO_KEPT=0; BLOCK_WARNED=0

# Reads a number from 1 to $2 into CHOICE. Returns 1 when there is no more input.
ask_choice() {
  local reply
  while true; do
    reply=""
    if ! read -rp "$1" reply && [ -z "$reply" ]; then
      echo ""
      return 1
    fi
    if [[ "$reply" =~ ^[0-9]+$ ]] && [ "$reply" -ge 1 ] && [ "$reply" -le "$2" ]; then
      CHOICE="$reply"
      return 0
    fi
    echo "  Enter a number from 1 to $2."
  done
}

# Same lookup as install.sh: PATH first, then the usual install folders, then the login shell.
resolve_claude_cli() {
  if command -v claude >/dev/null 2>&1; then
    CLAUDE_CMD="claude"
    return 0
  fi
  local c
  for c in "$HOME/.claude/local/claude" "/opt/homebrew/bin/claude" "/usr/local/bin/claude" \
           "$HOME/.local/bin/claude" "$HOME/.npm-global/bin/claude"; do
    if [ -x "$c" ]; then
      CLAUDE_CMD="$c"
      return 0
    fi
  done
  local resolved
  resolved="$("${SHELL:-/bin/zsh}" -ilc 'command -v claude' 2>/dev/null | tail -n1)"
  if [ -n "$resolved" ]; then
    CLAUDE_CMD="$resolved"
    return 0
  fi
  return 1
}

# ─── JSON and text edits (python3, the same tool install.sh uses) ──────────
# Each command returns 0 on success. The "-has" and "-list" commands return 0 when they find
# Maestro data. No command prints a secret value.
pyhelper() {
  python3 - "$@" <<'PY'
import glob, json, os, re, sys, tempfile

BEGIN = "<!-- MAESTRO:BEGIN"
END = "<!-- MAESTRO:END -->"
EXCLUDES = (".mcp.json", ".claude/settings.local.json")
TOKEN_KEY = re.compile(r"^(JIRA_API_TOKEN(_\w+)?|GITHUB_TOKEN|GITHUB_PERSONAL_ACCESS_TOKEN"
                       r"|BITBUCKET_API_TOKEN(_\w+)?|ANTHROPIC_API_KEY(_\w+)?)$")


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def write_atomic(path, text):
    path = os.path.realpath(path)   # keep a symlinked file (dotfiles) a symlink
    mode = None
    try:
        mode = os.stat(path).st_mode & 0o777
    except FileNotFoundError:
        pass
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".maestro-uninstall-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        if mode is not None:
            os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def write_json(path, data):
    write_atomic(path, json.dumps(data, indent=2, ensure_ascii=False) + "\n")


def maestro_servers(servers):
    # Names of the MCP servers that install.sh registers, old and new versions.
    if not isinstance(servers, dict):
        return []
    found = []
    for name, spec in servers.items():
        if not isinstance(spec, dict):
            continue
        text = " ".join([str(spec.get("command", ""))] + [str(a) for a in spec.get("args") or []])
        launcher = "mcp-with-secrets.sh" in text
        if name.startswith("atlassian-") and (launcher or "mcp-atlassian" in text):
            found.append(name)
        elif name == "github" and (launcher or "server-github" in text):
            found.append(name)
        elif name == "git" and "mcp-server-git" in text:
            found.append(name)
    return found


def mcp_list(path):
    try:
        data = load_json(path)
    except (OSError, ValueError):
        return 1
    names = maestro_servers(data.get("mcpServers") if isinstance(data, dict) else None)
    for name in names:
        print(name)
    return 0 if names else 1


def mcp_local_list(path):
    # Servers in a project (local) scope. Old installs could register them there.
    try:
        data = load_json(path)
    except (OSError, ValueError):
        return 1
    found = 0
    for proj, cfg in ((data.get("projects") or {}) if isinstance(data, dict) else {}).items():
        for name in maestro_servers(cfg.get("mcpServers") if isinstance(cfg, dict) else None):
            print(f"{proj}|{name}")
            found += 1
    return 0 if found else 1


def secrets_in(path):
    # Prints the names of plaintext token keys that have a value. Never prints a value.
    keys = set()
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return 1
    try:
        data = json.loads(text)
    except ValueError:
        data = None
    if isinstance(data, dict):
        for spec in (data.get("mcpServers") or {}).values():
            env = spec.get("env") if isinstance(spec, dict) else None
            for k, v in (env or {}).items():
                if TOKEN_KEY.match(str(k)) and str(v).strip():
                    keys.add(str(k))
    else:
        for line in text.splitlines():
            k, sep, v = line.strip().partition("=")
            if sep and TOKEN_KEY.match(k.strip()) and v.strip():
                keys.add(k.strip())
    if keys:
        print(", ".join(sorted(keys)))
        return 0
    return 1


def env_scrub(path):
    # Removes the token lines from a .env file and keeps the other lines.
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines(True)
    out = [l for l in lines if not TOKEN_KEY.match(l.strip().partition("=")[0].strip())]
    if len(out) != len(lines):
        write_atomic(path, "".join(out))
        print(f"    Removed {len(lines) - len(out)} token line(s). The other lines stay.")
    return 0


def is_maestro_mcp_json(path):
    # The file that install.sh generates: only atlassian-*, git and github servers.
    try:
        data = load_json(path)
    except (OSError, ValueError):
        return 1
    servers = data.get("mcpServers") if isinstance(data, dict) else None
    if not isinstance(servers, dict) or not servers:
        return 1
    names = set(servers)
    if not any(n.startswith("atlassian-") for n in names):
        return 1
    return 0 if all(n.startswith("atlassian-") or n in ("git", "github") for n in names) else 1


def hook(path, marker, remove):
    try:
        data = load_json(path)
    except FileNotFoundError:
        return 0 if remove else 1
    except ValueError as e:
        if remove:
            print(f"    {path} is not valid JSON ({e}). Remove the Maestro hook by hand.")
            return 1
        return 0   # list it, so the remove step shows the problem
    hooks = data.get("hooks") if isinstance(data, dict) else None
    found = 0
    if isinstance(hooks, dict):
        for event in list(hooks):
            groups = hooks[event]
            if not isinstance(groups, list):
                continue
            new_groups = []
            for group in groups:
                inner = group.get("hooks") if isinstance(group, dict) else None
                if isinstance(inner, list):
                    kept = [h for h in inner
                            if not (isinstance(h, dict) and marker in str(h.get("command", "")))]
                    if len(kept) != len(inner):
                        found += len(inner) - len(kept)
                        if not kept:
                            continue   # the group held only Maestro hooks
                        group["hooks"] = kept
                new_groups.append(group)
            if len(new_groups) != len(groups):
                if new_groups:
                    hooks[event] = new_groups
                else:
                    del hooks[event]
        if found and not hooks:
            del data["hooks"]
    if not remove:
        return 0 if found else 1
    if found:
        write_json(path, data)
    return 0


def claude_md(path, remove):
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        return 0 if remove else 1
    has_markers = BEGIN in text or END in text
    if not remove:
        return 0 if has_markers else 1
    if not has_markers:
        return 0
    block = re.compile(re.escape(BEGIN) + r".*?" + re.escape(END) + r"[ \t]*\n*", re.DOTALL)
    new = block.sub("", text)
    if BEGIN in new or END in new:
        print(f"    {path} has a MAESTRO marker without its pair. Remove the Maestro block by hand.")
        return 1
    if new.strip() or os.path.islink(path):
        write_atomic(path, new)
    else:
        os.remove(path)
        print("    The file had only the Maestro block, so the uninstall deleted the file.")
    return 0


def projects(ws_dir, *skip_dirs):
    skip = {os.path.realpath(p) for p in skip_dirs}
    seen = set()
    for ws in sorted(glob.glob(os.path.join(ws_dir, "*.code-workspace"))):
        try:
            data = load_json(ws)
        except (OSError, ValueError):
            continue
        for folder in data.get("folders") or []:
            p = folder.get("path") if isinstance(folder, dict) else None
            if not isinstance(p, str) or not p:
                continue
            p = os.path.expanduser(p)
            if not os.path.isabs(p):
                p = os.path.join(os.path.dirname(ws), p)
            real = os.path.realpath(p)
            if real in skip or real in seen or not os.path.isdir(real):
                continue
            seen.add(real)
            print(real)
    return 0


def is_maestro_helper(data):
    helper = data.get("apiKeyHelper") if isinstance(data, dict) else None
    return isinstance(helper, str) and "maestro-anthropic-" in helper


def api_key(path, remove):
    try:
        data = load_json(path)
    except FileNotFoundError:
        return 0 if remove else 1
    except ValueError as e:
        if remove:
            print(f"    {path} is not valid JSON ({e}). Remove apiKeyHelper by hand.")
        return 1
    if not is_maestro_helper(data):
        return 0 if remove else 1
    if not remove:
        return 0
    del data["apiKeyHelper"]
    if data:
        write_json(path, data)
    else:
        os.remove(path)
        try:
            os.rmdir(os.path.dirname(path))   # only when the .claude folder is now empty
        except OSError:
            pass
        print("    The file had only the apiKeyHelper entry, so the uninstall deleted the file.")
    return 0


def file_goes_away(repo, entry):
    # True when the file is not there, or when this uninstall deletes it (Maestro made it).
    path = os.path.join(repo, entry)
    if not os.path.lexists(path):
        return True
    if entry == ".mcp.json":
        return is_maestro_mcp_json(path) == 0
    try:
        data = load_json(path)
    except (OSError, ValueError):
        return False
    return isinstance(data, dict) and list(data) == ["apiKeyHelper"] and is_maestro_helper(data)


def exclude(repo, remove):
    path = os.path.join(repo, ".git", "info", "exclude")
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines(True)
    except (FileNotFoundError, NotADirectoryError):
        return 0 if remove else 1
    entries = [l.rstrip("\r\n") for l in lines if l.rstrip("\r\n") in EXCLUDES]
    if not remove:
        removable = sorted({e for e in entries if file_goes_away(repo, e)})
        if removable:
            print(", ".join(removable))
            return 0
        return 1
    out = []
    for line in lines:
        entry = line.rstrip("\r\n")
        if entry in EXCLUDES:
            if os.path.lexists(os.path.join(repo, entry)):
                print(f"    Kept '{entry}': the file is still in the project, so git must keep ignoring it.")
            else:
                print(f"    Removed '{entry}'.")
                continue
        out.append(line)
    if len(out) != len(lines):
        write_atomic(path, "".join(out))
    return 0


def main(argv):
    cmd, args = argv[1], argv[2:]
    table = {
        "mcp-list":        lambda: mcp_list(*args),
        "mcp-local-list":  lambda: mcp_local_list(*args),
        "secrets-in":      lambda: secrets_in(*args),
        "env-scrub":       lambda: env_scrub(*args),
        "is-maestro-mcp":  lambda: is_maestro_mcp_json(*args),
        "hook-has":        lambda: hook(args[0], args[1], False),
        "hook-remove":     lambda: hook(args[0], args[1], True),
        "claudemd-has":    lambda: claude_md(args[0], False),
        "claudemd-remove": lambda: claude_md(args[0], True),
        "projects":        lambda: projects(*args),
        "apikey-has":      lambda: api_key(args[0], False),
        "apikey-remove":   lambda: api_key(args[0], True),
        "exclude-has":     lambda: exclude(args[0], False),
        "exclude-remove":  lambda: exclude(args[0], True),
    }
    try:
        return table[cmd]()
    except Exception as e:   # report the error, never a traceback
        print(f"    Error: {e}")
        return 1


sys.exit(main(sys.argv))
PY
}

# ─── Keychain and git helpers ─────────────────────────────
# These read item names only. They never read a secret value.
keychain_has() { security find-generic-password -s "$1" >/dev/null 2>&1; }
inet_has()     { security find-internet-password -s "$1" -a "$2" >/dev/null 2>&1; }

keychain_candidates() {
  {
    security dump-keychain 2>/dev/null | sed -n 's/.*"svce"<blob>="\(maestro-[^"]*\)".*/\1/p'
    if [ -f "$MAESTRO_STATE/.env" ]; then
      sed -n 's/^JIRA_URL_\([A-Z0-9_]*\)=.*/maestro-jira-\1/p' "$MAESTRO_STATE/.env"
      grep -q '^GITHUB_CONFIGURED=' "$MAESTRO_STATE/.env" && echo "maestro-github"
    fi
  } | grep -E '^maestro-(jira-.+|github|bitbucket-.+|anthropic-.+)$' | sort -u
}

bitbucket_users() {
  [ -f "$MAESTRO_STATE/.env" ] || return 0
  sed -n 's/^BITBUCKET_USERNAME_[A-Z0-9_]*=//p' "$MAESTRO_STATE/.env" | sort -u
}

# True when a remote URL of repo $1 holds a password or token (https://user:token@host/...).
remote_has_token() {
  git -C "$1" config --get-regexp '^remote\..*\.(url|pushurl)$' 2>/dev/null \
    | grep -qE '[[:space:]][a-zA-Z][a-zA-Z0-9+.-]*://[^/@[:space:]]*:[^/@[:space:]]*@'
}

is_maestro_target() {
  case "$1" in
    "$MAESTRO_DIR"/*|"$MAESTRO_DIR_REAL"/*|"$MAESTRO_STATE"/*) return 0 ;;
  esac
  return 1
}

# Sets LINKS (one path per line) and LINK_NAMES for the Maestro links in folder $1.
collect_links() {
  LINKS=""; LINK_NAMES=""
  local f n
  [ -d "$1" ] || return 0
  for f in "$1"/*; do
    [ -L "$f" ] || continue
    is_maestro_target "$(readlink "$f")" || continue
    LINKS="${LINKS}${f}"$'\n'
    n="$(basename "$f")"
    LINK_NAMES="${LINK_NAMES:+$LINK_NAMES, }${2}${n%.md}"
  done
}

# ─── Discovery ────────────────────────────────────────────
discover_items() {
  local sec names name svc label p f g keys entries installed user repos projects seen dup

  # Project repos come from the VS Code workspace files that install.sh writes.
  projects=""
  [ -d "$MAESTRO_STATE/workspaces" ] && \
    projects="$(pyhelper projects "$MAESTRO_STATE/workspaces" "$MAESTRO_DIR" "$MAESTRO_DIR_REAL")"

  sec="Claude Code MCP servers"
  if [ -f "$CLAUDE_JSON" ]; then
    names="$(pyhelper mcp-list "$CLAUDE_JSON")"
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      if [ "$name" = "git" ]; then
        label="MCP server 'git', user scope (install.sh registered it; other tools can use it too)"
      else
        label="MCP server '$name', user scope"
      fi
      add_item mcp "$name" "$label" dep "$sec"
    done <<< "$names"
    names="$(pyhelper mcp-local-list "$CLAUDE_JSON")"
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      add_item mcp_local "$name" "MCP server '${name##*|}', project scope of $(tilde "${name%|*}")" dep "$sec"
    done <<< "$names"
  fi

  sec="Credentials (tokens and keys)"
  if command -v security >/dev/null 2>&1; then
    names="$(keychain_candidates)"
    while IFS= read -r svc; do
      [ -n "$svc" ] || continue
      keychain_has "$svc" || continue
      case "$svc" in
        maestro-jira-*)      label="Jira API token" ;;
        maestro-github)      label="GitHub token" ;;
        maestro-bitbucket-*) label="Bitbucket API token" ;;
        *)                   label="Claude (Anthropic) API key" ;;
      esac
      add_item keychain "$svc" "$label in the Keychain ('$svc')" dep "$sec"
    done <<< "$names"
    if inet_has github.com x-access-token; then
      add_item keychain_inet "github.com|x-access-token" \
        "GitHub token that git saved in the Keychain (github.com, account 'x-access-token') when install.sh cloned or fetched" dep "$sec"
    fi
    while IFS= read -r user; do
      [ -n "$user" ] || continue
      inet_has bitbucket.org "$user" && add_item keychain_inet "bitbucket.org|$user" \
        "Bitbucket token that git saved in the Keychain (bitbucket.org, account '$user') when install.sh cloned or fetched" dep "$sec"
    done <<< "$(bitbucket_users)"
  fi
  # Old installs wrote tokens in plaintext. Keep the other lines of ~/.maestro/.env: a second
  # uninstall run reads them.
  if [ -f "$MAESTRO_STATE/.env" ] && keys="$(pyhelper secrets-in "$MAESTRO_STATE/.env")"; then
    add_item env_scrub "$MAESTRO_STATE/.env" "Plaintext tokens in ~/.maestro/.env from an old install: $keys" dep "$sec"
  fi
  # When an old install linked ~/.maestro to the repo, two paths can name one file: list it once.
  seen="$MAESTRO_STATE/.env"
  for f in "$MAESTRO_STATE/.mcp.json" "$MAESTRO_DIR_REAL/.env" "$MAESTRO_DIR_REAL/.mcp.json" \
           "$MAESTRO_DIR_REAL/.maestro_state/.env" "$MAESTRO_DIR_REAL/.maestro_state/.mcp.json"; do
    [ -f "$f" ] || continue
    dup=0
    while IFS= read -r g; do
      [ -n "$g" ] && [ "$f" -ef "$g" ] && dup=1
    done <<< "$seen"
    [ "$dup" = "1" ] && continue
    if keys="$(pyhelper secrets-in "$f")"; then
      add_item secret_file "$f" "Old config file with plaintext tokens: $(tilde "$f") ($keys)" dep "$sec"
      seen="$seen"$'\n'"$f"
    fi
  done
  repos="$projects"$'\n'"$MAESTRO_DIR_REAL"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    remote_has_token "$p" && add_item remote_token "$p" \
      "Token inside a git remote URL of $(tilde "$p"). The uninstall removes the login part of the URL." dep "$sec"
  done <<< "$repos"

  sec="Claude Code settings in ~/.claude"
  if [ -f "$CLAUDE_HOME/settings.json" ] && pyhelper hook-has "$CLAUDE_HOME/settings.json" "$HOOK_MARKER"; then
    add_item hook "$CLAUDE_HOME/settings.json" \
      "SessionStart hook in ~/.claude/settings.json (it starts Maestro in repos with a maestro.yaml)" dep "$sec"
  fi
  if [ -f "$CLAUDE_HOME/CLAUDE.md" ] && pyhelper claudemd-has "$CLAUDE_HOME/CLAUDE.md"; then
    add_item claudemd "$CLAUDE_HOME/CLAUDE.md" \
      "Maestro rules block in ~/.claude/CLAUDE.md (your own text in the file stays)" dep "$sec"
  fi

  sec="Slash commands and subagents (links to the Maestro code)"
  collect_links "$CLAUDE_HOME/commands" "/"
  [ -n "$LINKS" ] && add_item links "$LINKS" "Slash commands in ~/.claude/commands: $LINK_NAMES" dep "$sec"
  collect_links "$CLAUDE_HOME/agents" ""
  [ -n "$LINKS" ] && add_item links "$LINKS" "Subagents in ~/.claude/agents: $LINK_NAMES" dep "$sec"

  sec="Files in your project repos"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -f "$p/.mcp.json" ] && pyhelper is-maestro-mcp "$p/.mcp.json"; then
      label="Generated MCP config: $(tilde "$p")/.mcp.json"
      keys="$(pyhelper secrets-in "$p/.mcp.json")" && label="$label (has plaintext tokens: $keys)"
      if git -C "$p" ls-files --error-unmatch .mcp.json >/dev/null 2>&1; then
        NOTES+=("$(tilde "$p")/.mcp.json stays because git tracks it. Delete it with a commit if you want.")
      else
        add_item project_mcp "$p" "$label" dep "$sec"
      fi
    fi
    if [ -f "$p/.claude/settings.local.json" ] && pyhelper apikey-has "$p/.claude/settings.local.json"; then
      add_item project_apikey "$p" \
        "apiKeyHelper entry in $(tilde "$p")/.claude/settings.local.json (other settings stay)" dep "$sec"
    fi
    if entries="$(pyhelper exclude-has "$p")"; then
      add_item project_exclude "$p" "Maestro lines in $(tilde "$p")/.git/info/exclude: $entries" dep "$sec"
    fi
    [ -f "$p/maestro.yaml" ] && \
      NOTES+=("$(tilde "$p")/maestro.yaml stays. It is project content. Delete it with a commit if you want.")
  done <<< "$projects"

  sec="Homebrew packages (install.sh adds them if missing; other apps can use them too)"
  if command -v brew >/dev/null 2>&1; then
    installed="$(brew list --formula 2>/dev/null)"
    for f in $BREW_FORMULAS; do
      printf '%s\n' "$installed" | grep -qxF "$f" && add_item brew "$f" "Homebrew package '$f'" dep "$sec"
    done
  fi

  sec="Maestro settings (deleted last; kept if an item fails to delete)"
  if [ -e "$MAESTRO_STATE" ] || [ -L "$MAESTRO_STATE" ]; then
    add_item state "$MAESTRO_STATE" \
      "~/.maestro: Maestro settings for this Mac account (.env, .mcp.json, workspaces) and links to the code" maestro "$sec"
  fi

  [ -f "$CLAUDE_HOME/CLAUDE.md.bak" ] && \
    NOTES+=("~/.claude/CLAUDE.md.bak stays. install.sh made this copy before it first edited CLAUDE.md.")
  NOTES+=("Homebrew, the Claude Code CLI and your own Claude Code login stay.")
}

print_items() {
  local i last=""
  for i in "${!ITEM_KIND[@]}"; do
    if [ "${ITEM_SECTION[$i]}" != "$last" ]; then
      echo ""
      echo "${ITEM_SECTION[$i]}:"
      last="${ITEM_SECTION[$i]}"
    fi
    printf "  %2d. %s\n" "$((i+1))" "${ITEM_LABEL[$i]}"
  done
}

# ─── Delete steps ─────────────────────────────────────────
del_mcp() {   # $1 = server name, $2 = folder for a project-scope server (empty for user scope)
  if ! resolve_claude_cli; then
    echo "    The claude CLI was not found. Remove the server by hand with: claude mcp remove $1"
    return 1
  fi
  local out
  if [ -n "${2:-}" ]; then
    out="$(cd "$2" 2>&1 && "$CLAUDE_CMD" mcp remove "$1" -s local 2>&1)"
  else
    out="$("$CLAUDE_CMD" mcp remove "$1" -s user 2>&1)"
  fi
  local rc=$?
  [ "$rc" -ne 0 ] && printf '%s\n' "$out" | sed 's/^/    /'
  return "$rc"
}

# A Keychain item can exist more than once, so delete until none is left.
del_keychain() {
  local i=0 out=""
  while [ "$i" -lt 20 ] && out="$(security delete-generic-password -s "$1" 2>&1 >/dev/null)"; do
    i=$((i+1))
  done
  if keychain_has "$1"; then
    [ -n "$out" ] && echo "    $out"
    return 1
  fi
  return 0
}

del_keychain_inet() {   # $1 = "server|account"
  local srv="${1%%|*}" acct="${1#*|}" i=0 out=""
  while [ "$i" -lt 20 ] && out="$(security delete-internet-password -s "$srv" -a "$acct" 2>&1 >/dev/null)"; do
    i=$((i+1))
  done
  if inet_has "$srv" "$acct"; then
    [ -n "$out" ] && echo "    $out"
    return 1
  fi
  return 0
}

del_secret_file() {
  rm -f "${1:?}" && [ ! -e "$1" ]
}

# Rewrites each remote URL that holds a token, without the login part (as install.sh does).
del_remote_token() {
  local repo="$1" key vals v rc=0
  for key in $(git -C "$repo" config --name-only --get-regexp '^remote\..*\.(url|pushurl)$' | sort -u); do
    vals="$(git -C "$repo" config --get-all "$key")"
    printf '%s\n' "$vals" | grep -qE '^[a-zA-Z][a-zA-Z0-9+.-]*://[^/@]*:[^/@]*@' || continue
    git -C "$repo" config --unset-all "$key" || { rc=1; continue; }
    while IFS= read -r v; do
      [ -n "$v" ] || continue
      git -C "$repo" config --add "$key" \
        "$(printf '%s' "$v" | sed -E 's#^([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@]*@#\1#')" || rc=1
    done <<< "$vals"
    echo "    Cleaned $key."
  done
  remote_has_token "$repo" && rc=1
  return $rc
}

del_links() {
  local f rc=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -L "$f" ]; then
      rm -f "${f:?}" || rc=1
    fi
  done <<< "$1"
  return $rc
}

del_project_mcp() {
  rm -f "${1:?}/.mcp.json" && [ ! -e "$1/.mcp.json" ]
}

del_state() {
  local s="$MAESTRO_STATE" l
  if [ -L "$s" ]; then            # old installs linked ~/.maestro to the repo: remove only the link
    rm -f "${s:?}"
  elif [ -d "$s" ]; then
    for l in agents hooks bin .claude; do
      if [ -L "$s/$l" ]; then       # the links first, so nothing follows them into the repo
        rm -f "${s:?}/${l:?}"
      fi
    done
    rm -rf "${s:?}"
  fi
  [ ! -e "$s" ] && [ ! -L "$s" ]
}

del_repo() {
  local d="$MAESTRO_DIR_REAL"
  case "$d" in
    ""|"/"|"$HOME"|"$HOME/")
      echo "    The path '$d' is not safe to delete."
      return 1 ;;
  esac
  if [ ! -f "$d/install.sh" ] || [ ! -f "$d/hooks/session-start.sh" ] || [ ! -d "$d/agents" ]; then
    echo "    $d does not look like the Maestro repo, so the uninstall keeps it."
    return 1
  fi
  cd "$HOME" || cd / || return 1
  rm -rf "${d:?}"
  if [ -e "$d" ]; then
    return 1
  fi
  REPO_DELETED=1
  return 0
}

delete_item() {
  local kind="${ITEM_KIND[$1]}" arg="${ITEM_ARG[$1]}"
  case "$kind" in
    mcp)             del_mcp "$arg" "" ;;
    mcp_local)       del_mcp "${arg##*|}" "${arg%|*}" ;;
    keychain)        del_keychain "$arg" ;;
    keychain_inet)   del_keychain_inet "$arg" ;;
    env_scrub)       pyhelper env-scrub "$arg" ;;
    secret_file)     del_secret_file "$arg" ;;
    remote_token)    del_remote_token "$arg" ;;
    hook)            pyhelper hook-remove "$arg" "$HOOK_MARKER" ;;
    claudemd)        pyhelper claudemd-remove "$arg" ;;
    links)           del_links "$arg" ;;
    project_mcp)     del_project_mcp "$arg" ;;
    project_apikey)  pyhelper apikey-remove "$arg/.claude/settings.local.json" ;;
    project_exclude) pyhelper exclude-remove "$arg" ;;
    brew)            brew uninstall "$arg" 2>&1 | sed 's/^/    /'; return "${PIPESTATUS[0]}" ;;
    state)           del_state ;;
    *)               echo "    Unknown item type: $kind"; return 1 ;;
  esac
}

# Prints what would be lost and returns 0 when the repo has work that is not on the remote.
repo_has_unsaved_work() {
  local d="$MAESTRO_DIR_REAL" changes unpushed stashes found=1
  git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  changes="$(git -C "$d" status --porcelain 2>/dev/null)"
  unpushed="$(git -C "$d" log --branches --not --remotes --oneline 2>/dev/null)"
  stashes="$(git -C "$d" stash list 2>/dev/null)"
  if [ -n "$changes" ]; then
    warn "The Maestro repo has changes that are not committed:"
    printf '%s\n' "$changes" | head -20 | sed 's/^/      /'
    found=0
  fi
  if [ -n "$unpushed" ]; then
    warn "The Maestro repo has commits that are not pushed:"
    printf '%s\n' "$unpushed" | head -20 | sed 's/^/      /'
    found=0
  fi
  if [ -n "$stashes" ]; then
    warn "The Maestro repo has stashed changes:"
    printf '%s\n' "$stashes" | head -20 | sed 's/^/      /'
    found=0
  fi
  return $found
}

run_item() {
  local i="$1" total="$2" label="${ITEM_LABEL[$1]}"
  echo ""
  echo "[$((i+1))/$total] $label"

  if [ "$MODE" = "one" ]; then
    echo "  1. Delete"
    echo "  2. Keep"
    echo "  3. Stop the uninstall here"
    ask_choice "  Choose [1/2/3]: " 3 || CHOICE=3
    case "$CHOICE" in
      2) KEPT+=("$label"); warn "Kept"; return ;;
      3) STOPPED=1; NOT_RUN+=("$label"); warn "Stopped. The uninstall deletes nothing more."; return ;;
    esac
  fi

  if delete_item "$i"; then
    DELETED+=("$label"); ok "Deleted"
  else
    FAILED+=("$label"); fail "Could not delete. The uninstall continues with the next item."
  fi
}

process_items() {
  local i total="${#ITEM_KIND[@]}" warned=0
  for i in "${!ITEM_KIND[@]}"; do
    if [ "$STOPPED" = "1" ]; then
      NOT_RUN+=("${ITEM_LABEL[$i]}")
      continue
    fi
    if [ "${ITEM_GROUP[$i]}" = "maestro" ] && [ "${#FAILED[@]}" -gt 0 ]; then
      if [ "$warned" = "0" ]; then
        warned=1
        BLOCK_WARNED=1
        echo ""
        warn "Some items failed to delete. The uninstall keeps Maestro, so you can run it again."
      fi
      BLOCKED+=("${ITEM_LABEL[$i]}")
      continue
    fi
    run_item "$i" "$total"
  done
}

# The Maestro code is never part of the list, not even for "delete everything". This question
# comes last, and only when no item failed: after a failure the code stays, so the uninstall
# can run again.
ask_delete_code() {
  local label="Maestro code: $(tilde "$MAESTRO_DIR_REAL")"
  if [ "$STOPPED" = "1" ]; then
    NOT_RUN+=("$label")
    return 0
  fi
  if [ "${#FAILED[@]}" -gt 0 ]; then
    if [ "$BLOCK_WARNED" = "0" ]; then
      echo ""
      warn "Some items failed to delete. The uninstall keeps the Maestro code, so you can run it again."
    fi
    BLOCKED+=("$label")
    return 0
  fi
  echo ""
  echo "Do you also want to delete the Maestro code from this Mac?"
  echo "  $(tilde "$MAESTRO_DIR_REAL")"
  echo "  Other Mac accounts that use this folder also lose the Maestro code."
  if [ "${#KEPT[@]}" -gt 0 ]; then
    warn "You kept some items. The items that link to the Maestro code stop working without it."
  fi
  repo_has_unsaved_work || true
  echo "  1. Yes, delete the Maestro code"
  echo "  2. No, keep it"
  if ! ask_choice "Choose [1/2]: " 2 || [ "$CHOICE" != "1" ]; then
    KEPT+=("$label"); REPO_KEPT=1; warn "Kept the Maestro code"
    return 0
  fi
  if del_repo; then
    DELETED+=("$label"); ok "Deleted the Maestro code"
  else
    FAILED+=("$label"); fail "Could not delete the Maestro code."
  fi
}

print_group() {
  local title="$1"
  shift
  [ "$#" -gt 0 ] || return 0
  echo ""
  echo "$title ($#):"
  local x
  for x in "$@"; do echo "  - $x"; done
}

print_summary() {
  echo ""
  echo "=== Summary ==="
  print_group "Deleted" "${DELETED[@]}"
  print_group "Kept (your choice)" "${KEPT[@]}"
  print_group "Failed" "${FAILED[@]}"
  print_group "Kept because an item failed" "${BLOCKED[@]}"
  print_group "Not done (you stopped the uninstall)" "${NOT_RUN[@]}"
  echo ""
  if [ "${#FAILED[@]}" -gt 0 ]; then
    fail "Some items failed. Fix them, then run the uninstall again:"
    echo "    $(tilde "$MAESTRO_DIR_REAL")/uninstall.sh"
  elif [ "$(( ${#KEPT[@]} - REPO_KEPT ))" -eq 0 ] && [ "${#NOT_RUN[@]}" -eq 0 ]; then
    ok "Maestro is uninstalled."
    if [ "$REPO_KEPT" = "1" ]; then
      echo "The Maestro code stays in $(tilde "$MAESTRO_DIR_REAL"). To delete it later, run ./uninstall.sh again."
    fi
  fi
  if [ "${#DELETED[@]}" -gt 0 ]; then
    echo "Restart VS Code and any open Claude Code sessions. They keep the old Maestro setup until they restart."
  fi
  if [ "$REPO_DELETED" = "1" ]; then
    echo "If your terminal was in the Maestro folder, run: cd ~"
  fi
}

main() {
  case "${1:-}" in
    "") ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; return 0 ;;
    *) echo "Unknown option: $1"; usage; return 64 ;;
  esac
  if [ -z "$HOME" ] || [ ! -d "$HOME" ]; then
    echo "ERROR: HOME is not set to a folder."
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required."
    return 1
  fi

  echo "=== Maestro — Uninstall ==="
  echo ""
  echo "Looking for Maestro items for account '$(whoami)'..."
  discover_items

  echo ""
  if [ "${#ITEM_KIND[@]}" -gt 0 ]; then
    echo "The uninstall found ${#ITEM_KIND[@]} items. It deletes them in this order:"
    print_items
  else
    echo "The uninstall found nothing else to remove."
  fi
  echo ""
  echo "At the end, the uninstall asks if it should also delete the Maestro code:"
  echo "  $(tilde "$MAESTRO_DIR_REAL")"
  echo "It asks only when no item fails to delete."
  if [ "${#NOTES[@]}" -gt 0 ]; then
    echo ""
    echo "Not part of the uninstall:"
    local n
    for n in "${NOTES[@]}"; do echo "  - $n"; done
  fi

  if [ "$DRY_RUN" = "1" ]; then
    echo ""
    echo "Dry run: nothing was deleted."
    return 0
  fi

  if [ "${#ITEM_KIND[@]}" -eq 0 ]; then
    ask_delete_code
    print_summary
    return 0
  fi

  echo ""
  echo "How do you want to uninstall?"
  echo "  1. Delete everything in the list"
  echo "  2. Delete one by one (confirm each item)"
  echo "  3. Cancel"
  if ! ask_choice "Choose [1/2/3]: " 3; then
    echo "No answer. Nothing was deleted."
    return 0
  fi
  case "$CHOICE" in
    1)
      MODE="all"
      echo ""
      warn "This deletes all ${#ITEM_KIND[@]} items in the list. You cannot undo it."
      echo "  1. Yes, delete all"
      echo "  2. No, cancel"
      if ! ask_choice "Choose [1/2]: " 2 || [ "$CHOICE" != "1" ]; then
        echo "Cancelled. Nothing was deleted."
        return 0
      fi ;;
    2) MODE="one" ;;
    *) echo "Cancelled. Nothing was deleted."; return 0 ;;
  esac

  process_items
  ask_delete_code
  print_summary
  [ "${#FAILED[@]}" -eq 0 ]
}

main "$@"; exit $?
