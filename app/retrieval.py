"""Retrieval (the R in RAG).

ICD-10 reference entries are embedded with Amazon Titan and stored as a small
JSON index in S3. At query time we embed the question and rank by cosine
similarity. Small and cheap on purpose: no vector database to run for a
portfolio-sized corpus. Swap for OpenSearch Serverless or Bedrock Knowledge
Bases at scale.
"""
import json
import math
import os

import boto3

EMBED_MODEL = os.environ.get("EMBED_MODEL_ID", "amazon.titan-embed-text-v2:0")
_bedrock = None
_index_cache = None


def _br():
    global _bedrock
    if _bedrock is None:
        _bedrock = boto3.client("bedrock-runtime")
    return _bedrock


def embed(text: str, client=None) -> list[float]:
    client = client or _br()
    resp = client.invoke_model(
        modelId=EMBED_MODEL,
        body=json.dumps({"inputText": text, "dimensions": 512, "normalize": True}),
    )
    return json.loads(resp["body"].read())["embedding"]


def cosine(a: list[float], b: list[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    return dot / (na * nb) if na and nb else 0.0


def load_index(bucket: str, key: str, s3=None) -> list[dict]:
    """Cached across warm Lambda invocations."""
    global _index_cache
    if _index_cache is None:
        s3 = s3 or boto3.client("s3")
        _index_cache = json.loads(s3.get_object(Bucket=bucket, Key=key)["Body"].read())
    return _index_cache


def top_k(query_vec: list[float], index: list[dict], k: int = 5) -> list[dict]:
    scored = [{**e, "score": cosine(query_vec, e["embedding"])} for e in index]
    scored.sort(key=lambda e: e["score"], reverse=True)
    return [{kk: v for kk, v in e.items() if kk != "embedding"} for e in scored[:k]]
