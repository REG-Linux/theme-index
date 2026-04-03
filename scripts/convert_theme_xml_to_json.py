#!/usr/bin/env python3
# XML-to-JSON theme converter for REG-ES

import argparse
import json
import os
import sys
import xml.etree.ElementTree as ET


FILTER_KEYS = {
    "if",
    "lang",
    "region",
    "tinyScreen",
    "verticalScreen",
    "ifHelpPrompts",
    "ifCheevos",
    "ifArch",
    "ifNotArch",
    "ifSubset",
}


def load_schema(schema_path):
    with open(schema_path, "r", encoding="utf-8") as handle:
        data = json.load(handle)

    elements = {}
    for element in data.get("elements", []):
        elements[element["name"]] = {prop["name"] for prop in element.get("properties", [])}

    aliases = {alias["alias"]: alias["target"] for alias in data.get("element_aliases", [])}
    base_classes = {item["type"]: item["base"] for item in data.get("base_classes", [])}

    return {"elements": elements, "aliases": aliases, "base_classes": base_classes}


def resolve_element_type(tag, schema):
    return schema["aliases"].get(tag, tag)


def collect_properties(element_type, schema):
    properties = set()
    current = resolve_element_type(element_type, schema)
    visited = set()
    while current and current not in visited:
        visited.add(current)
        properties.update(schema["elements"].get(current, set()))
        current = schema["base_classes"].get(current)
    return properties


def is_element_tag(tag, schema):
    resolved = resolve_element_type(tag, schema)
    return resolved in schema["elements"]


def extract_filters(attrs):
    filters = {}
    for key in FILTER_KEYS:
        if key in attrs:
            filters[key] = attrs[key]
    return filters


def normalize_bool(value):
    lowered = value.lower()
    if lowered in ("true", "false"):
        return lowered == "true"
    if lowered in ("1", "0"):
        return lowered == "1"
    return value


def rewrite_include_path(path, rewrite):
    if not rewrite:
        return path
    if path.endswith(".xml"):
        return path[:-4] + ".json"
    return path


def convert_storyboard(node):
    obj = {"type": "storyboard"}
    for key in ("event", "repeat", "repeatAt", "repeatat"):
        if key in node.attrib:
            if key == "repeatat":
                obj["repeatAt"] = node.attrib[key]
            else:
                obj[key] = node.attrib[key]

    animations = []
    sounds = []
    for child in node:
        if child.tag == "animation":
            anim = {}
            for attr, value in child.attrib.items():
                if attr in ("mode", "easingMode"):
                    anim["mode"] = value
                elif attr in ("autoreverse", "autoReverse"):
                    anim["autoReverse"] = normalize_bool(value)
                else:
                    anim[attr] = normalize_bool(value)
            animations.append(anim)
        elif child.tag == "sound":
            snd = {}
            for attr, value in child.attrib.items():
                if attr in ("autoreverse", "autoReverse"):
                    snd["autoReverse"] = normalize_bool(value)
                elif attr == "at":
                    snd["begin"] = value
                else:
                    snd[attr] = normalize_bool(value)
            sounds.append(snd)

    if animations:
        obj["animations"] = animations
    if sounds:
        obj["sounds"] = sounds

    return obj


def convert_element(node, schema):
    obj = {"type": node.tag}

    if "name" in node.attrib:
        obj["name"] = node.attrib["name"]
    if "extra" in node.attrib:
        obj["extra"] = normalize_bool(node.attrib["extra"])
    if "importProperties" in node.attrib:
        obj["importProperties"] = node.attrib["importProperties"]

    filters = extract_filters(node.attrib)
    if filters:
        obj["filters"] = filters

    props = []
    children = []

    reserved = {"name", "extra", "importProperties"} | FILTER_KEYS

    for key, value in node.attrib.items():
        if key in reserved:
            continue
        props.append({"name": key, "value": value})

    property_set = collect_properties(node.tag, schema)
    is_shader = node.tag in {"shader", "screenshader", "menuShader", "fadeShader"}

    for child in node:
        if child.tag == "storyboard":
            children.append(convert_storyboard(child))
            continue
        if child.tag == "itemTemplate":
            child_obj = convert_element(child, schema)
            children.append(child_obj)
            continue

        has_children = any(grand.tag for grand in child)
        child_filters = extract_filters(child.attrib)

        prop_name = child.tag
        if prop_name == "animate" and node.tag == "imagegrid":
            prop_name = "animateSelection"

        known_element = is_element_tag(child.tag, schema)
        if not has_children and (prop_name in property_set or is_shader or node.tag == "menuIcons" or not known_element):
            value = (child.text or "").strip()
            entry = {"name": prop_name, "value": value}
            if child_filters:
                entry["filters"] = child_filters
            props.append(entry)
            continue

        child_obj = convert_element(child, schema)
        if child_filters:
            child_obj["filters"] = child_filters
        children.append(child_obj)

    if props:
        obj["props"] = props
    if children:
        obj["children"] = children

    return obj


