"""Compact-inner / indented-outer JSON encoder.

Pretty-printer that collapses primitive-only lists to a single line
while keeping dicts and long lists indented.  Ported from
`production/py/change2target.py::ShortListJSONEncoder` -- same
behaviour, same output shape.
"""

from __future__ import annotations
import json
from json.encoder import encode_basestring_ascii


class ShortListJSONEncoder(json.JSONEncoder):
    """Emit primitive-only lists on a single line, keep dicts indented.

    Usage:
        json.dumps(obj, cls=ShortListJSONEncoder,
                   max_line_length=100, indent=2)
    """

    def __init__(self, *args, max_line_length: int = 100, **kwargs):
        super().__init__(*args, **kwargs)
        self.max_line_length  = max_line_length
        self._current_indent  = 0

    def encode(self, o) -> str:
        self._current_indent = 0
        return self._encode_value(o)

    def _encode_value(self, o) -> str:
        if self._is_short_list(o):
            return self._encode_short_list(o)
        if isinstance(o, dict):
            return self._encode_dict(o)
        if isinstance(o, list):
            return self._encode_list(o)
        if isinstance(o, str):
            return encode_basestring_ascii(o)
        if o is None:
            return "null"
        if isinstance(o, bool):
            return "true" if o else "false"
        return json.dumps(o)

    def _is_short_list(self, o) -> bool:
        if not isinstance(o, list):
            return False
        if not all(isinstance(x, (str, int, float, bool, type(None))) for x in o):
            return False
        return len(self._encode_short_list(o)) <= self.max_line_length

    def _encode_short_list(self, o) -> str:
        parts = []
        for item in o:
            if isinstance(item, str):
                parts.append(encode_basestring_ascii(item))
            elif item is None:
                parts.append("null")
            elif isinstance(item, bool):
                parts.append("true" if item else "false")
            else:
                parts.append(str(item))
        return "[" + ", ".join(parts) + "]"

    def _indent(self) -> str:
        w = int(self.indent) if self.indent else 2
        return " " * (w * self._current_indent)

    def _encode_dict(self, o) -> str:
        if not o:
            return "{}"
        self._current_indent += 1
        pad = self._indent()
        items = []
        for k, v in o.items():
            k_str = encode_basestring_ascii(k)
            v_str = self._encode_value(v)
            if "\n" in v_str and not self._is_short_list(v):
                lines = v_str.split("\n")
                v_str = lines[0] + "".join("\n" + pad + line for line in lines[1:])
            items.append(f"{pad}{k_str}: {v_str}")
        self._current_indent -= 1
        return "{\n" + ",\n".join(items) + "\n" + self._indent() + "}"

    def _encode_list(self, o) -> str:
        if not o:
            return "[]"
        if self._is_short_list(o):
            return self._encode_short_list(o)
        self._current_indent += 1
        pad = self._indent()
        items = []
        for item in o:
            item_str = self._encode_value(item)
            if "\n" in item_str and not self._is_short_list(item):
                lines = item_str.split("\n")
                item_str = lines[0] + "".join("\n" + pad + line for line in lines[1:])
            items.append(pad + item_str)
        self._current_indent -= 1
        return "[\n" + ",\n".join(items) + "\n" + self._indent() + "]"


def dumps(obj, *, indent: int = 2, max_line_length: int = 100) -> str:
    """Convenience wrapper.  Same shape as json.dumps but short-list inline."""
    return json.dumps(obj,
                      cls=ShortListJSONEncoder,
                      indent=indent,
                      max_line_length=max_line_length)
