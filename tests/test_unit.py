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
    out, types = redact_phi(text, client=FakeCM())
    assert "Jane Smith" not in out and "01/02/1980" not in out
    assert "[NAME]" in out and "[DATE]" in out
    assert types == ["DATE", "NAME"]


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
