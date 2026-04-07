// SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
// SPDX-License-Identifier: Apache-2.0

import { describe, it, expect } from "vitest";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";

const SETUP_HOST_ALIASES = path.join(import.meta.dirname, "..", "scripts", "setup-host-aliases.sh");
const RUNTIME_SH = path.join(import.meta.dirname, "..", "scripts", "lib", "runtime.sh");

describe("setup-host-aliases.sh", () => {
  it("exists and is executable", () => {
    const stat = fs.statSync(SETUP_HOST_ALIASES);
    expect(stat.isFile()).toBe(true);
    expect(stat.mode & 0o100).toBeTruthy();
  });

  it("sources runtime.sh successfully", () => {
    const result = spawnSync("bash", ["-c", `source "${RUNTIME_SH}"; echo ok`], {
      encoding: /** @type {const} */ ("utf-8"),
      env: { ...process.env },
    });
    expect(result.status).toBe(0);
    expect(result.stdout.trim()).toBe("ok");
  });

  it("exits with usage when no sandbox name provided", () => {
    const result = spawnSync("bash", [SETUP_HOST_ALIASES, "nemoclaw"], {
      encoding: /** @type {const} */ ("utf-8"),
      env: { ...process.env },
    });
    expect(result.status).not.toBe(0);
    expect(result.stderr + result.stdout).toMatch(/Usage:/i);
  });

  it("repairs /etc/hosts using host.docker.internal resolution from WSL", () => {
    const content = fs.readFileSync(SETUP_HOST_ALIASES, "utf-8");
    expect(content).toContain("getent ahostsv4 host.docker.internal");
    expect(content).toContain("/etc/hosts");
    expect(content).toContain("host.docker.internal host.openshell.internal");
  });

  it("backs up hosts before rewriting sandbox aliases", () => {
    const content = fs.readFileSync(SETUP_HOST_ALIASES, "utf-8");
    expect(content).toContain("hosts.orig");
    expect(content).toContain("cp /etc/hosts /tmp/hosts.orig");
    expect(content).toContain("hosts.nemoclaw");
  });

  it("only targets WSL with Docker Desktop", () => {
    const content = fs.readFileSync(SETUP_HOST_ALIASES, "utf-8");
    expect(content).toContain("is_wsl");
    expect(content).toContain("docker_host_runtime");
    expect(content).toContain("docker-desktop");
  });

  it("runs a pod-side TCP forwarder on the sandbox gateway IP", () => {
    const content = fs.readFileSync(SETUP_HOST_ALIASES, "utf-8");
    expect(content).toContain("host-port-proxy.py");
    expect(content).toContain("socket.SOCK_STREAM");
    expect(content).toContain("VETH_GW");
    expect(content).toContain("8765");
  });

  it("adds an iptables TCP allow rule for the forwarded host-local port", () => {
    const content = fs.readFileSync(SETUP_HOST_ALIASES, "utf-8");
    expect(content).toContain("-p tcp");
    expect(content).toContain("--dport 8765");
    expect(content).toContain("ACCEPT");
  });
});