def convert_include(node, rewrite):
    obj = {"type": "include"}
    path = (node.text or "").strip()
    if path:
        obj["path"] = rewrite_include_path(path, rewrite)

    for key in ("subset", "name", "displayName", "subSetDisplayName", "appliesTo"):
        if key in node.attrib:
            obj[key] = node.attrib[key]

    filters = extract_filters(node.attrib)
    if filters:
        obj["filters"] = filters

    return obj


def convert_view(node, schema, node_type):
    obj = {"type": node_type}
    if "name" in node.attrib:
        obj["name"] = node.attrib["name"]
    if "displayName" in node.attrib:
        obj["displayName"] = node.attrib["displayName"]
    if "inherits" in node.attrib:
        obj["inherits"] = node.attrib["inherits"]
    if "extraTransition" in node.attrib:
        obj["extraTransition"] = node.attrib["extraTransition"]
    if "extraTransitionSpeed" in node.attrib:
        obj["extraTransitionSpeed"] = node.attrib["extraTransitionSpeed"]
    if "extraTransitionDirection" in node.attrib:
        obj["extraTransitionDirection"] = node.attrib["extraTransitionDirection"]

    filters = extract_filters(node.attrib)
    if filters:
        obj["filters"] = filters

    elements = []
    for child in node:
        elements.append(convert_element(child, schema))

    if elements:
        obj["elements"] = elements

    return obj


def convert_feature(node, schema, rewrite):
    obj = {"type": "feature"}
    if "supported" in node.attrib:
        obj["supported"] = node.attrib["supported"]

    filters = extract_filters(node.attrib)
    if filters:
        obj["filters"] = filters

    nodes = []
    for child in node:
        if child.tag == "view":
            nodes.append(convert_view(child, schema, "view"))
        elif child.tag == "customView":
            nodes.append(convert_view(child, schema, "customView"))
        elif child.tag == "include":
            nodes.append(convert_include(child, rewrite))
        elif child.tag == "subset":
            nodes.append(convert_subset(child, schema, rewrite))

    if nodes:
        obj["nodes"] = nodes

    return obj


def convert_subset(node, schema, rewrite):
    obj = {"type": "subset"}
    if "name" in node.attrib:
        obj["name"] = node.attrib["name"]
    if "displayName" in node.attrib:
        obj["displayName"] = node.attrib["displayName"]
    if "subSetDisplayName" in node.attrib:
        obj["subSetDisplayName"] = node.attrib["subSetDisplayName"]
    if "appliesTo" in node.attrib:
        obj["appliesTo"] = node.attrib["appliesTo"]

    filters = extract_filters(node.attrib)
    if filters:
        obj["filters"] = filters

    includes = []
    for child in node:
        if child.tag == "include":
            includes.append(convert_include(child, rewrite))

    if includes:
        obj["nodes"] = includes

    return obj


def convert_variables(root):
    vars_entries = []
    for variables in root.findall("variables"):
        base_filters = extract_filters(variables.attrib)
        for child in variables:
            if child.tag is None:
                continue
            value = (child.text or "").strip()
            entry = {"key": child.tag, "value": value}
            child_filters = extract_filters(child.attrib)
            merged = {}
            merged.update(base_filters)
            merged.update(child_filters)
            if merged:
                entry["filters"] = merged
            vars_entries.append(entry)
    return vars_entries


