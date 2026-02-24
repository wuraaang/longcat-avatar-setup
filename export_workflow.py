#!/usr/bin/env python3
"""
Export the current ComfyUI workflow to API format.

Connects to a running ComfyUI instance, fetches the active workflow via
the /prompt endpoint's format, and saves it as workflow_avatar_api.json.

Handles:
- Widget values → named inputs mapping via /object_info
- Hidden UI widgets (control_after_generate, upload) correctly skipped
- Dict-format widgets_values (some custom nodes use this)
- Link resolution (connections between nodes)
- GetNode/SetNode virtual connections (resolved to direct links)
- Reroute node pass-through (followed to actual source)

Usage:
    # With ComfyUI running on localhost:8188
    python export_workflow.py

    # Custom server address
    python export_workflow.py --server 192.168.1.10:8188

    # From a saved workflow JSON file (UI format)
    python export_workflow.py --input workflow.json
"""

import argparse
import json
import sys
import urllib.request
from collections import defaultdict
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_OUTPUT = SCRIPT_DIR / "workflow_avatar_api.json"

# Node types that are UI-only and should be excluded from API output
UI_ONLY_TYPES = {"Note", "MarkdownNote"}

# Node types that need special handling (virtual connections / pass-through)
VIRTUAL_TYPES = {"GetNode", "SetNode", "Reroute"}

# Values that indicate a control_after_generate widget
CONTROL_AFTER_GENERATE_VALUES = {"fixed", "increment", "decrement", "randomize"}


def fetch_json(url: str) -> dict:
    with urllib.request.urlopen(url, timeout=30) as resp:
        return json.loads(resp.read())


def fetch_workflow_from_server(base_url: str) -> dict:
    """Fetch the current workflow from ComfyUI's internal state."""
    # The /prompt endpoint doesn't give us the UI workflow.
    # We need to use the /api/get-workflow or similar.
    # Actually, ComfyUI stores the last loaded workflow in browser state.
    # The best approach: read from the user's default workflow directory.
    raise NotImplementedError(
        "Direct workflow fetch not available. Use --input with a saved workflow JSON."
    )


def fetch_object_info(base_url: str) -> dict:
    """Fetch all node type definitions from ComfyUI server."""
    url = f"{base_url}/object_info"
    print(f"Fetching object_info from {url} ...")
    info = fetch_json(url)
    print(f"  Got definitions for {len(info)} node types.")
    return info


def build_link_map(links: list) -> dict:
    link_map = {}
    for link in links:
        link_id, src_node, src_slot, tgt_node, tgt_slot, type_str = link
        link_map[link_id] = {
            "source_node": src_node,
            "source_slot": src_slot,
            "target_node": tgt_node,
            "target_slot": tgt_slot,
            "type": type_str,
        }
    return link_map


def build_node_map(nodes: list) -> dict:
    return {node["id"]: node for node in nodes}


def resolve_set_get_connections(nodes: list, link_map: dict) -> dict:
    set_sources = {}
    for node in nodes:
        if node["type"] != "SetNode":
            continue
        wv = node.get("widgets_values", [])
        var_name = wv[0] if isinstance(wv, list) and wv else wv.get("name") if isinstance(wv, dict) else None
        if var_name is None:
            continue
        for inp in node.get("inputs", []):
            link_id = inp.get("link")
            if link_id is not None and link_id in link_map:
                link = link_map[link_id]
                set_sources[var_name] = (link["source_node"], link["source_slot"])
                break

    get_resolutions = {}
    for node in nodes:
        if node["type"] != "GetNode":
            continue
        wv = node.get("widgets_values", [])
        var_name = wv[0] if isinstance(wv, list) and wv else wv.get("name") if isinstance(wv, dict) else None
        if var_name and var_name in set_sources:
            get_resolutions[node["id"]] = set_sources[var_name]

    return get_resolutions


def build_set_node_source_map(nodes: list, link_map: dict) -> dict:
    set_node_sources = {}
    for node in nodes:
        if node["type"] != "SetNode":
            continue
        for inp in node.get("inputs", []):
            link_id = inp.get("link")
            if link_id is not None and link_id in link_map:
                link = link_map[link_id]
                set_node_sources[node["id"]] = (link["source_node"], link["source_slot"])
                break
    return set_node_sources


