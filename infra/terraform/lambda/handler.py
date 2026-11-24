"""CloudWatch Logs subscription -> S3 (JSON Lines, gzip)."""
import base64
import gzip
import json
import os
import time

import boto3

s3 = boto3.client("s3")
BUCKET = os.environ["BUCKET"]


def handler(event, context):
    payload = json.loads(gzip.decompress(base64.b64decode(event["awslogs"]["data"])))

    if payload.get("messageType") != "DATA_MESSAGE":
        return {"skipped": True}

    lines = [
        json.dumps(
            {
                "timestamp": e["timestamp"],
                "logGroup": payload["logGroup"],
                "logStream": payload["logStream"],
                "message": e["message"],
            }
        )
        for e in payload["logEvents"]
    ]

    now = time.gmtime()
    key = time.strftime("logs/%Y/%m/%d/%H%M%S-", now) + context.aws_request_id + ".jsonl.gz"

    s3.put_object(
        Bucket=BUCKET,
        Key=key,
        Body=gzip.compress(("\n".join(lines) + "\n").encode()),
        ContentType="application/x-ndjson",
        ContentEncoding="gzip",
    )
    return {"written": len(lines), "key": key}
