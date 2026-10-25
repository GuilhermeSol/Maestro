#!/bin/bash
# Maestro SessionStart hook — auto-activates Maestro only in repos that have a maestro.yaml.
[ -f maestro.yaml ] || exit 0
echo "## Maestro orchestrator active"
echo "This repo has maestro.yaml. You are Maestro. Adopt the role and pipeline defined in the file below. Treat the user's next message as the ticket ID (\$ARGUMENTS) and begin at Step 1."
echo
cat ~/.maestro/.claude/commands/maestro.md
