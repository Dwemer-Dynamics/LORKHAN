#!/usr/bin/env python3
"""Repository protocol discipline checker.

This is deliberately a structural Draft 2020-12 checker, not a complete JSON Schema engine.
It checks repository conventions, resolves local references, validates the keyword subset used by
ALMSIVI, and exercises fixture expectations. If the third-party ``jsonschema`` package is already
installed, it additionally performs official meta-schema and instance validation without fetching.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
SCHEMAS = ROOT / "almsivi/schemas/v1"
FIXTURES = ROOT / "almsivi/fixtures/v1"
DRAFT = "https://json-schema.org/draft/2020-12/schema"
SCHEMA_URI = re.compile(r"^https://almsivi\.invalid/schemas/v1/[a-z0-9.-]+\.schema\.json$")

class ValidationError(ValueError):
    pass


def load(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def schema_files() -> list[Path]:
    return sorted(SCHEMAS.glob("*.schema.json"))


def resolve(ref: str, registry: dict[str, dict[str, Any]]) -> dict[str, Any]:
    base, marker, fragment = ref.partition("#")
    if base not in registry:
        raise ValidationError(f"unresolved or non-local $ref: {ref}")
    node: Any = registry[base]
    if marker and fragment:
        if not fragment.startswith("/"):
            raise ValidationError(f"unsupported non-pointer fragment: {ref}")
        for part in fragment[1:].split("/"):
            part = part.replace("~1", "/").replace("~0", "~")
            if not isinstance(node, dict) or part not in node:
                raise ValidationError(f"unresolved JSON pointer: {ref}")
            node = node[part]
    if not isinstance(node, dict):
        raise ValidationError(f"$ref does not select a schema object: {ref}")
    return node


def check_schema_shape(node: Any, path: str, registry: dict[str, dict[str, Any]]) -> None:
    if isinstance(node, list):
        for index, child in enumerate(node):
            check_schema_shape(child, f"{path}[{index}]", registry)
        return
    if not isinstance(node, dict):
        return
    if "$ref" in node:
        if not isinstance(node["$ref"], str):
            raise ValidationError(f"{path}.$ref must be a string")
        resolve(node["$ref"], registry)
    if (node.get("type") == "object" and node.get("additionalProperties") is not False
            and not node.get("$comment", "").startswith("Deferred")):
        raise ValidationError(f"{path}: contract-owned object must set additionalProperties:false")
    if "properties" in node and node.get("type") != "object":
        raise ValidationError(f"{path}: properties requires type:object")
    if "required" in node:
        properties = node.get("properties", {})
        if not isinstance(node["required"], list) or not all(key in properties for key in node["required"]):
            raise ValidationError(f"{path}: required must name declared properties")
    for key, child in node.items():
        if key in {"properties", "$defs"} and isinstance(child, dict):
            for name, subschema in child.items():
                check_schema_shape(subschema, f"{path}.{key}.{name}", registry)
        elif key in {"items", "contains", "not", "if", "then", "else"}:
            check_schema_shape(child, f"{path}.{key}", registry)
        elif key in {"allOf", "anyOf", "oneOf", "prefixItems"}:
            check_schema_shape(child, f"{path}.{key}", registry)


def type_matches(value: Any, expected: str) -> bool:
    return {
        "object": lambda: isinstance(value, dict), "array": lambda: isinstance(value, list),
        "string": lambda: isinstance(value, str), "integer": lambda: isinstance(value, int) and not isinstance(value, bool),
        "number": lambda: isinstance(value, (int, float)) and not isinstance(value, bool),
        "boolean": lambda: isinstance(value, bool), "null": lambda: value is None,
    }[expected]()


def validate(value: Any, schema: dict[str, Any], registry: dict[str, dict[str, Any]], path: str = "$") -> None:
    if "$ref" in schema:
        validate(value, resolve(schema["$ref"], registry), registry, path)
        siblings = {key: item for key, item in schema.items() if key != "$ref"}
        if siblings:
            validate(value, siblings, registry, path)
        return
    if "allOf" in schema:
        for child in schema["allOf"]:
            validate(value, child, registry, path)
    if "anyOf" in schema and not any(valid(child, value, registry, path) for child in schema["anyOf"]):
        raise ValidationError(f"{path}: no anyOf branch matched")
    if "oneOf" in schema and sum(valid(child, value, registry, path) for child in schema["oneOf"]) != 1:
        raise ValidationError(f"{path}: expected exactly one oneOf match")
    if "not" in schema and valid(schema["not"], value, registry, path):
        raise ValidationError(f"{path}: matched forbidden schema")
    if "const" in schema and value != schema["const"]:
        raise ValidationError(f"{path}: expected constant {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        raise ValidationError(f"{path}: value is not in enum")
    if "type" in schema:
        types = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(type_matches(value, item) for item in types):
            raise ValidationError(f"{path}: wrong type")
    if isinstance(value, dict):
        missing = [key for key in schema.get("required", []) if key not in value]
        if missing:
            raise ValidationError(f"{path}: missing required keys {missing}")
        properties = schema.get("properties", {})
        for key, item in value.items():
            if key in properties:
                validate(item, properties[key], registry, f"{path}.{key}")
            elif schema.get("additionalProperties") is False:
                raise ValidationError(f"{path}: unexpected key {key!r}")
    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0) or len(value) > schema.get("maxItems", sys.maxsize):
            raise ValidationError(f"{path}: array length out of bounds")
        if schema.get("uniqueItems") and len({json.dumps(item, sort_keys=True) for item in value}) != len(value):
            raise ValidationError(f"{path}: duplicate array item")
        if isinstance(schema.get("items"), dict):
            for index, item in enumerate(value):
                validate(item, schema["items"], registry, f"{path}[{index}]")
    if isinstance(value, str):
        if len(value) < schema.get("minLength", 0) or len(value) > schema.get("maxLength", sys.maxsize):
            raise ValidationError(f"{path}: string length out of bounds")
        if "pattern" in schema and re.fullmatch(schema["pattern"], value) is None:
            raise ValidationError(f"{path}: string does not match pattern")
        if schema.get("format") == "date-time":
            try:
                datetime.fromisoformat(value.replace("Z", "+00:00"))
            except ValueError as exc:
                raise ValidationError(f"{path}: invalid calendar date-time") from exc
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if value < schema.get("minimum", float("-inf")) or value > schema.get("maximum", float("inf")):
            raise ValidationError(f"{path}: number out of bounds")


def valid(schema: dict[str, Any], value: Any, registry: dict[str, dict[str, Any]], path: str) -> bool:
    try:
        validate(value, schema, registry, path)
        return True
    except ValidationError:
        return False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--require-jsonschema", action="store_true")
    args = parser.parse_args()
    schemas = {path: load(path) for path in schema_files()}
    registry = {schema.get("$id", ""): schema for schema in schemas.values()}
    if len(registry) != len(schemas) or "" in registry:
        raise ValidationError("schema $id values must be present and unique")
    for path, schema in schemas.items():
        if schema.get("$schema") != DRAFT or not SCHEMA_URI.fullmatch(schema.get("$id", "")):
            raise ValidationError(f"{path.name}: wrong Draft 2020-12 declaration or canonical $id")
        check_schema_shape(schema, path.name, registry)

    use_jsonschema = importlib.util.find_spec("jsonschema") is not None
    if args.require_jsonschema and not use_jsonschema:
        raise ValidationError("jsonschema is not installed; dependency fetching is forbidden")
    official = None
    if use_jsonschema:
        import jsonschema
        for schema in schemas.values():
            jsonschema.Draft202012Validator.check_schema(schema)
        official = True

    fixture_count = 0
    for classification in ("valid", "invalid", "hostile"):
        for path in sorted((FIXTURES / classification).glob("*.json")):
            wrapper = load(path)
            if set(wrapper) != {"description", "instance", "schema"}:
                raise ValidationError(f"{path.name}: fixture wrapper has unexpected fields")
            if wrapper["schema"] not in registry:
                raise ValidationError(f"{path.name}: unknown schema URI")
            accepted = valid(registry[wrapper["schema"]], wrapper["instance"], registry, path.name)
            if (classification == "valid") != accepted:
                raise ValidationError(f"{path.name}: expected {classification}, structural result was {'valid' if accepted else 'invalid'}")
            if official is not None:
                # Referencing uses the package's resolver when installed; structural validation remains authoritative here.
                try:
                    import jsonschema
                    from referencing import Registry, Resource
                    local_registry = Registry()
                    for uri, document in registry.items():
                        local_registry = local_registry.with_resource(uri, Resource.from_contents(document))
                    jsonschema.Draft202012Validator(
                        registry[wrapper["schema"]], registry=local_registry,
                        format_checker=jsonschema.Draft202012Validator.FORMAT_CHECKER,
                    ).validate(wrapper["instance"])
                    official_accepted = True
                except jsonschema.ValidationError:
                    official_accepted = False
                if (classification == "valid") != official_accepted:
                    raise ValidationError(f"{path.name}: installed jsonschema disagrees with fixture class")
            fixture_count += 1
    result = subprocess.run([sys.executable, str(ROOT / "scripts/protocol/generate_manifest.py"), "--check"], cwd=ROOT)
    if result.returncode:
        return result.returncode
    print(f"validated {len(schemas)} Draft 2020-12 schemas and {fixture_count} fixtures"
          f" ({'with' if use_jsonschema else 'without'} installed jsonschema)")
    return 0

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, json.JSONDecodeError, ValidationError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(2)
