#!/usr/bin/env python3
"""
Idempotently set cluster-autoscaler scale-down timing flags (demo-friendly).

Upstream defaults are often ~10m for --scale-down-unneeded-time and
--scale-down-delay-after-add. This script strips any existing values for those
flags and appends the ones from the environment.

Defaults (~2m) speed up demo scale-down without going as extreme as sub-minute
values, which can create extra churn (see kubernetes/autoscaler issue #6213).

Env:
  SCALE_DOWN_UNNEEDED_TIME   (default 2m)  — node must be unneeded this long before removal
  SCALE_DOWN_DELAY_AFTER_ADD (default 2m)  — wait after scale-up before scale-down
  CA_NAMESPACE               (default kube-system)
  CA_DEPLOY_NAME             — if unset, discover a Deployment running cluster-autoscaler
  CA_CONTAINER_INDEX         — if set (0-based), use this container in the Deployment
"""
from __future__ import annotations

import json
import os
import subprocess
import sys


STRIP_PREFIXES = (
    "--scale-down-unneeded-time=",
    "--scale-down-delay-after-add=",
)


def kubectl(argv: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["kubectl", *argv],
        check=True,
        capture_output=True,
        text=True,
    )


def kubectl_json(argv: list[str]) -> dict:
    out = kubectl(argv + ["-o", "json"])
    return json.loads(out.stdout)


def container_score(name: str, c: dict) -> int:
    img = (c.get("image") or "").lower()
    score = 0
    if name == "cluster-autoscaler":
        score += 10
    if "cluster-autoscaler" in img and "controller" not in img:
        score += 5
    args = c.get("args") or []
    if any((a or "").startswith("--cloud-provider=") for a in args):
        score += 1
    return score


def pick_container_index(containers: list[dict], deploy_name: str) -> int:
    best_i = 0
    best_s = -1
    for i, c in enumerate(containers):
        s = container_score(deploy_name, c)
        if s > best_s:
            best_s = s
            best_i = i
    if best_s <= 0:
        return 0
    return best_i


def find_autoscaler_deploy(ns: str) -> tuple[str, int]:
    data = kubectl_json(["get", "deploy", "-n", ns])
    best: tuple[str, int] | None = None
    best_score = -1
    for item in data.get("items") or []:
        name = item["metadata"]["name"]
        containers = item["spec"]["template"]["spec"]["containers"]
        for i, c in enumerate(containers):
            s = container_score(name, c)
            if s > best_score:
                best_score = s
                best = (name, i)
    if best is None or best_score <= 0:
        sys.stderr.write(
            f"No cluster-autoscaler Deployment found in namespace {ns!r}.\n"
            "Set CA_DEPLOY_NAME / CA_CONTAINER_INDEX if yours differs.\n"
        )
        sys.exit(1)
    return best


def write_github_output(key: str, value: str) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(f"{key}={value}\n")


def main() -> None:
    ns = os.environ.get("CA_NAMESPACE", "kube-system")
    deploy_override = os.environ.get("CA_DEPLOY_NAME", "").strip()

    unneeded = os.environ.get("SCALE_DOWN_UNNEEDED_TIME", "2m").strip()
    after_add = os.environ.get("SCALE_DOWN_DELAY_AFTER_ADD", "2m").strip()
    if not unneeded or not after_add:
        sys.stderr.write("SCALE_DOWN_UNNEEDED_TIME and SCALE_DOWN_DELAY_AFTER_ADD must be non-empty.\n")
        sys.exit(1)

    if deploy_override:
        deploy = deploy_override
        dep = kubectl_json(["get", "deploy", deploy, "-n", ns])
        containers = dep["spec"]["template"]["spec"]["containers"]
        cidx_env = os.environ.get("CA_CONTAINER_INDEX", "").strip()
        if cidx_env != "":
            cidx = int(cidx_env)
        else:
            cidx = pick_container_index(containers, deploy)
    else:
        deploy, cidx = find_autoscaler_deploy(ns)
        print(f"Using Deployment {deploy!r} container index {cidx} in namespace {ns!r}")
        dep = kubectl_json(["get", "deploy", deploy, "-n", ns])
        containers = dep["spec"]["template"]["spec"]["containers"]

    old_args = list(containers[cidx].get("args") or [])
    new_args = [a for a in old_args if not a.startswith(STRIP_PREFIXES)]
    new_args.append(f"--scale-down-unneeded-time={unneeded}")
    new_args.append(f"--scale-down-delay-after-add={after_add}")

    write_github_output("ca_deploy_name", deploy)

    if new_args == old_args:
        print("cluster-autoscaler args already match desired scale-down flags; nothing to do.")
        return

    patch = [{"op": "replace", "path": f"/spec/template/spec/containers/{cidx}/args", "value": new_args}]
    p = subprocess.run(
        [
            "kubectl",
            "patch",
            "deployment",
            deploy,
            "-n",
            ns,
            "--type=json",
            "-p",
            json.dumps(patch),
        ],
        capture_output=True,
        text=True,
    )
    if p.returncode != 0:
        sys.stderr.write(p.stderr or p.stdout or "kubectl patch failed\n")
        sys.exit(p.returncode)
    print(p.stdout)
    print(
        f"Patched {deploy}/{ns}: scale-down-unneeded-time={unneeded}, "
        f"scale-down-delay-after-add={after_add}"
    )


if __name__ == "__main__":
    main()
