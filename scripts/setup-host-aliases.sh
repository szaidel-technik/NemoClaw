#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Repair host-local aliases inside the sandbox when Docker Desktop + WSL injects
# stale /etc/hosts entries that do not match the host-side resolution path.
#
# Problem: On some WSL2 + Docker Desktop setups, the sandbox gets
#   host.docker.internal / host.openshell.internal -> 192.168.65.254
# in /etc/hosts, while the working host route from WSL resolves to a different
# Windows host IP. Because /etc/hosts wins over DNS, the sandbox keeps trying
# the stale IP and local-host presets appear broken.
#
# Fix:
#   1. Resolve host.docker.internal on the WSL host.
#   2. Find the OpenShell sandbox network namespace.
#   3. Replace any existing host-local alias lines in /etc/hosts with the
#      host-side IPv4 that WSL already uses successfully.
#
# Usage: ./scripts/setup-host-aliases.sh [gateway-name] <sandbox-name>

set -euo pipefail

GATEWAY_NAME="${1:-}"
SANDBOX_NAME="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/runtime.sh
. "$SCRIPT_DIR/lib/runtime.sh"

if [ -z "$SANDBOX_NAME" ]; then
  echo "Usage: $0 [gateway-name] <sandbox-name>"
  exit 1
fi

is_wsl() {
  [ -n "${WSL_DISTRO_NAME:-}" ] \
    || [ -n "${WSL_INTEROP:-}" ] \
    || grep -qi microsoft /proc/version 2>/dev/null
}

if ! is_wsl; then
  echo "Skipping sandbox host-alias repair: not running under WSL."
  exit 0
fi

if [ -z "${DOCKER_HOST:-}" ]; then
  if docker_host="$(detect_docker_host)"; then
    export DOCKER_HOST="$docker_host"
  fi
fi

RUNTIME="$(docker_host_runtime "${DOCKER_HOST:-}" || true)"
if [ "$RUNTIME" != "docker-desktop" ]; then
  echo "Skipping sandbox host-alias repair: runtime is '${RUNTIME:-unknown}', not docker-desktop."
  exit 0
fi

HOST_ALIAS_IP="$(
  getent ahostsv4 host.docker.internal 2>/dev/null \
    | awk 'NF { print $1; exit }'
)"

if [ -z "$HOST_ALIAS_IP" ]; then
  echo "WARNING: Could not resolve host.docker.internal on the WSL host. Sandbox host aliases not repaired."
  exit 0
fi

if printf '%s' "$HOST_ALIAS_IP" | grep -qE '^127\.'; then
  echo "WARNING: host.docker.internal resolved to loopback (${HOST_ALIAS_IP}); refusing to rewrite sandbox aliases."
  exit 0
fi

if [ -z "${DOCKER_HOST:-}" ]; then
  if docker_host="$(detect_docker_host)"; then
    export DOCKER_HOST="$docker_host"
  fi
fi

CLUSTERS="$(docker ps --filter "name=openshell-cluster" --format '{{.Names}}' 2>/dev/null || true)"
CLUSTER="$(select_openshell_cluster_container "$GATEWAY_NAME" "$CLUSTERS" || true)"

if [ -z "$CLUSTER" ]; then
  if [ -n "$GATEWAY_NAME" ]; then
    echo "WARNING: Could not find gateway container for '$GATEWAY_NAME'. Sandbox host aliases not repaired."
  else
    echo "WARNING: Could not find any openshell cluster container. Sandbox host aliases not repaired."
  fi
  exit 1
fi

kctl() {
  docker exec "$CLUSTER" kubectl "$@"
}

POD="$(kctl get pods -n openshell -o name 2>/dev/null \
  | grep -F -- "$SANDBOX_NAME" | head -1 | sed 's|pod/||' || true)"

if [ -z "$POD" ]; then
  echo "WARNING: Could not find pod for sandbox '$SANDBOX_NAME'. Sandbox host aliases not repaired."
  exit 1
fi

SANDBOX_NS="$(kctl exec -n openshell "$POD" -- sh -c \
  "ls /run/netns/ 2>/dev/null | grep sandbox | head -1" 2>/dev/null || true)"

if [ -z "$SANDBOX_NS" ]; then
  echo "WARNING: Could not find sandbox network namespace. Sandbox host aliases not repaired."
  exit 1
fi

sb_exec() {
  kctl exec -n openshell "$POD" -- ip netns exec "$SANDBOX_NS" "$@"
}

CURRENT_HOSTS="$(sb_exec getent hosts host.docker.internal host.openshell.internal 2>/dev/null || true)"
if printf '%s\n' "$CURRENT_HOSTS" | grep -q "^${HOST_ALIAS_IP}[[:space:]].*host.docker.internal"; then
  echo "  [PASS] Sandbox host aliases already resolve to ${HOST_ALIAS_IP}"
  exit 0
fi

echo "Repairing sandbox host aliases in pod '$POD' (${CURRENT_HOSTS:-unresolved} -> ${HOST_ALIAS_IP})..."

sb_exec sh -c "
  [ -f /tmp/hosts.orig ] || cp /etc/hosts /tmp/hosts.orig
  awk '!/(host\\.docker\\.internal|host\\.openshell\\.internal)/' /etc/hosts > /tmp/hosts.nemoclaw
  printf '%s host.docker.internal host.openshell.internal\n' '$HOST_ALIAS_IP' >> /tmp/hosts.nemoclaw
  cat /tmp/hosts.nemoclaw > /etc/hosts
"

VERIFY_HOSTS="$(sb_exec getent hosts host.docker.internal host.openshell.internal 2>/dev/null || true)"
if printf '%s\n' "$VERIFY_HOSTS" | grep -q "^${HOST_ALIAS_IP}[[:space:]].*host.docker.internal"; then
  echo "  [PASS] Sandbox host aliases repaired -> ${HOST_ALIAS_IP}"
else
  echo "  [FAIL] Sandbox host aliases still do not resolve to ${HOST_ALIAS_IP}: ${VERIFY_HOSTS:-unresolved}"
  exit 1
fi
