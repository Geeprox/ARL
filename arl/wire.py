"""JSON decoding rules shared by bounded wire contracts."""
import json

from .contracts import Fault


class DuplicateJSONField(ValueError):
    """An object repeated one of its keys."""


def _unique_object(items):
    result = {}
    for key, value in items:
        if key in result:
            raise DuplicateJSONField()
        result[key] = value
    return result


def _invalid_constant(_value):
    raise ValueError('nonfinite JSON constant')


def decode_json(raw):
    """Disallow duplicate fields and the non-JSON NaN/Infinity literals."""
    return json.loads(raw, object_pairs_hook=_unique_object, parse_constant=_invalid_constant)


def strict_json(raw):
    try:
        return decode_json(raw.decode('utf-8'))
    except (ValueError, UnicodeError, RecursionError):
        raise Fault('invalid_payload') from None

