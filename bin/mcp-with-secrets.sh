#!/usr/bin/env bash
# Maestro MCP launcher — fetches secrets from the macOS Keychain and injects them as
# environment variables, then execs the real MCP server. Keeps tokens out of .mcp.json
# and .env entirely; the only plaintext copy exists in this process's memory at runtime.
#
# Usage:
#   mcp-with-secrets.sh ENV_NAME=keychain-service [ENV_NAME=keychain-service ...] -- command [args...]
#
# Each ENV_NAME=keychain-service pair reads the generic password stored under that service
# name in the login keychain and exports it as ENV_NAME. Everything after `--` is the
# command to exec with those variables in scope.
set -euo pipefail

declare -a EXEC
parsing_secrets=1

for arg in "$@"; do
  if [ "$parsing_secrets" = "1" ] && [ "$arg" = "--" ]; then
    parsing_secrets=0
    continue
  fi
  if [ "$parsing_secrets" = "1" ]; then
    name="${arg%%=*}"
    service="${arg#*=}"
    value="$(security find-generic-password -s "$service" -w 2>/dev/null || true)"
    if [ -z "$value" ]; then
      echo "maestro: no keychain secret found for service '$service' (env $name)" >&2
    fi
    export "$name=$value"
  else
    EXEC+=("$arg")
  fi
done

if [ "${#EXEC[@]}" -eq 0 ]; then
  echo "maestro: no command to exec after '--'" >&2
  exit 64
fi

exec "${EXEC[@]}"
