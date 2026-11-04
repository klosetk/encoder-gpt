"""Embed the ICD-10 reference set and upload the index to S3.

Usage: python scripts/build_index.py --bucket <index-bucket> [--csv data/icd10_sample.csv]
Re-run every October when CMS publishes the new ICD-10-CM code set.
"""
import argparse
import csv
import json
import sys
from pathlib import Path

import boto3

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "app"))
from retrieval import embed  # noqa: E402


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--bucket", required=True)
    p.add_argument("--key", default="index/icd10_index.json")
    p.add_argument("--csv", default="data/icd10_sample.csv")
    a = p.parse_args()

    with open(a.csv, newline="") as f:
        rows = list(csv.DictReader(f))

    index = [{**r, "embedding": embed(f"{r['code']} {r['description']}")} for r in rows]
    boto3.client("s3").put_object(
        Bucket=a.bucket, Key=a.key, Body=json.dumps(index).encode(),
        ContentType="application/json", ServerSideEncryption="AES256",
    )
    print(f"Indexed {len(index)} codes -> s3://{a.bucket}/{a.key}")


if __name__ == "__main__":
    main()
