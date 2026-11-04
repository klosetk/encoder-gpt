# Runbook: diagnosing Encoder GPT failures

Work from the outside in. At each layer, confirm it's healthy before moving down.

## 1. Is it broken, and since when?
- CloudWatch alarm `encoder-gpt-<env>-errors` state and history
- **What changed?** `aws lambda get-alias --function-name encoder-gpt-<env> --name live`, then check that version's description (commit SHA) and recent Terraform applies
- **Fastest mitigation:** if it started with a deploy, roll back first and investigate after:
  `aws lambda update-alias --function-name encoder-gpt-<env> --name live --function-version <previous> --routing-config '{}'`

## 2. Runtime
- Logs: `aws logs tail /aws/lambda/encoder-gpt-<env> --since 30m`
- Timeouts → X-Ray trace shows which call is slow (Comprehend, embedding, or model)
- Throttles → `encoder-gpt-<env>-throttles` alarm; reserved concurrency is 10
- Image won't start → check the ECR image exists and was built for `linux/amd64`

## 3. Permissions and IAM
- `AccessDeniedException` names the missing action. Check `infra/iam.tf`
- Bedrock `AccessDenied` with correct IAM → model access not enabled in the Bedrock console, or the model ID/inference profile changed
- CI can't deploy → OIDC trust: repo name in `github_repo` must match exactly

## 4. Integrations
- **Bedrock:** `ValidationException` on model ID → confirm the current ID in the console and update `var.model_id`
- **Comprehend Medical:** check service availability in the region
- **S3 index:** `NoSuchKey` → rerun `scripts/build_index.py`

## 5. Quality regressions (no errors, wrong answers)
- `NeedsHumanReview` metric spiking → retrieval or model drift
- Run the eval suite against `live`: `python evals/run_evals.py --function encoder-gpt-<env> --qualifier live`
- Misses cluster around one code family → the index is missing or stale (ICD-10 updates every October)

## 6. Terraform
- `terraform plan` shows unexpected changes → **drift**: someone changed something in the console. Reconcile in code, never by hand
- State lock stuck → confirm no apply is running, then `terraform force-unlock <id>`
- Lost or corrupted state → restore the previous version from the versioned state bucket

## After it's fixed
- Verify with the eval suite through `live`
- Add a test case or alarm so this failure is caught earlier next time
- Update this runbook
