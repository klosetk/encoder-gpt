"""Fast unit tests — no AWS calls, run on every PR."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "app"))

from redaction import redact_phi  # noqa: E402
from retrieval import cosine, top_k  # noqa: E402


class FakeCM:
    def detect_phi(self, Text):
        return {"Entities": [
            {"BeginOffset": 8, "EndOffset": 18, "Type": "NAME", "Score": 0.99},
            {"BeginOffset": 26, "EndOffset": 36, "Type": "DATE", "Score": 0.97},
            {"BeginOffset": 0, "EndOffset": 7, "Type": "ID", "Score": 0.2},  # low confidence, ignored
        ]}


def test_redaction_replaces_phi_spans():
    text = "Patient Jane Smith, DOB 01/02/1980, has diabetes"
    out, types = redact_phi(text, client=FakeCM(), mode="comprehend")
    assert "Jane Smith" not in out and "01/02/1980" not in out
    assert "[NAME]" in out and "[DATE]" in out
    assert types == ["DATE", "NAME"]


def test_basic_redaction_catches_structured_identifiers():
    text = ("Dr. Alan Reed saw pt, MRN: A12345, DOB 01/02/1980, "
            "SSN 123-45-6789, call 512-555-0199 or pt@example.com. Type 2 diabetes.")
    out, types = redact_phi(text, mode="basic")
    for leaked in ["Alan Reed", "A12345", "01/02/1980", "123-45-6789", "512-555-0199", "pt@example.com"]:
        assert leaked not in out
    assert "Type 2 diabetes" in out  # clinical content survives
    assert {"SSN", "PHONE", "EMAIL", "DATE", "NAME"} <= set(types)


def test_basic_redaction_leaves_clean_text_alone():
    text = "Right ankle sprain from basketball, initial encounter"
    assert redact_phi(text, mode="basic") == (text, [])


def test_unknown_mode_fails_loudly():
    import pytest
    with pytest.raises(ValueError):
        redact_phi("x", mode="nope")


def test_cosine_identical_and_orthogonal():
    assert abs(cosine([1, 0], [1, 0]) - 1.0) < 1e-9
    assert cosine([1, 0], [0, 1]) == 0.0
    assert cosine([0, 0], [1, 1]) == 0.0


def test_top_k_ranks_and_strips_embeddings():
    index = [
        {"code": "A", "description": "a", "embedding": [1, 0]},
        {"code": "B", "description": "b", "embedding": [0.7, 0.7]},
        {"code": "C", "description": "c", "embedding": [0, 1]},
    ]
    res = top_k([1, 0], index, k=2)
    assert [r["code"] for r in res] == ["A", "B"]
    assert all("embedding" not in r for r in res)
