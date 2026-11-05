# Fleet Ops Agent

A persistent [OpenClaw](https://docs.openclaw.ai) agent that runs 24/7 on AWS and **operates Encoder GPT**: it watches alarms, diagnoses failures with the runbook, rolls back bad deploys, and reports in your chat app (Slack, Telegram, or Discord), with email alerts on the side.

```mermaid
flowchart LR
    S[Slack · Telegram · Discord] <-->|outbound only| A[OpenClaw gateway<br/>EC2 Graviton]
    A -->|reasons with| B[Bedrock Claude]
    A -->|reads| CW[CloudWatch alarms + logs]
    A -->|runs evals| L[Encoder GPT Lambda]
    A -->|ONE write: move 'live' alias| L
    R[EC2 health alarms] -->|auto-recover / reboot| A
```

## Design decisions

| Concern | Decision |
|---|---|
| **Access boundary** | The skill says what the agent *should* do; IAM decides what it *can* do. Read-only everywhere, plus one write (`lambda:UpdateAlias` on `live`). An explicit Deny blocks code changes, IAM, and S3 writes even if the role is widened later. Prompt injection can't grant permissions the role doesn't have. |
| **Credentials** | No AWS keys anywhere: Bedrock and AWS APIs use the instance role. Chat tokens live in SSM Parameter Store (SecureString) and reach the gateway as environment variables at runtime, never in config files or git. |
| **Network** | Zero inbound ports. Every chat platform connects outbound (Slack Socket Mode, Telegram long polling, Discord gateway), and admin access is Session Manager, so there are no SSH keys. A public IP provides outbound internet without a $32/month NAT gateway. |
| **Recovery** | EC2 auto-recovers on host failure and reboots on instance failure; the gateway is a systemd service that restarts on crash. |
| **Judgment** | Rollback rules are explicit: only for a *recent deploy* while the failure alarm is firing. For IAM, model access, or index problems, rollback won't help, so the agent reports the human fix instead. |
| **Cost** | Off by default. t4g.medium ≈ $24/month of credits while running (t4g.small stalled under OpenClaw). Stop the instance between demos. |

## Notification channels

Two layers, chosen in `infra/terraform.tfvars`. Switching platforms is a config change, not new code.

| Layer | Setting | Options | Cost |
|---|---|---|---|
| **Alerts** (one-way: something broke) | `alarm_email` | Email via Amazon SNS | Free tier: 1,000 emails/month |
| **Agent chat** (two-way: digests, questions, incident reports) | `agent_channel` | `slack`, `telegram`, `discord` | All free |

**Microsoft Teams** is supported by OpenClaw through a plugin, but custom bots need a Microsoft 365 business tenant and an Azure bot registration, so it isn't configured here. The pattern is the same: a token in Parameter Store, a file in `channels/`, and a case in `setup.sh`.

## Setup

**Prereqs:** Encoder GPT deployed (see the main README) and Bedrock working in your account.

### 1. Pick a platform and create the bot

<details>
<summary><b>Slack</b> (looks like a real workplace; free workspace is fine)</summary>

1. [api.slack.com/apps](https://api.slack.com/apps/new) → **Create New App** → **From a manifest** → pick your workspace → paste the manifest from [OpenClaw's Slack setup page](https://docs.openclaw.ai/channels/slack/setup) (Minimal is fine).
2. **Basic Information → App-Level Tokens → Generate**, add scope `connections:write` → copy the `xapp-…` token.
3. **Install App → Install to Workspace** → copy the `xoxb-…` bot token.
4. Create a channel such as `#fleet-ops`, invite the bot (`/invite @YourBot`), and copy the channel ID (channel name → *About* → bottom of the panel).

```bash
P=/encoder-gpt/dev/agent
aws ssm put-parameter --name $P/slack-bot-token  --type SecureString --value 'xoxb-...'
aws ssm put-parameter --name $P/slack-app-token  --type SecureString --value 'xapp-...'
aws ssm put-parameter --name $P/slack-channel-id --type String       --value 'C0123456789'
```
</details>

<details>
<summary><b>Telegram</b> (fastest setup: one token)</summary>

1. In Telegram, message **@BotFather** → `/newbot` → follow the prompts → copy the bot token.
2. Get your chat ID: message your new bot once, then open `https://api.telegram.org/bot<TOKEN>/getUpdates` and copy `chat.id`. (Group IDs start with `-100`.)

```bash
P=/encoder-gpt/dev/agent
aws ssm put-parameter --name $P/telegram-bot-token --type SecureString --value '123456:ABC...'
aws ssm put-parameter --name $P/telegram-chat-id   --type String       --value '123456789'
```
Set `agent_channel = "telegram"`. After setup, approve yourself: `openclaw pairing list telegram`, then `openclaw pairing approve telegram <CODE>`.
</details>

<details>
<summary><b>Discord</b> (free server and bot)</summary>

1. [discord.com/developers/applications](https://discord.com/developers/applications) → **New Application** → **Bot** → **Reset Token** → copy it.
2. Same page: turn on **Message Content Intent**.
3. **OAuth2 → URL Generator**: scopes `bot` and `applications.commands`; permissions View Channels, Send Messages, Read Message History, Embed Links. Open the URL and add the bot to your server.
4. Discord **Settings → Advanced → Developer Mode** on, then right-click your channel → **Copy Channel ID**.

```bash
P=/encoder-gpt/dev/agent
aws ssm put-parameter --name $P/discord-bot-token  --type SecureString --value '...'
aws ssm put-parameter --name $P/discord-channel-id --type String       --value '123456789012345678'
```
Set `agent_channel = "discord"`.
</details>

### 2. Turn the agent on
In `infra/terraform.tfvars` set `enable_fleet_agent = true` and your `agent_channel`, then:
```bash
cd infra && terraform apply
```
Wait about 5 minutes for the boot script to install Node and OpenClaw.

### 3. Connect and finish setup
```bash
$(terraform output -raw agent_connect_command)   # opens a shell on the agent
sudo -iu ec2-user
tail -3 /var/log/fleet-agent-bootstrap.log        # should say BOOTSTRAP COMPLETE
openclaw onboard --install-daemon                 # interactive; skip model/channel steps, setup.sh handles them
~/encoder-gpt/agent/setup.sh
```
**Switching platforms later:** change `agent_channel`, store that platform's tokens, run `terraform apply`, then re-run `setup.sh` on the agent.

### 4. Test it
```bash
openclaw agent --message "Use the fleet-ops skill to run a health check on Encoder GPT."
```
Then in your chat app, message the bot: *"Is Encoder GPT healthy?"*

### 5. The demo: catch a bad deploy
From CloudShell (your credentials, not the agent's):
```bash
scripts/chaos.sh dev
```
This puts a deliberately broken version live. Within a couple of minutes the alarm fires; ask the agent to investigate, and watch it find the bad version, roll back, verify with evals, and report. **Record this.**

## Stop / start to save credits
```bash
aws ec2 stop-instances  --instance-ids $(terraform -chdir=infra output -raw agent_instance_id)
aws ec2 start-instances --instance-ids $(terraform -chdir=infra output -raw agent_instance_id)
```

## Notes
- OpenClaw evolves quickly. If a CLI flag in `setup.sh` has changed, check `openclaw <command> --help` and the [docs](https://docs.openclaw.ai).
- Scheduled checks run every 2 hours on weekdays (8am–6pm Central), plus a digest at 8:31am. Edit with `openclaw cron list`.
