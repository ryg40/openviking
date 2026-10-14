#!/usr/bin/env python3
"""Build the architecture explorer: one model, one template, one value file.

The model holds placeholders such as {{host.public_url}}; the value file fills them.
The build fails when a placeholder has no value or when a value is not used.
The generator reads the model, the template and the value file only.
See docs/architecture.md.

  python3 -I docs/scripts/build-architecture.py \\
    --values docs/architecture/values.public.json --out docs/architecture.html
"""

import argparse
import html
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MODEL = ROOT / "docs" / "architecture" / "model.json"
TEMPLATE = ROOT / "docs" / "architecture" / "template.html"
PLACEHOLDER = re.compile(r"\{\{\s*([A-Za-z0-9_.-]+)\s*\}\}")
MODEL_MARK = "@@MODEL_JSON@@"
TITLE_MARK = "@@TITLE@@"


class BuildError(Exception):
    pass


def refuse_runtime_file(path):
    # The runtime files hold credentials. A value file is never one of them.
    resolved = path.resolve()
    if resolved.name.startswith(".env") or resolved.name in ("ov.conf", "ovcli.conf"):
        raise BuildError(f"refused: {path} is a runtime configuration file")
    for parent in resolved.parents:
        # data/ beside compose.yaml is the state directory of a checkout.
        if parent.name == "data" and (parent.parent / "compose.yaml").is_file():
            raise BuildError(f"refused: {path} is under the runtime state directory")


def load_json(path, what):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise BuildError(f"cannot read {what} {path}: {error.strerror}") from None
    except json.JSONDecodeError as error:
        raise BuildError(f"{what} {path}: invalid JSON at line {error.lineno}") from None


def load_values(path):
    refuse_runtime_file(path)
    raw = load_json(path, "value file")
    if not isinstance(raw, dict) or not raw:
        raise BuildError(f"value file {path}: expected a non-empty JSON object")
    values = {}
    for key, entry in raw.items():
        # An entry is a string, or an object with "value" and the "source" it comes from.
        value = entry.get("value") if isinstance(entry, dict) else entry
        if not isinstance(value, str):
            raise BuildError(f"value file {path}: {key} has no string value")
        if PLACEHOLDER.search(value):
            raise BuildError(f"value file {path}: {key} holds a placeholder")
        values[key] = value
    return values


def fill(node, values, used, missing, where="model"):
    if isinstance(node, dict):
        return {k: fill(v, values, used, missing, f"{where}.{k}") for k, v in node.items()}
    if isinstance(node, list):
        return [fill(v, values, used, missing, f"{where}[{i}]") for i, v in enumerate(node)]
    if not isinstance(node, str):
        return node

    def replace(match):
        key = match[1]
        if key not in values:
            missing.setdefault(key, where)
            return match[0]
        used.add(key)
        return values[key]

    return PLACEHOLDER.sub(replace, node)


