"""Encoder GPT on AWS — Lambda entry point.

Flow: redact PHI -> retrieve candidate codes -> Bedrock reasons over ONLY the
retrieved evidence -> return suggestions with confidence + rationale.
Suggestions are advisory: a certified coder makes the final call.
"""
import json
import logging
import os
import time

import boto3

from redaction import redact_phi
from retrieval import embed, load_index, top_k

log = logging.getLogger()
log.setLevel(logging.INFO)

MODEL_ID = os.environ["MODEL_ID"]
INDEX_BUCKET = os.environ["INDEX_BUCKET"]
INDEX_KEY = os.environ.get("INDEX_KEY", "index/icd10_index.json")

SYSTEM_PROMPT = """You are a medical coding assistant. Suggest ICD-10-CM codes
for the clinical description using ONLY the candidate codes provided.
If none fit, say so — never invent a code.
Respond with JSON only:
{"suggestions": [{"code": "...", "description": "...", "confidence": 0.0-1.0,
"rationale": "..."}], "needs_human_review": true|false}
Set needs_human_review true if confidence < 0.8 or the description is ambiguous."""

_bedrock = None


def _br():
    global _bedrock
    if _bedrock is None:
        _bedrock = boto3.client("bedrock-runtime")
    return _bedrock


def suggest_codes(description: str) -> dict:
    started = time.time()
    clean, phi_types = redact_phi(description)

    candidates = top_k(embed(clean), load_index(INDEX_BUCKET, INDEX_KEY), k=8)
    evidence = "\n".join(f"- {c['code']}: {c['description']}" for c in candidates)

    resp = _br().converse(
        modelId=MODEL_ID,
        system=[{"text": SYSTEM_PROMPT}],
        messages=[{"role": "user", "content": [{"text":
            f"Clinical description:\n{clean}\n\nCandidate codes:\n{evidence}"}]}],
        inferenceConfig={"maxTokens": 800, "temperature": 0},
    )
    raw = resp["output"]["message"]["content"][0]["text"]
    result = json.loads(raw[raw.find("{"): raw.rfind("}") + 1])

    # Guardrail: drop any code the model returned that wasn't retrieved.
    allowed = {c["code"] for c in candidates}
    result["suggestions"] = [s for s in result.get("suggestions", []) if s["code"] in allowed]
    if not result["suggestions"]:
        result["needs_human_review"] = True

    # Structured log -> CloudWatch. No input text logged (defense in depth).
    log.info(json.dumps({
        "event": "suggestion", "latency_ms": int((time.time() - started) * 1000),
        "phi_redacted": phi_types, "n_suggestions": len(result["suggestions"]),
        "needs_review": result.get("needs_human_review"),
        "version": os.environ.get("AWS_LAMBDA_FUNCTION_VERSION"),
    }))
    return {**result, "phi_redacted": phi_types}


def lambda_handler(event, context):
    try:
        body = event.get("body", event)
        if isinstance(body, str):
            body = json.loads(body)
        desc = (body.get("description") or "").strip()
        if not desc:
            return {"statusCode": 400, "body": json.dumps({"error": "description required"})}
        return {"statusCode": 200, "body": json.dumps(suggest_codes(desc))}
    except Exception as e:
        # One structured line with the cause, so diagnosis is a single log query.
        # (AWS error messages name the service and reason; they never contain request text.)
        err = getattr(e, "response", {}).get("Error", {}) if hasattr(e, "response") else {}
        log.error(json.dumps({
            "event": "suggestion_failed",
            "error_type": err.get("Code") or type(e).__name__,
            "error": (err.get("Message") or str(e))[:500],
            "operation": getattr(e, "operation_name", None),
            "version": os.environ.get("AWS_LAMBDA_FUNCTION_VERSION"),
        }))
        log.exception("failure_traceback")  # distinct name so the failure metric counts each error once
        return {"statusCode": 500, "body": json.dumps({"error": "internal error"})}
