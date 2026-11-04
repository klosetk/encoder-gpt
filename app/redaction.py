"""PHI redaction — a technical control, not a policy.

The original Encoder GPT relied on users not typing PHI. Here every input is
scrubbed *before* it reaches the model. Two interchangeable backends:

  REDACTION_MODE=comprehend  Amazon Comprehend Medical DetectPHI (ML-based,
                             catches names and free-text identifiers). Requires
                             an AWS Paid plan.
  REDACTION_MODE=basic       Pattern matching for structured identifiers
                             (SSNs, phones, emails, dates, MRN-style IDs).
                             No AWS service, $0. Does NOT reliably catch names
                             or addresses — use only for demos, never real PHI.
"""
import os
import re

MIN_SCORE = 0.5
_client = None

# Order matters: more specific patterns first.
BASIC_PATTERNS = [
    ("EMAIL", re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.]+\b")),
    ("SSN", re.compile(r"\b\d{3}-\d{2}-\d{4}\b")),
    ("PHONE", re.compile(r"(?:\+?1[\s.-]?)?\(?\b\d{3}\)?[\s.-]\d{3}[\s.-]\d{4}\b")),
    ("DATE", re.compile(
        r"\b(?:\d{1,2}[/-]\d{1,2}[/-]\d{2,4}|\d{4}-\d{2}-\d{2}|"
        r"(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.? \d{1,2},? \d{4})\b",
        re.IGNORECASE)),
    ("ID", re.compile(r"\b(?:MRN|DOB|acct|account|member\s*id|id)\s*[:#]?\s*[A-Z0-9-]{4,}\b", re.IGNORECASE)),
    ("NAME", re.compile(r"\b(?:Mr|Mrs|Ms|Miss|Dr)\.? [A-Z][a-z]+(?: [A-Z][a-z]+)?")),
]


def _cm():
    global _client
    if _client is None:
        import boto3
        _client = boto3.client("comprehendmedical")
    return _client


def _redact_comprehend(text: str, client) -> tuple[str, list[str]]:
    entities = client.detect_phi(Text=text).get("Entities", [])
    found = []
    # Replace from the end so earlier offsets stay valid.
    for e in sorted(entities, key=lambda x: x["BeginOffset"], reverse=True):
        if e.get("Score", 0) < MIN_SCORE:
            continue
        text = text[: e["BeginOffset"]] + f"[{e['Type']}]" + text[e["EndOffset"]:]
        found.append(e["Type"])
    return text, sorted(set(found))


def _redact_basic(text: str) -> tuple[str, list[str]]:
    found = []
    for label, pattern in BASIC_PATTERNS:
        text, n = pattern.subn(f"[{label}]", text)
        if n:
            found.append(label)
    return text, sorted(set(found))


def redact_phi(text: str, client=None, mode: str | None = None) -> tuple[str, list[str]]:
    """Return (redacted_text, phi_types_found)."""
    mode = mode or os.environ.get("REDACTION_MODE", "comprehend")
    if mode == "basic":
        return _redact_basic(text)
    if mode == "comprehend":
        return _redact_comprehend(text, client or _cm())
    raise ValueError(f"Unknown REDACTION_MODE: {mode}")