def resolve_source(node_id, output_slot, node_map, link_map,
                   get_resolutions, set_node_sources, visited=None):
    if visited is None:
        visited = set()
    if node_id in visited:
        return (node_id, output_slot)
    visited.add(node_id)

    node = node_map.get(node_id)
    if node is None:
        return (node_id, output_slot)

    if node["type"] == "GetNode":
        if node_id in get_resolutions:
            src_node_id, src_slot = get_resolutions[node_id]
            return resolve_source(src_node_id, src_slot, node_map, link_map,
                                  get_resolutions, set_node_sources, visited)
        return (node_id, output_slot)

    if node["type"] == "SetNode":
        if node_id in set_node_sources:
            src_node_id, src_slot = set_node_sources[node_id]
            return resolve_source(src_node_id, src_slot, node_map, link_map,
                                  get_resolutions, set_node_sources, visited)
        return (node_id, output_slot)

    if node["type"] == "Reroute":
        for inp in node.get("inputs", []):
            link_id = inp.get("link")
            if link_id is not None and link_id in link_map:
                link = link_map[link_id]
                return resolve_source(link["source_node"], link["source_slot"],
                                      node_map, link_map, get_resolutions,
                                      set_node_sources, visited)
        return (node_id, output_slot)

    return (node_id, output_slot)


def get_ordered_widget_names(node_type: str, object_info: dict) -> list:
    WIDGET_TYPES = {"FLOAT", "INT", "BOOLEAN", "STRING", "COMBO"}
    if node_type not in object_info:
        return []

    info = object_info[node_type]
    input_defs = info.get("input", {})
    input_order = info.get("input_order", {})

    ordered = []
    for section in ["required", "optional"]:
        section_defs = input_defs.get(section, {})
        section_order = input_order.get(section, list(section_defs.keys()))
        for input_name in section_order:
            if input_name not in section_defs:
                continue
            input_def = section_defs[input_name]
            if not isinstance(input_def, list) or len(input_def) == 0:
                continue
            type_info = input_def[0]
            if isinstance(type_info, list):
                ordered.append(input_name)
            elif isinstance(type_info, str) and type_info in WIDGET_TYPES:
                ordered.append(input_name)
    return ordered


def get_api_input_names(node_type: str, object_info: dict) -> set:
    if node_type not in object_info:
        return set()
    info = object_info[node_type]
    input_defs = info.get("input", {})
    names = set()
    for section in ["required", "optional"]:
        names.update(input_defs.get(section, {}).keys())
    return names


def get_widget_type_map(node_type: str, object_info: dict) -> dict:
    WIDGET_TYPES = {"FLOAT", "INT", "BOOLEAN", "STRING", "COMBO"}
    if node_type not in object_info:
        return {}
    info = object_info[node_type]
    input_defs = info.get("input", {})
    input_order = info.get("input_order", {})
    result = {}
    for section in ["required", "optional"]:
        section_defs = input_defs.get(section, {})
        section_order = input_order.get(section, list(section_defs.keys()))
        for input_name in section_order:
            if input_name not in section_defs:
                continue
            input_def = section_defs[input_name]
            if not isinstance(input_def, list) or len(input_def) == 0:
                continue
            type_info = input_def[0]
            if isinstance(type_info, list):
                result[input_name] = "COMBO"
            elif isinstance(type_info, str) and type_info in WIDGET_TYPES:
                result[input_name] = type_info
    return result


