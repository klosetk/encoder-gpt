#!/bin/bash
# Chaos test: simulate a bad deploy so you can watch the Fleet Ops Agent
# catch it and roll back. Run from CloudShell (with your admin credentials,
# NOT the agent's). Great for recording a demo video.
#
#   scripts/chaos.sh dev
#
# What it does:
#   1. Publishes a new version whose model ID is deliberately invalid
#   2. Points "live" at it (as if a broken deploy slipped through)
#   3. Restores $LATEST so future real deploys aren't affected
#   4. Sends traffic so the failure alarm fires
set -euo pipefail
ENV="${1:-dev}"
FN="encoder-gpt-$ENV"
export AWS_PAGER=""

GOOD=$(aws lambda get-alias --function-name "$FN" --name live --query FunctionVersion --output text)
ORIG_ENV=$(aws lambda get-function-configuration --function-name "$FN" --query Environment)
BAD_ENV=$(echo "$ORIG_ENV" | jq '.Variables.MODEL_ID = "anthropic.does-not-exist-v1:0"')

echo "Current healthy version: $GOOD"
echo "Publishing a broken version..."
aws lambda update-function-configuration --function-name "$FN" --environment "$BAD_ENV" >/dev/null
aws lambda wait function-updated --function-name "$FN"
BAD=$(aws lambda publish-version --function-name "$FN" --description "chaos-test: invalid model id" --query Version --output text)

echo "Pointing live at broken version $BAD..."
aws lambda update-alias --function-name "$FN" --name live --function-version "$BAD" --routing-config '{}' >/dev/null

echo "Restoring \$LATEST configuration..."
aws lambda update-function-configuration --function-name "$FN" --environment "$ORIG_ENV" >/dev/null
aws lambda wait function-updated --function-name "$FN"

echo "Sending traffic..."
for i in 1 2 3 4 5; do
  aws lambda invoke --function-name "$FN" --qualifier live \
    --cli-binary-format raw-in-base64-out \
    --payload '{"description":"Follow-up for essential hypertension"}' /tmp/chaos-$i.json >/dev/null
  echo "  request $i -> $(jq -r .statusCode /tmp/chaos-$i.json)"
done

cat <<EOF

Broken version $BAD is live; healthy version is $GOOD.
The failure alarm should fire within ~2 minutes. Then, in Slack, ask the agent:
  "@Fleet Ops Encoder GPT is failing - diagnose and fix it"
(or wait for its scheduled health check).

Manual undo if needed:
  aws lambda update-alias --function-name $FN --name live --function-version $GOOD --routing-config '{}'
EOF
