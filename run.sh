#!/usr/bin/env bash
# run.sh — Deploy VPC Lattice Client-Server Communication and run tests.
# Usage: bash run.sh <output_json_path>
# All logging goes to stderr. The output JSON path receives the execution report.
set -euo pipefail

OUTPUT_JSON="${1:-/tmp/execution_report.json}"
UNIT_REPORT="/tmp/unit_results.json"
INTEG_REPORT="/tmp/integ_results.json"
TF_DIR="/app/solution"

log() { echo "[$(date -u +%FT%TZ)] $*" >&2; }

# ---------------------------------------------------------------------------
# Wait for LocalStack
# ---------------------------------------------------------------------------
wait_for_localstack() {
  log "Waiting for LocalStack at ${AWS_ENDPOINT_URL:-http://localhost:4566}..."
  local endpoint="${AWS_ENDPOINT_URL:-http://localhost:4566}"
  for i in $(seq 1 90); do
    if curl -sf "${endpoint}/_localstack/health" 2>/dev/null | grep -q '"ec2"'; then
      log "LocalStack is ready (attempt $i)"
      return 0
    fi
    sleep 2
  done
  log "ERROR: LocalStack did not become ready within 180s"
  exit 1
}

wait_for_localstack

# ---------------------------------------------------------------------------
# Lint: terraform fmt -check
# ---------------------------------------------------------------------------
log "=== LINT: terraform fmt -check ==="
FMT_EXIT=0
FMT_OUTPUT=$(terraform fmt -check -recursive -no-color "$TF_DIR" 2>&1) || FMT_EXIT=$?
if [ $FMT_EXIT -ne 0 ]; then
  log "terraform fmt check FAILED: $FMT_OUTPUT"
  LINT_STATUS="FAIL"
  LINT_ERRORS=1
else
  log "terraform fmt check PASSED"
  LINT_STATUS="PASS"
  LINT_ERRORS=0
fi

# ---------------------------------------------------------------------------
# Build: terraform init + validate
# ---------------------------------------------------------------------------
log "=== BUILD: terraform init ==="
cd "$TF_DIR"
BUILD_STATUS="PASS"
INIT_EXIT=0
terraform init -no-color -input=false >&2 || INIT_EXIT=$?
if [ $INIT_EXIT -ne 0 ]; then
  log "terraform init FAILED"
  BUILD_STATUS="FAIL"
fi

if [ "$BUILD_STATUS" = "PASS" ]; then
  log "=== BUILD: terraform validate ==="
  VALIDATE_EXIT=0
  terraform validate -no-color >&2 || VALIDATE_EXIT=$?
  if [ $VALIDATE_EXIT -ne 0 ]; then
    log "terraform validate FAILED"
    BUILD_STATUS="FAIL"
  else
    log "terraform validate PASSED"
  fi
fi

# ---------------------------------------------------------------------------
# Unit tests (pytest — static analysis of .tf files)
# ---------------------------------------------------------------------------
log "=== UNIT TESTS ==="
UNIT_EXIT=0
python3 -m pytest "$TF_DIR/tests/unit_tests.py" \
  -v \
  --json-report \
  --json-report-file="$UNIT_REPORT" \
  -p no:cacheprovider \
  --tb=short \
  >&2 || UNIT_EXIT=$?
log "Unit test exit code: $UNIT_EXIT"

# ---------------------------------------------------------------------------
# Deploy: terraform apply
# ---------------------------------------------------------------------------
log "=== DEPLOY: terraform apply ==="
DEPLOY_STATUS="PASS"
APPLY_EXIT=0
terraform apply -auto-approve -no-color >&2 || APPLY_EXIT=$?
if [ $APPLY_EXIT -ne 0 ]; then
  log "terraform apply FAILED"
  DEPLOY_STATUS="FAIL"
else
  log "terraform apply PASSED"
fi

# ---------------------------------------------------------------------------
# Integration tests (pytest + boto3 against LocalStack)
# ---------------------------------------------------------------------------
log "=== INTEGRATION TESTS ==="
INTEG_EXIT=0
python3 -m pytest "$TF_DIR/tests/integration_tests.py" \
  -v \
  --json-report \
  --json-report-file="$INTEG_REPORT" \
  -p no:cacheprovider \
  --tb=short \
  >&2 || INTEG_EXIT=$?
log "Integration test exit code: $INTEG_EXIT"

# ---------------------------------------------------------------------------
# Aggregate results into JSON report
# ---------------------------------------------------------------------------
log "=== Generating execution report ==="

export _UNIT_REPORT="$UNIT_REPORT"
export _INTEG_REPORT="$INTEG_REPORT"
export _OUTPUT_JSON="$OUTPUT_JSON"
export _LINT_STATUS="$LINT_STATUS"
export _LINT_ERRORS="$LINT_ERRORS"
export _BUILD_STATUS="$BUILD_STATUS"
export _DEPLOY_STATUS="$DEPLOY_STATUS"

python3 - <<'PYEOF'
import json, sys, os

def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}

unit_data     = load_json(os.environ["_UNIT_REPORT"])
integ_data    = load_json(os.environ["_INTEG_REPORT"])
output_path   = os.environ["_OUTPUT_JSON"]
lint_status   = os.environ["_LINT_STATUS"]
lint_errors   = int(os.environ["_LINT_ERRORS"])
build_status  = os.environ["_BUILD_STATUS"]
deploy_status = os.environ["_DEPLOY_STATUS"]

def parse_pytest_report(data):
    tests  = data.get("tests", [])
    summary = data.get("summary", {})
    total  = summary.get("total", len(tests))
    passed = summary.get("passed", 0)
    failed_names = []
    for t in tests:
        outcome = t.get("outcome", "")
        if outcome in ("failed", "error"):
            failed_names.append(t.get("nodeid", "unknown"))
    if total == 0:
        return "FAIL", 0, 0, [], 0.0
    if len(failed_names) == 0 and total > 0:
        return "PASS", total, total - len(failed_names), failed_names, 100.0
    pass_rate = round(100.0 * passed / total, 2)
    return "FAIL", total, passed, failed_names, pass_rate

u_status, u_run, u_passed, u_failed, u_rate = parse_pytest_report(unit_data)
i_status, i_run, i_passed, i_failed, i_rate = parse_pytest_report(integ_data)

overall = (
    "PASS"
    if all(s == "PASS" for s in [lint_status, build_status, u_status, deploy_status, i_status])
    else "FAIL"
)

report = {
    "overall_status":              overall,
    "build_status":                build_status,
    "lint_status":                 lint_status,
    "lint_errors":                 lint_errors,
    "unit_tests_status":           u_status,
    "unit_tests_run":              u_run,
    "unit_tests_passed":           u_passed,
    "unit_tests_failed":           u_failed,
    "unit_tests_pass_rate":        u_rate,
    "coverage_lines":              0.0,
    "coverage_branches":           0.0,
    "coverage_statements":         0.0,
    "deploy_status":               deploy_status,
    "integration_status":          i_status,
    "integration_tests_run":       i_run,
    "integration_tests_passed":    i_passed,
    "integration_tests_failed":    i_failed,
    "integration_tests_pass_rate": i_rate,
}

with open(output_path, "w") as f:
    json.dump(report, f, indent=2)
print(f"Report written to {output_path}", file=sys.stderr)
print(json.dumps(report, indent=2), file=sys.stderr)
PYEOF

log "Done."
exit 0
