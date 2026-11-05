#!/bin/bash
# Record real answers from the live service for the portfolio's "Try it" demo.
# The portfolio replays these, so public visitors never trigger AWS usage.
# Run once from CloudShell: about 6 Bedrock calls (a few cents of credits).
#
#   scripts/record_demo.sh dev > demo-samples.json
#
# The PHI in the sample below is invented, to show redaction working.
set -euo pipefail
ENV="${1:-dev}"
FN="encoder-gpt-$ENV"
export AWS_PAGER=""

SAMPLES=(
  "Rolled right ankle playing basketball yesterday, ligament sprain, first visit"
  "Mr. John Carter, DOB 03/14/1975, MRN A55821, follow-up for type 2 diabetes, A1c stable, no complications"
  "Follow-up for high blood pressure, primary hypertension, on lisinopril"
  "Rear-ended in car accident, neck strain/whiplash, initial evaluation"
  "Burning and frequency with urination, UTI, site not specified"
  "Headache and some chest tightness after a long run, resolved with rest"
)

echo "["
for i in "${!SAMPLES[@]}"; do
  desc="${SAMPLES[$i]}"
  payload=$(jq -cn --arg d "$desc" '{description: $d}')
  aws lambda invoke --function-name "$FN" --qualifier live \
    --cli-binary-format raw-in-base64-out --payload "$payload" /tmp/demo-$i.json >/dev/null
  result=$(jq -c '.body | fromjson' /tmp/demo-$i.json)
  sep=$([ "$i" -lt $((${#SAMPLES[@]} - 1)) ] && echo "," || echo "")
  jq -cn --arg d "$desc" --argjson r "$result" '{description: $d, result: $r}'
  echo "$sep"
  echo "recorded $((i + 1))/${#SAMPLES[@]}" >&2
done
echo "]"