def check_model(model):
    errors = []
    groups = model.get("groups", {})
    edge_types = model.get("edge_types", {})
    views = model.get("views", [])
    nodes_of = {}
    for view in views:
        vid = view.get("id")
        if vid in nodes_of:
            errors.append(f"view {vid}: duplicate id")
        if view.get("type") == "flow":
            nodes_of[vid] = None
            continue
        ids = [n.get("id") for n in view.get("nodes", [])]
        if len(ids) != len(set(ids)):
            errors.append(f"view {vid}: duplicate node id")
        nodes_of[vid] = set(ids)
        layout = view.get("layout", {})
        placed = {g for row in layout.get("rows", [layout.get("columns", [])]) for col in row for g in col}
        for node in view.get("nodes", []):
            if node.get("group") not in groups:
                errors.append(f"view {vid}: node {node.get('id')} has unknown group")
            elif node["group"] not in placed:
                errors.append(f"view {vid}: group {node['group']} is not in the layout")
            if not node.get("summary"):
                errors.append(f"view {vid}: node {node.get('id')} has no summary")
        for edge in view.get("edges", []):
            for end in ("from", "to"):
                if edge.get(end) not in nodes_of[vid]:
                    errors.append(f"view {vid}: edge end {edge.get(end)} is not a node")
            if edge.get("type") not in edge_types:
                errors.append(f"view {vid}: edge type {edge.get('type')} is unknown")
    flows_of = {}
    for view in views:
        if view.get("type") != "flow":
            continue
        base = nodes_of.get(view.get("base"))
        if not base:
            errors.append(f"view {view.get('id')}: base view is missing")
            continue
        flows_of[view["id"]] = {f.get("id") for f in view.get("flows", [])}
        if not view.get("flows"):
            errors.append(f"view {view.get('id')}: no flow")
        for flow in view.get("flows", []):
            if not flow.get("steps"):
                errors.append(f"flow {flow.get('id')}: no step")
            for step in flow.get("steps", []):
                if step.get("node") not in base:
                    errors.append(f"flow {flow.get('id')}: step node {step.get('node')} is missing")
    # A drill target and a tour stop name a view, and optionally a node or a flow in it.
    targets = [(f"node {n.get('id')}: drill", n["drill"]) for v in views for n in v.get("nodes", []) if n.get("drill")]
    targets += [(f"tour stop {i}", stop) for i, stop in enumerate(model.get("tour", []), 1)]
    for where, target in targets:
        if target.get("view") not in nodes_of:
            errors.append(f"{where}: view is missing")
            continue
        if target.get("node") and target["node"] not in (nodes_of[target["view"]] or ()):
            errors.append(f"{where}: node is missing")
        if target.get("flow") and target["flow"] not in flows_of.get(target["view"], ()):
            errors.append(f"{where}: flow is missing")
    if errors:
        raise BuildError("model errors:\n  " + "\n  ".join(errors))


def build(model_path, template_path, values_path):
    values = load_values(values_path)
    used, missing = set(), {}
    model = fill(load_json(model_path, "model"), values, used, missing)
    try:
        template = template_path.read_text(encoding="utf-8")
    except OSError as error:
        raise BuildError(f"cannot read template {template_path}: {error.strerror}") from None
    problems = [f"placeholder {{{{{k}}}}} has no value (first use: {w})" for k, w in missing.items()]
    problems += [f"value {k} is not used" for k in sorted(set(values) - used)]
    if problems:
        raise BuildError(f"value file {values_path}:\n  " + "\n  ".join(problems))
    check_model(model)
    if template.count(MODEL_MARK) != 1 or template.count(TITLE_MARK) != 1:
        raise BuildError(f"template {template_path}: each mark must occur once")
    # One short line for each value keeps line-based checks local; "<" never closes the script.
    data = json.dumps(model, ensure_ascii=False, indent=1).replace("<", "\\u003c")
    title = html.escape(f"{model['meta']['title']} ({model['meta']['build']})")
    return template.replace(TITLE_MARK, title).replace(MODEL_MARK, data)


def main():
    parser = argparse.ArgumentParser(description="Build the architecture explorer HTML file.")
    parser.add_argument("--values", required=True, type=Path, help="value file (JSON)")
    parser.add_argument("--out", required=True, type=Path, help="HTML file to write")
    parser.add_argument("--model", type=Path, default=MODEL, help="topology model (JSON)")
    parser.add_argument("--template", type=Path, default=TEMPLATE, help="HTML template")
    parser.add_argument("--check", action="store_true", help="compare with --out; write nothing")
    args = parser.parse_args()
    try:
        output = build(args.model, args.template, args.values)
    except BuildError as error:
        print(f"build-architecture: {error}", file=sys.stderr)
        return 1
    if args.check:
        current = args.out.read_text(encoding="utf-8") if args.out.exists() else None
        if current != output:
            print(f"build-architecture: {args.out} is not current; rebuild it", file=sys.stderr)
            return 1
        return 0
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(output, encoding="utf-8")
    print(f"build-architecture: wrote {args.out} ({len(output.encode())} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
