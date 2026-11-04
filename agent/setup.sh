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

# ── 3. Chat channel: chosen in Terraform (var.agent_channel), tokens from Parameter Store
# Supported: slack | telegram | discord. Email alerts are separate (SNS, var.alarm_email).
CHANNEL_KIND=$(param channel); CHANNEL_KIND=${CHANNEL_KIND:-slack}
TARGET=""; READY=0; PLUGIN=""; TOKENS=()
say "Chat channel: $CHANNEL_KIND"

case "$CHANNEL_KIND" in
  slack)
    BOT=$(param slack-bot-token); APP=$(param slack-app-token); ID=$(param slack-channel-id)
    if [[ -n "$BOT" && -n "$APP" ]]; then
      TOKENS=("SLACK_BOT_TOKEN=$BOT" "SLACK_APP_TOKEN=$APP"); READY=1
      [[ -n "$ID" ]] && TARGET="channel:$ID"
    fi
    PLUGIN="@openclaw/slack" ;;
  telegram)
    BOT=$(param telegram-bot-token); ID=$(param telegram-chat-id)
    if [[ -n "$BOT" ]]; then
      TOKENS=("TELEGRAM_BOT_TOKEN=$BOT"); READY=1
      [[ -n "$ID" ]] && TARGET="$ID"
    fi ;;            # Telegram ships with OpenClaw core: no plugin
  discord)
    BOT=$(param discord-bot-token); ID=$(param discord-channel-id)
    if [[ -n "$BOT" ]]; then
      TOKENS=("DISCORD_BOT_TOKEN=$BOT"); READY=1
      [[ -n "$ID" ]] && TARGET="channel:$ID"
    fi
    PLUGIN="@openclaw/discord" ;;
  *)
    echo "!! Unknown channel '$CHANNEL_KIND' (expected slack, telegram, or discord)"; exit 1 ;;
esac

if [[ "$READY" == 1 ]]; then
  say "Configuring $CHANNEL_KIND"
  umask 077   # token file readable by this user only
  {
    printf '%s\n' "${TOKENS[@]}"
    printf 'AWS_REGION=%s\nAWS_DEFAULT_REGION=%s\nFLEET_ENV=%s\n' "$AWS_REGION" "$AWS_REGION" "$FLEET_ENV"
  } > "$HOME/.openclaw/fleet-agent.env"
  umask 022

  mkdir -p "$HOME/.config/systemd/user/$UNIT.d"
  printf '[Service]\nEnvironmentFile=%%h/.openclaw/fleet-agent.env\n' > "$HOME/.config/systemd/user/$UNIT.d/fleet-agent.conf"

  if [[ -n "$PLUGIN" ]]; then
    openclaw plugins install "$PLUGIN" || echo "($PLUGIN already installed)"
  fi
  openclaw config patch --file "$AGENT_DIR/channels/$CHANNEL_KIND.json5"
else
  echo "No $CHANNEL_KIND tokens in $PARAMS yet - skipping chat. Add them and re-run (see agent/README.md)."
fi

# ── 4. Restart the gateway with the new config ───────────────────────────────
say "Restarting gateway"
systemctl --user daemon-reload
systemctl --user restart "$UNIT"
sleep 5
systemctl --user --no-pager status "$UNIT" | head -5

# ── 5. Schedules: proactive checks delivered to the chosen channel ───────────
if [[ -n "$TARGET" ]]; then
  say "Scheduling health checks and daily digest -> $CHANNEL_KIND"
  openclaw cron add \
    --name "fleet-health-check" \
    --cron "7 8-18/2 * * 1-5" --tz "America/Chicago" \
    --message "Use the fleet-ops skill. Run the health check. If anything is in ALARM, diagnose and follow the rollback rules, then post the incident report. If healthy, reply with the one-line healthy status only." \
    --announce --channel "$CHANNEL_KIND" --to "$TARGET" || echo "(health check may already exist - see: openclaw cron list)"

  openclaw cron add \
    --name "fleet-daily-digest" \
    --cron "31 8 * * 1-5" --tz "America/Chicago" \
    --message "Use the fleet-ops skill. Post a morning digest for Encoder GPT: current live version, any alarms in the last 24h (from alarm history), and eval accuracy from running the eval suite through live. Keep it under 8 lines." \
    --announce --channel "$CHANNEL_KIND" --to "$TARGET" || echo "(digest may already exist - see: openclaw cron list)"
else
  echo "No channel/chat ID stored - skipping schedules. You can still chat with the agent directly."
fi

if [[ "$CHANNEL_KIND" == "telegram" && "$READY" == 1 ]]; then
  echo
  echo "Telegram pairing: send your bot any message, then approve it here:"
  echo "  openclaw pairing list telegram"
  echo "  openclaw pairing approve telegram <CODE>"
fi

# ── 6. Verify ────────────────────────────────────────────────────────────────
say "Verifying"
openclaw models list | grep -i bedrock || echo "!! Bedrock model not listed - check Bedrock access and IAM"
openclaw skills list | grep -i fleet-ops || echo "!! fleet-ops skill not listed - try: openclaw gateway restart"

say "Done. Try it:"
echo '  openclaw agent --message "Use the fleet-ops skill to run a health check on Encoder GPT."'
