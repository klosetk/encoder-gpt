"""Automated spot-checks: the CI/CD quality gate.

Invokes a specific Lambda version/alias against labeled cases and fails
(exit 1) if top-1 accuracy is below the threshold. The deploy pipeline uses
this to decide promote vs. rollback.

Usage: python evals/run_evals.py --function encoder-gpt --qualifier <version> [--threshold 0.85]
"""
import argparse
import json
import sys
from pathlib import Path

import boto3


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--function", required=True)
    p.add_argument("--qualifier", required=True)
    p.add_argument("--threshold", type=float, default=0.85)
    a = p.parse_args()

    lam = boto3.client("lambda")
    cases = [json.loads(l) for l in Path(__file__).with_name("cases.jsonl").read_text().splitlines() if l.strip()]
    hits, misses = 0, []

    for c in cases:
        resp = lam.invoke(FunctionName=a.function, Qualifier=a.qualifier,
                          Payload=json.dumps({"description": c["description"]}))
        body = json.loads(json.loads(resp["Payload"].read())["body"])
        top = (body.get("suggestions") or [{}])[0].get("code")
        if top == c["expected"]:
            hits += 1
        else:
            misses.append({"expected": c["expected"], "got": top})

    acc = hits / len(cases)
    print(json.dumps({"accuracy": round(acc, 3), "cases": len(cases), "misses": misses}, indent=2))
    if acc < a.threshold:
        print(f"FAIL: accuracy {acc:.2%} below threshold {a.threshold:.0%}")
        sys.exit(1)
    print("PASS")


if __name__ == "__main__":
    main()
