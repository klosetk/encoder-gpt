"""Slack front door: signature checks and formatting. No AWS or Slack calls."""
import hashlib
import hmac
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "gateway"))

import handler  # noqa: E402

SECRET = "test-secret"


def sign(body, ts):
    return "v0=" + hmac.new(SECRET.encode(), f"v0:{ts}:{body}".encode(), hashlib.sha256).hexdigest()


def headers(body, ts=None):
    ts = str(int(ts or time.time()))
    return {"x-slack-request-timestamp": ts, "x-slack-signature": sign(body, ts)}


def test_valid_signature_passes():
    body = "text=ankle+sprain"
    assert handler.verify(headers(body), body, SECRET)


def test_tampered_body_fails():
    assert not handler.verify(headers("text=ankle+sprain"), "text=something+else", SECRET)


def test_replayed_request_fails():
    body = "text=ankle+sprain"
    old = time.time() - 600
    assert not handler.verify(headers(body, old), body, SECRET)


def test_missing_headers_fail():
    assert not handler.verify({}, "text=x", SECRET)


def test_unsigned_request_rejected_before_any_work(monkeypatch):
    monkeypatch.setattr(handler, "signing_secret", lambda: SECRET)
    monkeypatch.setattr(handler, "client", lambda name: (_ for _ in ()).throw(AssertionError("no AWS calls")))
    out = handler.handle_slash({"body": "text=x", "headers": {}}, None)
    assert out["statusCode"] == 401


def test_format_never_echoes_input_and_flags_review():
    msg = handler.format_result({
        "suggestions": [{"code": "S93.401A", "description": "Sprain of right ankle ligament",
                         "confidence": 0.62, "rationale": "Inversion injury"}],
        "needs_human_review": True, "phi_redacted": ["NAME"],
    })
    assert "`S93.401A`" in msg and "62%" in msg and "human review" in msg and "NAME" in msg


def test_post_refuses_non_slack_urls():
    try:
        handler.post("https://evil.example.com/x", {})
    except ValueError:
        return
    raise AssertionError("posted to a non-Slack host")
