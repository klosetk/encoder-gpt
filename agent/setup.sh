#!/bin/bash
# One-time agent setup. Run on the agent server as ec2-user, AFTER:
#   openclaw onboard --install-daemon
# Safe to re-run (it re-applies config and refreshes tokens).
#
# Usage:  ~/encoder-gpt/agent/setup.sh
set -euo pipefail

source /etc/profile.d/fleet-agent.sh
# Node may come from nvm (boot script) or a nodejs.org tarball in ~/.local/node.
export PATH="$HOME/.local/node/bin:$PATH"
export NVM_DIR="$HOME/.nvm"
if [[ -s "$NVM_DIR/nvm.sh" ]]; then set +u; . "$NVM_DIR/nvm.sh"; set -u; fi   # nvm isn't nounset-safe
command -v openclaw >/dev/null || { echo "!! openclaw not found on PATH - install it first (see agent/README.md)"; exit 1; }

AGENT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARAMS="/encoder-gpt/${FLEET_ENV}/agent"
UNIT="openclaw-gateway.service"

# Every OpenClaw call gets a time limit and no keyboard input, so a hidden
# interactive prompt or a stuck call can never freeze the script.
oc() { timeout 120 openclaw "$@" </dev/null; }

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

param() {  # read an SSM parameter; empty string if it doesn't exist
  aws ssm get-parameter --name "$PARAMS/$1" --with-decryption \
    --query Parameter.Value --output text --no-cli-pager 2>/dev/null || true
}

# ── 0. AWS credentials: use this server's IAM role (no keys) ─────────────────
# OpenClaw can't detect EC2 instance-role credentials on its own, so name a
# profile that sources them from instance metadata, and set AWS_PROFILE below.
mkdir -p "$HOME/.aws"
printf '[default]\nregion = %s\ncredential_source = Ec2InstanceMetadata\n' "$AWS_REGION" > "$HOME/.aws/config"
export AWS_PROFILE=default

# ── 1. Brain: Bedrock via the instance role (no API key) ─────────────────────
say "Configuring Bedrock (instance-role auth)"
# Bedrock support ships as a separate plugin package. Without it, every turn
# fails with "No API provider registered for api: bedrock-converse-stream".
oc plugins install @openclaw/amazon-bedrock-provider || echo "(amazon-bedrock-provider already installed)"
oc plugins enable amazon-bedrock --accept-capabilities || echo "(amazon-bedrock plugin: check 'openclaw plugins list')"
oc config patch --file "$AGENT_DIR/openclaw.bedrock.json5"
oc config set plugins.entries.amazon-bedrock.config.discovery.enabled true
oc config set plugins.entries.amazon-bedrock.config.discovery.region "$AWS_REGION"

# ── 2. Skill: the runbook as something the agent can execute ─────────────────
say "Installing fleet-ops skill"
mkdir -p "$HOME/.openclaw/workspace/skills"
# Copy, don't symlink: OpenClaw rejects skill links that escape its workspace.
rm -rf "$HOME/.openclaw/workspace/skills/fleet-ops"
cp -R "$AGENT_DIR/skills/fleet-ops" "$HOME/.openclaw/workspace/skills/fleet-ops"

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
    printf 'AWS_PROFILE=default\nAWS_REGION=%s\nAWS_DEFAULT_REGION=%s\nFLEET_ENV=%s\n' "$AWS_REGION" "$AWS_REGION" "$FLEET_ENV"
  } > "$HOME/.openclaw/fleet-agent.env"
  umask 022

  mkdir -p "$HOME/.config/systemd/user/$UNIT.d"
  printf '[Service]\nEnvironmentFile=%%h/.openclaw/fleet-agent.env\n' > "$HOME/.config/systemd/user/$UNIT.d/fleet-agent.conf"

  if [[ -n "$PLUGIN" ]]; then
    oc plugins install "$PLUGIN" || echo "($PLUGIN already installed)"
  fi
  oc config patch --file "$AGENT_DIR/channels/$CHANNEL_KIND.json5"
else
  echo "No $CHANNEL_KIND tokens in $PARAMS yet - skipping chat. Add them and re-run (see agent/README.md)."
fi

# ── 4. Restart the gateway with the new config ───────────────────────────────
say "Restarting gateway"
systemctl --user daemon-reload
systemctl --user restart "$UNIT"
systemctl --user --no-pager status "$UNIT" | head -5

# Wait until the gateway actually accepts connections (it can take a minute
# on a small instance) instead of racing it with the next commands.
say "Waiting for the gateway to accept connections"
for i in $(seq 1 36); do
  if bash -c 'exec 3<>/dev/tcp/127.0.0.1/18789' 2>/dev/null; then echo "  gateway ready after $((i*5))s"; break; fi
  sleep 5
  [[ $i == 36 ]] && echo "!! gateway not reachable after 3 minutes - check: journalctl --user -u $UNIT -n 50"
done
sleep 5   # let it finish loading plugins after the port opens

# ── 5. Schedules: proactive checks delivered to the chosen channel ───────────
# Uses systemd timers rather than OpenClaw's built-in scheduler: in this
# OpenClaw release, built-in automations require a stored model account or
# API key, and this agent deliberately has neither (Bedrock auth is the IAM role).
# Each timer runs one agent turn and delivers the reply with --deliver.
if [[ -n "$TARGET" ]]; then
  say "Scheduling health checks and daily digest -> $CHANNEL_KIND (systemd timers)"
  OC_BIN="$(command -v openclaw)"
  NODE_DIR="$(dirname "$(command -v node)")"
  UDIR="$HOME/.config/systemd/user"
  mkdir -p "$UDIR"

  write_job() {  # name, schedule, message
    cat > "$UDIR/fleet-$1.service" <<UNIT
[Unit]
Description=Fleet Ops Agent: $1
After=$UNIT

[Service]
Type=oneshot
EnvironmentFile=%h/.openclaw/fleet-agent.env
Environment=PATH=$NODE_DIR:/usr/local/bin:/usr/bin:/bin
TimeoutStartSec=900
ExecStart=$OC_BIN agent --message "$3" --deliver --reply-channel $CHANNEL_KIND --reply-to $TARGET --thinking low
UNIT
    cat > "$UDIR/fleet-$1.timer" <<UNIT
[Unit]
Description=Schedule for Fleet Ops Agent: $1

[Timer]
OnCalendar=$2
Persistent=false

[Install]
WantedBy=timers.target
UNIT
  }

  write_job health "Mon..Fri 08..18/2:07:00 America/Chicago" \
    "Use the fleet-ops skill. Run the health check. If anything is in ALARM, diagnose and follow the rollback rules, then post the incident report. If healthy, reply with the one-line healthy status only."
  write_job digest "Mon..Fri 08:31:00 America/Chicago" \
    "Use the fleet-ops skill. Post a morning digest for Encoder GPT: current live version, any alarms in the last 24h (from alarm history), and eval accuracy from running the eval suite through live. Keep it under 8 lines."

  systemctl --user daemon-reload
  systemctl --user enable --now fleet-health.timer fleet-digest.timer
  systemctl --user list-timers 'fleet-*' --no-pager | head -5
  echo "  Run one now:  systemctl --user start fleet-health.service"
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
oc models list | grep -i bedrock || echo "!! Bedrock model not listed - check Bedrock access and IAM"
oc skills list | grep -i fleet-ops || echo "!! fleet-ops skill not listed - try: openclaw gateway restart"

say "Done. Try it:"
echo '  openclaw agent --message "Use the fleet-ops skill to run a health check on Encoder GPT."'
