#!/bin/bash
# One-time agent setup. Run on the agent server as ec2-user, AFTER:
#   openclaw onboard --install-daemon
# Safe to re-run (it re-applies config and refreshes tokens).
#
# Usage:  ~/encoder-gpt/agent/setup.sh
set -euo pipefail

source /etc/profile.d/fleet-agent.sh
export NVM_DIR="$HOME/.nvm"
set +u; . "$NVM_DIR/nvm.sh"; set -u   # nvm isn't nounset-safe

AGENT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARAMS="/encoder-gpt/${FLEET_ENV}/agent"
UNIT="openclaw-gateway.service"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

param() {  # read an SSM parameter; empty string if it doesn't exist
  aws ssm get-parameter --name "$PARAMS/$1" --with-decryption \
    --query Parameter.Value --output text --no-cli-pager 2>/dev/null || true
}

# ── 1. Brain: Bedrock via the instance role (no API key) ─────────────────────
say "Configuring Bedrock (instance-role auth)"
openclaw config patch --file "$AGENT_DIR/openclaw.bedrock.json5"
openclaw config set plugins.entries.amazon-bedrock.config.discovery.enabled true
openclaw config set plugins.entries.amazon-bedrock.config.discovery.region "$AWS_REGION"

# ── 2. Skill: the runbook as something the agent can execute ─────────────────
say "Installing fleet-ops skill"
mkdir -p "$HOME/.openclaw/workspace/skills"
ln -sfn "$AGENT_DIR/skills/fleet-ops" "$HOME/.openclaw/workspace/skills/fleet-ops"

# ── 3. Slack: tokens from Parameter Store -> gateway environment ─────────────
BOT=$(param slack-bot-token)
APP=$(param slack-app-token)
CHANNEL=$(param slack-channel-id)

if [[ -n "$BOT" && -n "$APP" ]]; then
  say "Configuring Slack (Socket Mode)"
  umask 077
  printf 'SLACK_BOT_TOKEN=%s\nSLACK_APP_TOKEN=%s\nAWS_REGION=%s\nAWS_DEFAULT_REGION=%s\nFLEET_ENV=%s\n' \
    "$BOT" "$APP" "$AWS_REGION" "$AWS_REGION" "$FLEET_ENV" > "$HOME/.openclaw/fleet-agent.env"
  umask 022

  mkdir -p "$HOME/.config/systemd/user/$UNIT.d"
  cat > "$HOME/.config/systemd/user/$UNIT.d/fleet-agent.conf" <<EOF
[Service]
EnvironmentFile=%h/.openclaw/fleet-agent.env
EOF

  openclaw plugins install @openclaw/slack || echo "(Slack plugin already installed)"
  openclaw config patch --file "$AGENT_DIR/openclaw.slack.json5"
else
  echo "No Slack tokens in $PARAMS yet - skipping Slack. Add them and re-run (see agent/README.md)."
fi

# ── 4. Restart the gateway with the new config ───────────────────────────────
say "Restarting gateway"
systemctl --user daemon-reload
systemctl --user restart "$UNIT"
sleep 5
systemctl --user --no-pager status "$UNIT" | head -5

# ── 5. Schedules: proactive checks delivered to Slack ────────────────────────
if [[ -n "$CHANNEL" && -n "$BOT" ]]; then
  say "Scheduling health checks and daily digest"
  openclaw cron add \
    --name "fleet-health-check" \
    --cron "7 8-18/2 * * 1-5" --tz "America/Chicago" \
    --message "Use the fleet-ops skill. Run the health check. If anything is in ALARM, diagnose and follow the rollback rules, then post the incident report. If healthy, reply with the one-line healthy status only." \
    --announce --channel slack --to "channel:$CHANNEL" || echo "(health check may already exist - see: openclaw cron list)"

  openclaw cron add \
    --name "fleet-daily-digest" \
    --cron "31 8 * * 1-5" --tz "America/Chicago" \
    --message "Use the fleet-ops skill. Post a morning digest for Encoder GPT: current live version, any alarms in the last 24h (from alarm history), and eval accuracy from running the eval suite through live. Keep it under 8 lines." \
    --announce --channel slack --to "channel:$CHANNEL" || echo "(digest may already exist - see: openclaw cron list)"
fi

# ── 6. Verify ────────────────────────────────────────────────────────────────
say "Verifying"
openclaw models list | grep -i bedrock || echo "!! Bedrock model not listed - check Bedrock access and IAM"
openclaw skills list | grep -i fleet-ops || echo "!! fleet-ops skill not listed - try: openclaw gateway restart"

say "Done. Try it:"
echo '  openclaw agent --message "Use the fleet-ops skill to run a health check on Encoder GPT."'
