"""PHI redaction — a technical control, not a policy.

The original Encoder GPT relied on users not typing PHI. Here every input is
scrubbed by Amazon Comprehend Medical *before* it reaches the model.
"""
import boto3

_client = None
MIN_SCORE = 0.5


def _cm():
    global _client
    if _client is None:
        _client = boto3.client("comprehendmedical")
    return _client


def redact_phi(text: str, client=None) -> tuple[str, list[str]]:
    """Return (redacted_text, phi_types_found). Replaces spans with [TYPE]."""
    client = client or _cm()
    entities = client.detect_phi(Text=text).get("Entities", [])
    found = []
    # Replace from the end so earlier offsets stay valid.
    for e in sorted(entities, key=lambda x: x["BeginOffset"], reverse=True):
        if e.get("Score", 0) < MIN_SCORE:
            continue
        text = text[: e["BeginOffset"]] + f"[{e['Type']}]" + text[e["EndOffset"]:]
        found.append(e["Type"])
    return text, sorted(set(found))
