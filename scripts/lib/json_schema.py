"""Small dependency-free validator for the JSON Schema keywords used by ALMSIVI ledgers."""
from __future__ import annotations

import re
from typing import Any


class SchemaError(ValueError):
    pass


def _type_matches(value: Any, expected: str) -> bool:
    return {"object": lambda: isinstance(value, dict), "array": lambda: isinstance(value, list),
            "string": lambda: isinstance(value, str), "integer": lambda: isinstance(value, int) and not isinstance(value, bool),
            "number": lambda: isinstance(value, (int, float)) and not isinstance(value, bool),
            "boolean": lambda: isinstance(value, bool), "null": lambda: value is None}[expected]()


def validate(value: Any, schema: dict[str, Any], path: str = "$") -> None:
    if "const" in schema and value != schema["const"]:
        raise SchemaError(f"{path}: expected constant {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        raise SchemaError(f"{path}: value is not in enum")
    if "type" in schema:
        types = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(_type_matches(value, item) for item in types):
            raise SchemaError(f"{path}: expected type {' or '.join(types)}")
    if isinstance(value, dict):
        required = schema.get("required", [])
        missing = [key for key in required if key not in value]
        if missing:
            raise SchemaError(f"{path}: missing required keys {missing}")
        properties = schema.get("properties", {})
        pattern_properties = schema.get("patternProperties", {})
        additional = schema.get("additionalProperties", True)
        for key, item in value.items():
            if key in properties:
                validate(item, properties[key], f"{path}.{key}")
                continue
            matched_patterns = [pattern_schema for pattern, pattern_schema in pattern_properties.items()
                                if re.search(pattern, key) is not None]
            if matched_patterns:
                for pattern_schema in matched_patterns:
                    validate(item, pattern_schema, f"{path}.{key}")
            elif additional is False:
                raise SchemaError(f"{path}: unexpected key {key!r}")
            elif isinstance(additional, dict):
                validate(item, additional, f"{path}.{key}")
    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0):
            raise SchemaError(f"{path}: too few items")
        if isinstance(schema.get("items"), dict):
            for index, item in enumerate(value):
                validate(item, schema["items"], f"{path}[{index}]")
    if isinstance(value, str):
        if len(value) < schema.get("minLength", 0):
            raise SchemaError(f"{path}: string is too short")
        if "pattern" in schema and re.search(schema["pattern"], value) is None:
            raise SchemaError(f"{path}: string does not match pattern")
