#!/usr/bin/env bash

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_valid_alb_hostname() {
  local hostname="$1"

  (( ${#hostname} <= 253 )) &&
    [[ "$hostname" =~ ^([[:alnum:]]([[:alnum:]-]*[[:alnum:]])?\.)+elb\.amazonaws\.com$ ]]
}

wait_for_kubernetes_object() {
  local resource_type="$1"
  local resource_name="$2"
  local namespace="$3"
  local timeout_seconds="$4"
  local poll_seconds="$5"
  local max_attempts=$(( (timeout_seconds + poll_seconds - 1) / poll_seconds ))
  local attempt

  for (( attempt = 1; attempt <= max_attempts; attempt++ )); do
    if kubectl get "$resource_type" "$resource_name" --namespace "$namespace" >/dev/null 2>&1; then
      return 0
    fi

    if (( attempt < max_attempts )); then
      printf 'Waiting for %s/%s in namespace %s... (%d/%d)\n' \
        "$resource_type" "$resource_name" "$namespace" "$attempt" "$max_attempts" >&2
      sleep "$poll_seconds"
    fi
  done

  printf 'ERROR: %s/%s did not appear in namespace %s within %s seconds.\n' \
    "$resource_type" "$resource_name" "$namespace" "$timeout_seconds" >&2
  return 1
}

wait_for_alb_hostname() {
  local ingress_name="$1"
  local namespace="$2"
  local timeout_seconds="$3"
  local poll_seconds="$4"
  local max_attempts=$(( (timeout_seconds + poll_seconds - 1) / poll_seconds ))
  local attempt
  local hostname

  for (( attempt = 1; attempt <= max_attempts; attempt++ )); do
    hostname="$(kubectl get ingress "$ingress_name" \
      --namespace "$namespace" \
      --output jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    hostname="${hostname//$'\r'/}"
    hostname="${hostname//$'\n'/}"

    if [[ -n "$hostname" ]]; then
      if ! is_valid_alb_hostname "$hostname"; then
        printf 'ERROR: Ingress %s/%s returned an invalid ALB hostname: %q\n' \
          "$namespace" "$ingress_name" "$hostname" >&2
        return 1
      fi

      printf '%s\n' "$hostname"
      return 0
    fi

    if (( attempt < max_attempts )); then
      printf 'Waiting for an ALB hostname on Ingress %s/%s... (%d/%d)\n' \
        "$namespace" "$ingress_name" "$attempt" "$max_attempts" >&2
      sleep "$poll_seconds"
    fi
  done

  printf 'ERROR: Ingress %s/%s had no ALB hostname after %s seconds.\n' \
    "$namespace" "$ingress_name" "$timeout_seconds" >&2
  return 1
}
