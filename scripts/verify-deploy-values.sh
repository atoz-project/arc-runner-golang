#!/usr/bin/env bash
set -euo pipefail

CHART_REF="oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set"
CHART_VERSION="0.14.2"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

helm pull "$CHART_REF" --version "$CHART_VERSION" --untar -d "$TMP_DIR" >/dev/null
CHART_DIR="$TMP_DIR/gha-runner-scale-set"

render_set() {
  local name="$1"
  local values_file="$2"
  helm template "$name" "$CHART_DIR" \
    -n arc-runners \
    -f "$values_file" \
    --set controllerServiceAccount.name=ci-lint \
    --set controllerServiceAccount.namespace=arc-runners \
    > "$TMP_DIR/$name.yaml"
}

render_set arc-runner-set-golang deploy/arc-runner-set-golang.values.yaml
render_set arc-runner-set deploy/arc-runner-set.values.yaml

python3 - "$TMP_DIR/arc-runner-set-golang.yaml" "$TMP_DIR/arc-runner-set.yaml" <<'PY'
import sys
import yaml

def load_runner_set(path: str) -> dict:
    with open(path, encoding="utf-8") as fh:
        docs = [d for d in yaml.safe_load_all(fh) if d and d.get("kind") == "AutoscalingRunnerSet"]
    if len(docs) != 1:
        raise AssertionError(f"{path}: expected 1 AutoscalingRunnerSet, got {len(docs)}")
    return docs[0]

def get_runner_container(pod_spec: dict, path: str) -> dict:
    containers = pod_spec.get("containers") or []
    for c in containers:
        if c.get("name") == "runner":
            return c
    raise AssertionError(f"{path}: missing runner container")

def assert_no_extra_disk(tpl: dict, runner: dict, path: str) -> None:
    anns = (tpl.get("metadata") or {}).get("annotations") or {}
    if "k8s.aliyun.com/eci-extra-ephemeral-storage" in anns:
        raise AssertionError(f"{path}: unexpected eci-extra-ephemeral-storage annotation")
    res = runner.get("resources") or {}
    for bucket in ("requests", "limits"):
        if "ephemeral-storage" in (res.get(bucket) or {}):
            raise AssertionError(f"{path}: unexpected ephemeral-storage in resources.{bucket}")

go_doc = load_runner_set(sys.argv[1])
go_tpl = go_doc["spec"]["template"]
go_spec = go_tpl["spec"]
go_runner = get_runner_container(go_spec, sys.argv[1])

assert (go_spec.get("securityContext") or {}).get("fsGroup") == 1001, "golang: fsGroup must be 1001"
assert go_runner.get("command") == ["/home/runner/run.sh"], f"golang: bad command {go_runner.get('command')}"
assert not str(go_runner.get("image", "")).endswith(":latest"), "golang: image must not use :latest"

mounts = go_runner.get("volumeMounts") or []
if not any(m.get("name") == "cache" and m.get("mountPath") == "/home/runner/.cache" for m in mounts):
    raise AssertionError(f"golang: missing /home/runner/.cache mount in {mounts}")

vols = go_spec.get("volumes") or []
cache_vols = [v for v in vols if v.get("name") == "cache"]
if len(cache_vols) != 1:
    raise AssertionError(f"golang: expected 1 cache volume, got {cache_vols}")
nfs = cache_vols[0].get("nfs") or {}
if not str(nfs.get("server", "")).endswith(".nas.aliyuncs.com") or nfs.get("path") != "/":
    raise AssertionError(f"golang: invalid cache nfs spec {nfs}")

expected_res = {"cpu": "2", "memory": "4Gi"}
for bucket in ("requests", "limits"):
    got = (go_runner.get("resources") or {}).get(bucket)
    if got != expected_res:
        raise AssertionError(f"golang: resources.{bucket} = {got}, want {expected_res}")
assert_no_extra_disk(go_tpl, go_runner, sys.argv[1])

plain_doc = load_runner_set(sys.argv[2])
plain_tpl = plain_doc["spec"]["template"]
plain_spec = plain_tpl["spec"]
plain_runner = get_runner_container(plain_spec, sys.argv[2])

assert plain_runner.get("command") == ["/home/runner/run.sh"], f"plain: bad command {plain_runner.get('command')}"
assert not str(plain_runner.get("image", "")).endswith(":latest"), "plain: image must not use :latest"
assert_no_extra_disk(plain_tpl, plain_runner, sys.argv[2])

print("verify-deploy-values: OK")
PY
