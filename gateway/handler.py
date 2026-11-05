"""Slack /encode front door for Encoder GPT.

Slack gives a slash command 3 seconds to answer; a Bedrock call can take
longer. So this function answers in two passes:

  1. Slack -> API Gateway -> here: verify Slack's signature, reply "working on it"
     (ephemeral), and re-invoke itself asynchronously.
  2. Async pass: call Encoder GPT's "live" alias, then post the codes back to
     Slack's response_url, visible only to the person who asked.

Security: unsigned or stale requests are rejected before anything costs money.
The note text is never logged and never echoed back into the channel.
Stdlib + boto3 only, so Terraform can zip it with no build step.
"""
import hashlib
import hmac
import json
import logging
import os
import time
import urllib.parse
import urllib.request
from base64 import b64decode

import boto3

log = logging.getLogger()
log.setLevel(logging.INFO)

ENCODER = os.environ.get("ENCODER_FUNCTION", "")          # name:live
SECRET_PARAM = os.environ.get("SLACK_SECRET_PARAM", "")
MAX_CHARS = int(os.environ.get("MAX_CHARS", "1000"))
MAX_SKEW = 300  # seconds; Slack's recommended replay window

_clients = {}
_secret = None


def client(name):
    if name not in _clients:
        _clients[name] = boto3.client(name)
    return _clients[name]


def signing_secret():
    global _secret
    if _secret is None:
        _secret = client("ssm").get_parameter(Name=SECRET_PARAM, WithDecryption=True)["Parameter"]["Value"]
    return _secret


def verify(headers, raw_body, secret, now=None):
    """Slack request signing v0: HMAC-SHA256 over 'v0:{timestamp}:{body}'."""
    ts = headers.get("x-slack-request-timestamp", "")
    sig = headers.get("x-slack-signature", "")
    if not ts.isdigit() or not sig:
        return False
    if abs((now or time.time()) - int(ts)) > MAX_SKEW:
        return False
    expected = "v0=" + hmac.new(secret.encode(), f"v0:{ts}:{raw_body}".encode(), hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, sig)


def reply(body, status=200):
    return {"statusCode": status, "headers": {"content-type": "application/json"}, "body": json.dumps(body)}


def ephemeral(text):
    return reply({"response_type": "ephemeral", "text": text})


USAGE = ("Usage: `/encode <clinical description>`\n"
         "Example: `/encode rolled right ankle playing basketball, ligament sprain, first visit`\n"
         "Use de-identified text. Names, dates, and IDs are redacted anyway.")


def handle_slash(event, context):
    raw = event.get("body") or ""
    if event.get("isBase64Encoded"):
        raw = b64decode(raw).decode()
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}

    if not verify(headers, raw, signing_secret()):
        log.warning(json.dumps({"event": "slack_rejected", "reason": "bad_signature"}))
        return reply({"error": "invalid signature"}, 401)

    form = {k: v[0] for k, v in urllib.parse.parse_qs(raw).items()}
    if form.get("ssl_check"):
        return reply({})
    text = form.get("text", "").strip()
    if not text or text.lower() == "help":
        return ephemeral(USAGE)
    if len(text) > MAX_CHARS:
        return ephemeral(f"That's {len(text)} characters; the limit is {MAX_CHARS}. Trim it to the clinical facts.")

    client("lambda").invoke(
        FunctionName=context.invoked_function_arn,
        InvocationType="Event",
        Payload=json.dumps({"followup": {"text": text, "response_url": form.get("response_url", "")}}),
    )
    log.info(json.dumps({"event": "slack_command", "team": form.get("team_id"), "chars": len(text)}))
    return ephemeral(":hourglass_flowing_sand: Coding that now…")


def format_result(result):
    lines = ["*ICD-10 suggestions*"]
    redacted = result.get("phi_redacted") or []
    if redacted:
        lines[0] += f"  _(redacted before the model: {', '.join(redacted)})_"
    for s in result.get("suggestions", []):
        conf = round(float(s.get("confidence", 0)) * 100)
        lines.append(f"• `{s['code']}` {s.get('description', '')}  *{conf}%*")
        if s.get("rationale"):
            lines.append(f"    _{s['rationale']}_")
    if not result.get("suggestions"):
        lines.append("No confident match in the index.")
    if result.get("needs_human_review"):
        lines.append(":warning: Flagged for human review.")
    lines.append("_Advisory only. A certified coder makes the final call._")
    return "\n".join(lines)


def post(url, payload):
    # Only ever post back to Slack, never to an arbitrary URL from the request.
    if not url.startswith("https://hooks.slack.com/"):
        raise ValueError("unexpected response_url host")
    req = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                 headers={"content-type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=10) as r:  # noqa: S310 (host checked above)
        return r.status


def handle_followup(job):
    started = time.time()
    try:
        resp = client("lambda").invoke(FunctionName=ENCODER,
                                       Payload=json.dumps({"description": job["text"]}))
        out = json.loads(resp["Payload"].read())
        body = json.loads(out.get("body", "{}"))
        ok = out.get("statusCode") == 200
        text = format_result(body) if ok else ":x: Encoder GPT couldn't process that. The on-call agent has the logs."
    except Exception as e:  # report, don't retry (async retries would post duplicates)
        ok, text = False, ":x: Encoder GPT is unavailable right now."
        log.error(json.dumps({"event": "slack_followup_failed", "error_type": type(e).__name__}))
    post(job["response_url"], {"response_type": "ephemeral", "replace_original": True, "text": text})
    log.info(json.dumps({"event": "slack_answered", "ok": ok, "latency_ms": int((time.time() - started) * 1000)}))


def lambda_handler(event, context):
    if "followup" in event:
        return handle_followup(event["followup"])
    return handle_slash(event, context)