def sanitize_xml(text):
    """Fix common XML issues found in upstream themes:
    - <?xml?> declaration not at start (move it or strip it)
    - Double-dashes inside comments (<!-- --- foo --- -->)
    - Bare & in attribute values (should be &amp;)"""
    import re
    # Strip UTF-8 BOM
    text = text.lstrip('\ufeff')
    # Move <?xml ...?> declaration to the very start if present elsewhere
    m = re.search(r'<\?xml\s[^?]*\?>\s*', text)
    if m:
        decl = m.group().strip()
        text = text[:m.start()] + text[m.end():]
        text = decl + '\n' + text.lstrip()
    # Fix double-dashes inside comments: collapse runs of dashes and
    # ensure the body doesn't start or end with '-' (which would create
    # the forbidden '---' adjacent to the delimiters).
    def _fix_comment(m_inner):
        body = m_inner.group(1)
        body = re.sub(r'-{2,}', '-', body)
        body = body.strip('-')
        if not body.strip():
            return '<!-- -->'
        return '<!-- ' + body.strip() + ' -->'
    text = re.sub(r'<!--(.*?)-->', _fix_comment, text, flags=re.DOTALL)
    # Fix bare & in attribute values
    text = re.sub(r'&(?!amp;|lt;|gt;|quot;|apos;|#)', '&amp;', text)
    return text


def convert_theme(xml_path, schema, rewrite):
    with open(xml_path, 'r', encoding='utf-8', errors='replace') as f:
        raw = f.read()
    raw = sanitize_xml(raw)
    root = ET.fromstring(raw)
    if root.tag != "theme":
        return None

    theme = {}
    if "defaultView" in root.attrib:
        theme["defaultView"] = root.attrib["defaultView"]
    if "defaultTransition" in root.attrib:
        theme["defaultTransition"] = root.attrib["defaultTransition"]

    format_version = None
    nodes = []

    for child in root:
        if child.tag == "formatVersion":
            try:
                format_version = float((child.text or "").strip())
            except ValueError:
                format_version = None
            continue

        if child.tag == "variables":
            continue

        if child.tag == "include":
            nodes.append(convert_include(child, rewrite))
        elif child.tag == "view":
            nodes.append(convert_view(child, schema, "view"))
        elif child.tag == "customView":
            nodes.append(convert_view(child, schema, "customView"))
        elif child.tag == "subset":
            nodes.append(convert_subset(child, schema, rewrite))
        elif child.tag == "feature":
            nodes.append(convert_feature(child, schema, rewrite))

    if format_version is None:
        format_version = 7
    theme["formatVersion"] = format_version

    vars_entries = convert_variables(root)
    if vars_entries:
        theme["variables"] = vars_entries

    if nodes:
        theme["nodes"] = nodes

    return theme


def collect_xml_files(target):
    if os.path.isdir(target):
        matches = []
        for root, _, files in os.walk(target):
            for name in files:
                if name.lower().endswith(".xml"):
                    matches.append(os.path.join(root, name))
        return matches
    return [target]


def main():
    parser = argparse.ArgumentParser(description="Convert ES theme XML to JSON.")
    parser.add_argument("input", help="Theme XML file or directory.")
    parser.add_argument("--output", help="Output file path (only for single input file).")
    parser.add_argument("--schema", default=os.path.join("resources", "theme_schema.json"),
                        help="Path to theme_schema.json.")
    parser.add_argument("--no-rewrite-includes", action="store_true",
                        help="Do not rewrite .xml include paths to .json.")
    args = parser.parse_args()

    schema = load_schema(args.schema)
    rewrite_includes = not args.no_rewrite_includes

    xml_files = collect_xml_files(args.input)
    if len(xml_files) == 1 and args.output:
        output_paths = [args.output]
    else:
        output_paths = []
        for xml_path in xml_files:
            if os.path.basename(xml_path).lower() == "theme.xml":
                output_paths.append(os.path.join(os.path.dirname(xml_path), "theme.json"))
            else:
                base, _ = os.path.splitext(xml_path)
                output_paths.append(base + ".json")

    converted = 0
    for xml_path, output_path in zip(xml_files, output_paths):
        try:
            theme = convert_theme(xml_path, schema, rewrite_includes)
        except ET.ParseError as exc:
            print(f"Skipping {xml_path}: XML parse error {exc}", file=sys.stderr)
            continue

        if theme is None:
            continue

        out_dir = os.path.dirname(output_path)
        if out_dir:
            os.makedirs(out_dir, exist_ok=True)
        with open(output_path, "w", encoding="utf-8") as handle:
            json.dump(theme, handle, indent=2)
            handle.write("\n")
        converted += 1

    if converted == 0:
        print("No theme XML files converted.", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
