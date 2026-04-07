#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Repair host-local aliases inside the sandbox when Docker Desktop + WSL injects
# stale /etc/hosts entries that do not match the host-side resolution path.
#
# Problem:
#   On some WSL2 + Docker Desktop setups, the sandbox gets
#   host.docker.internal / host.openshell.internal -> 192.168.65.254
#   in /etc/hosts, while the working host route from WSL resolves to a
#   different Windows host IP. Because /etc/hosts wins over DNS, the sandbox
#   keeps trying the stale IP and local-host presets appear broken.
#
#   Even after rewriting the aliases to the working Windows host IP, direct TCP
#   from the isolated sandbox namespace can still be refused. The sandbox does,
#   however, reliably reach the pod-side gateway IP (10.200.0.1).
#
# Fix:
#   1. Resolve host.docker.internal on the WSL host.
#   2. Find the OpenShell sandbox pod and network namespace.
#   3. Run a pod-side TCP forwarder on the sandbox gateway IP (10.200.0.1:8765)
#      that relays traffic to the resolved Windows host IP:8765.
#   4. Allow TCP to that gateway IP:port in the sandbox namespace.
#   5. Rewrite host-local aliases in /etc/hosts to point at the gateway IP.
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
if [ "$RUNTIME" = "unknown" ] || [ -z "$RUNTIME" ]; then
  DOCKER_INFO="$(docker info 2>/dev/null || true)"
  case "$(printf '%s' "$DOCKER_INFO" | tr '[:upper:]' '[:lower:]')" in
    *"docker desktop"*)
      RUNTIME="docker-desktop"
      ;;
    *colima*)
      RUNTIME="colima"
      ;;
    *docker*)
      RUNTIME="docker"
      ;;
    *podman*)
      RUNTIME="podman"
      ;;
  esac
fi
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

VETH_GW="$(kctl exec -n openshell "$POD" -- sh -c \
  "ip addr show | grep 'inet 10\\.200\\.0\\.' | awk '{print \$2}' | cut -d/ -f1" \
  2>/dev/null || true)"
VETH_GW="${VETH_GW:-10.200.0.1}"

sb_exec() {
  kctl exec -n openshell "$POD" -- ip netns exec "$SANDBOX_NS" "$@"
}

CURRENT_HOSTS="$(sb_exec getent hosts host.docker.internal host.openshell.internal 2>/dev/null || true)"
echo "Repairing sandbox host aliases in pod '$POD' (${CURRENT_HOSTS:-unresolved} -> ${VETH_GW}; upstream ${HOST_ALIAS_IP}:8765)..."

kctl exec -n openshell "$POD" -- sh -c "cat > /tmp/host-port-proxy.py << 'HOSTPROXY'
import os
import socket
import sys
import threading

UPSTREAM_HOST = sys.argv[1]
UPSTREAM_PORT = int(sys.argv[2])
BIND_IP = sys.argv[3]
BIND_PORT = int(sys.argv[4])

listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind((BIND_IP, BIND_PORT))
listener.listen(128)

with open('/tmp/host-port-proxy.pid', 'w') as pf:
    pf.write(str(os.getpid()))

msg = f'host-port-proxy: {BIND_IP}:{BIND_PORT} -> {UPSTREAM_HOST}:{UPSTREAM_PORT} pid={os.getpid()}'
print(msg, flush=True)
with open('/tmp/host-port-proxy.log', 'w') as log:
    log.write(msg + '\n')

def pump(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except Exception:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except Exception:
            pass
        try:
            src.close()
        except Exception:
            pass
        try:
            dst.close()
        except Exception:
            pass

while True:
    client, _ = listener.accept()
    try:
        upstream = socket.create_connection((UPSTREAM_HOST, UPSTREAM_PORT), timeout=5)
    except Exception:
        try:
            client.close()
        except Exception:
            pass
        continue
    threading.Thread(target=pump, args=(client, upstream), daemon=True).start()
    threading.Thread(target=pump, args=(upstream, client), daemon=True).start()
HOSTPROXY"

OLD_PID="$(kctl exec -n openshell "$POD" -- cat /tmp/host-port-proxy.pid 2>/dev/null || true)"
if [ -n "$OLD_PID" ]; then
  kctl exec -n openshell "$POD" -- kill "$OLD_PID" 2>/dev/null || true
  sleep 1
fi

kctl exec -n openshell "$POD" -- \
  sh -c "nohup python3 -u /tmp/host-port-proxy.py '${HOST_ALIAS_IP}' '8765' '${VETH_GW}' '8765' \
    > /tmp/host-port-proxy.log 2>&1 &"

sleep 2

IPTABLES_BIN=""
for candidate in iptables /sbin/iptables /usr/sbin/iptables; do
  if kctl exec -n openshell "$POD" -- sh -c "test -x \"\$(command -v $candidate 2>/dev/null || echo $candidate)\"" 2>/dev/null; then
    IPTABLES_BIN="$candidate"
    break
  fi
done

if [ -z "$IPTABLES_BIN" ]; then
  echo "WARNING: iptables not found in pod. Sandbox host aliases not repaired."
  exit 1
fi

sb_exec "$IPTABLES_BIN" -C OUTPUT -p tcp -d "$VETH_GW" --dport 8765 -j ACCEPT 2>/dev/null \
  || sb_exec "$IPTABLES_BIN" -I OUTPUT 1 -p tcp -d "$VETH_GW" --dport 8765 -j ACCEPT

sb_exec sh -c "
  [ -f /tmp/hosts.orig ] || cp /etc/hosts /tmp/hosts.orig
  awk '!/(host\\.docker\\.internal|host\\.openshell\\.internal)/' /etc/hosts > /tmp/hosts.nemoclaw
  printf '%s host.docker.internal host.openshell.internal\n' '$VETH_GW' >> /tmp/hosts.nemoclaw
  cat /tmp/hosts.nemoclaw > /etc/hosts
"

VERIFY_HOSTS="$(sb_exec getent hosts host.docker.internal host.openshell.internal 2>/dev/null || true)"
PROXY_PID="$(kctl exec -n openshell "$POD" -- cat /tmp/host-port-proxy.pid 2>/dev/null || true)"
PROXY_LOG="$(kctl exec -n openshell "$POD" -- cat /tmp/host-port-proxy.log 2>/dev/null || true)"

if printf '%s\n' "$VERIFY_HOSTS" | grep -q "^${VETH_GW}[[:space:]].*host.docker.internal" \
  && [ -n "$PROXY_PID" ] \
  && printf '%s' "$PROXY_LOG" | grep -q "host-port-proxy:"; then
  echo "  [PASS] Sandbox host aliases repaired -> ${VETH_GW} (forwarding to ${HOST_ALIAS_IP}:8765)"
else
  echo "  [FAIL] Sandbox host aliases still do not resolve to ${VETH_GW}: ${VERIFY_HOSTS:-unresolved}"
  exit 1
fi
