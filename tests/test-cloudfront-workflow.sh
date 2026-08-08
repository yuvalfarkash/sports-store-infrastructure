#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/cloudfront-common.sh
source "$TEST_ROOT/scripts/cloudfront-common.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

VALID_HOSTNAME="k8s-sportsstore-1234567890.eu-central-1.elb.amazonaws.com"

is_valid_alb_hostname "$VALID_HOSTNAME" || fail "a normal ALB hostname was rejected"
is_valid_alb_hostname "dualstack.$VALID_HOSTNAME" || fail "a dualstack ALB hostname was rejected"

for invalid_hostname in \
  "" \
  "https://$VALID_HOSTNAME" \
  "example.com" \
  "bad host.eu-central-1.elb.amazonaws.com" \
  "-bad.eu-central-1.elb.amazonaws.com" \
  "bad-.eu-central-1.elb.amazonaws.com"; do
  if is_valid_alb_hostname "$invalid_hostname"; then
    fail "invalid hostname passed validation: $invalid_hostname"
  fi
done

for positive_integer in 1 10 900; do
  is_positive_integer "$positive_integer" || fail "positive integer was rejected: $positive_integer"
done

for invalid_integer in 0 -1 1.5 text; do
  if is_positive_integer "$invalid_integer"; then
    fail "invalid positive integer passed validation: $invalid_integer"
  fi
done

kubectl() {
  printf '%s\n' "$VALID_HOSTNAME"
}

sleep() {
  :
}

DISCOVERED_HOSTNAME="$(wait_for_alb_hostname sports-store sports-store 2 1)"
[[ "$DISCOVERED_HOSTNAME" == "$VALID_HOSTNAME" ]] || fail "ALB discovery did not return the validated hostname"

kubectl() {
  return 1
}

if wait_for_alb_hostname sports-store sports-store 2 1 >/dev/null 2>&1; then
  fail "ALB discovery did not fail after its bounded timeout"
fi

kubectl() {
  printf '%s\n' "https://example.com/not-an-alb"
}

if wait_for_alb_hostname sports-store sports-store 2 1 >/dev/null 2>&1; then
  fail "ALB discovery accepted an invalid non-hostname value"
fi

# Sourcing deploy.sh is non-mutating because its main guard does not execute.
# shellcheck source=../deploy.sh
source "$TEST_ROOT/deploy.sh"

TERRAFORM_CALLS=0
terraform() {
  TERRAFORM_CALLS=$((TERRAFORM_CALLS + 1))

  case "$TERRAFORM_CALLS" in
    1)
      [[ "$#" == 3 ]] || fail "Terraform init arguments were split unexpectedly"
      [[ "$1" == "-chdir=$CLOUDFRONT_DIR" && "$2" == "init" && "$3" == "-input=false" ]] ||
        fail "Terraform init arguments were not safely quoted"
      ;;
    2)
      [[ "$#" == 6 ]] || fail "Terraform apply arguments were split unexpectedly"
      [[ "$1" == "-chdir=$CLOUDFRONT_DIR" && "$2" == "apply" ]] ||
        fail "Terraform apply directory or command was incorrect"
      [[ "$5" == "-var=alb_origin_hostname=$VALID_HOSTNAME" ]] ||
        fail "ALB hostname was not passed as one safely quoted Terraform argument"
      [[ "$6" == "-var=aws_region=eu-central-1" ]] ||
        fail "AWS region was not passed as one safely quoted Terraform argument"
      ;;
    *)
      fail "apply_cloudfront made an unexpected Terraform call"
      ;;
  esac
}

apply_cloudfront "$VALID_HOSTNAME" eu-central-1 >/dev/null
[[ "$TERRAFORM_CALLS" == 2 ]] || fail "apply_cloudfront did not make exactly two Terraform calls"

printf 'CloudFront workflow helper tests passed.\n'