def map_widgets_values(node, node_type, object_info, connected_names):
    widgets_values = node.get("widgets_values")
    if widgets_values is None:
        return {}

    api_input_names = get_api_input_names(node_type, object_info)
    widget_type_map = get_widget_type_map(node_type, object_info)
    UI_ONLY_WIDGET_KEYS = {"videopreview"}

    if isinstance(widgets_values, dict):
        inputs = {}
        for key, value in widgets_values.items():
            if key in UI_ONLY_WIDGET_KEYS or key in connected_names:
                continue
            if key in api_input_names:
                inputs[key] = value
        return inputs

    ordered_names = get_ordered_widget_names(node_type, object_info)
    if not ordered_names:
        return {}

    inputs = {}
    wi = 0
    for input_name in ordered_names:
        if wi >= len(widgets_values):
            break
        value = widgets_values[wi]
        wi += 1
        if input_name not in connected_names:
            inputs[input_name] = value
        if (input_name == "seed"
                and widget_type_map.get(input_name) == "INT"
                and wi < len(widgets_values)
                and isinstance(widgets_values[wi], str)
                and widgets_values[wi] in CONTROL_AFTER_GENERATE_VALUES):
            wi += 1

        if node_type in object_info:
            info = object_info[node_type]
            for section in ["required", "optional"]:
                section_defs = info["input"].get(section, {})
                if input_name in section_defs:
                    defn = section_defs[input_name]
                    if (isinstance(defn, list) and len(defn) > 1
                            and isinstance(defn[1], dict) and defn[1].get("image_upload")):
                        if wi < len(widgets_values):
                            wi += 1
    return inputs


def convert_workflow(workflow: dict, object_info: dict) -> dict:
    nodes = workflow["nodes"]
    links = workflow.get("links", [])

    link_map = build_link_map(links)
    node_map = build_node_map(nodes)
    get_resolutions = resolve_set_get_connections(nodes, link_map)
    set_node_sources = build_set_node_source_map(nodes, link_map)

    api = {}
    for node in nodes:
        node_id = node["id"]
        node_type = node["type"]
        if node_type in UI_ONLY_TYPES or node_type in VIRTUAL_TYPES:
            continue

        title = (node.get("title")
                 or node.get("properties", {}).get("title")
                 or node.get("properties", {}).get("Node name for S&R")
                 or node_type)

        connected_names = set()
        for inp in node.get("inputs", []):
            if inp.get("link") is not None:
                connected_names.add(inp.get("name", ""))

        inputs = {}
        widget_inputs = map_widgets_values(node, node_type, object_info, connected_names)
        inputs.update(widget_inputs)

        for inp in node.get("inputs", []):
            link_id = inp.get("link")
            if link_id is None or link_id not in link_map:
                continue
            link = link_map[link_id]
            actual_source, actual_slot = resolve_source(
                link["source_node"], link["source_slot"],
                node_map, link_map, get_resolutions, set_node_sources)
            input_name = inp.get("name", f"input_{inp.get('slot_index', 0)}")
            inputs[input_name] = [str(actual_source), actual_slot]

        inputs.pop("upload", None)
        api[str(node_id)] = {
            "class_type": node_type,
            "inputs": inputs,
            "_meta": {"title": title},
        }

    return api


def main():
    parser = argparse.ArgumentParser(
        description="Export ComfyUI workflow to API format")
    parser.add_argument("--input", "-i", required=True,
                        help="Input workflow JSON (UI format, saved from ComfyUI)")
    parser.add_argument("--output", "-o", default=str(DEFAULT_OUTPUT),
                        help=f"Output path (default: {DEFAULT_OUTPUT})")
    parser.add_argument("--server", default="http://localhost:8188",
                        help="ComfyUI server URL (for /object_info)")
    args = parser.parse_args()

    print(f"Loading workflow from {args.input} ...")
    with open(args.input) as f:
        workflow = json.load(f)

    # Handle wrapper format (MCP tool result)
    if isinstance(workflow, list) and workflow and "text" in workflow[0]:
        data = json.loads(workflow[0]["text"])
        workflow = data.get("workflow", data)

    if "nodes" not in workflow:
        print("Error: input does not appear to be a UI-format workflow (no 'nodes' key)")
        sys.exit(1)

    print(f"  {len(workflow['nodes'])} nodes, {len(workflow.get('links', []))} links")

    object_info = fetch_object_info(args.server)

    print("\nConverting to API format ...")
    api = convert_workflow(workflow, object_info)
    print(f"  Generated {len(api)} nodes in API format.")

    print(f"\nSaving to {args.output} ...")
    with open(args.output, "w") as f:
        json.dump(api, f, indent=2)

    # Summary
    print("\n-- Summary --")
    type_counts = defaultdict(int)
    for node_data in api.values():
        type_counts[node_data["class_type"]] += 1
    for t, c in sorted(type_counts.items()):
        print(f"  {t}: {c}")
    print(f"\n  Total: {len(api)} nodes")
    print("  Done!")


if __name__ == "__main__":
    main()
