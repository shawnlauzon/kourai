"""Load an installation's kourai config over the plugin's defaults.

The config is one TOML file per installation, outside git. Its path comes
from --config, else $KOURAI_CONFIG. The plugin's documented defaults are
config/defaults.toml (or $KOURAI_DEFAULTS, for tests). The file is read again
on every call, so a changed value applies on the next call with no restart.

Rules, all driven by the defaults file's [_schema] table:
- Every key in the config must exist in the defaults (a typo is an error),
  except inside the tables listed in _schema.open_tables.
- A value's type must match the default's: string, integer, float (an
  integer is accepted), boolean, array (elements typed like the default's
  first element), table.
- Keys in _schema.required must be set to a non-empty value.
- Arrays of tables named in _schema.items get per-item defaults, required
  keys and the same key and type checks.
- Strings may reference another string or number key as {dotted.key}; a
  leading ~/ expands to the home directory.

Exit codes of the CLI: 0 ok, 1 invalid config, 2 usage or unknown key,
3 no config file, 4 Python too old.
"""

import copy
import json
import os
import re
import shlex
import sys

if sys.version_info < (3, 11):
    sys.stderr.write("kourai-config needs Python 3.11 or later (tomllib)\n")
    sys.exit(4)

import tomllib  # noqa: E402

EXIT_INVALID = 1
EXIT_USAGE = 2
EXIT_NO_CONFIG = 3

REF = re.compile(r"\{([A-Za-z0-9_.\-]+)\}")


class ConfigError(Exception):
    """The config file is missing, unreadable or invalid."""

    def __init__(self, code, path, problems):
        super().__init__("; ".join(problems))
        self.code = code
        self.path = path
        self.problems = problems


class UnknownKey(Exception):
    pass


def plugin_root():
    return os.path.dirname(os.path.dirname(os.path.realpath(__file__)))


def defaults_path():
    return os.environ.get("KOURAI_DEFAULTS") or os.path.join(
        plugin_root(), "config", "defaults.toml")


def config_path(explicit=None):
    return explicit or os.environ.get("KOURAI_CONFIG") or None


def _read_toml(path, code_if_missing):
    try:
        with open(path, "rb") as f:
            return tomllib.load(f)
    except FileNotFoundError:
        raise ConfigError(code_if_missing, path, ["file not found: " + path])
    except tomllib.TOMLDecodeError as e:
        raise ConfigError(EXIT_INVALID, path, ["TOML syntax: %s" % e])


def _type_name(v):
    if isinstance(v, bool):
        return "boolean"
    if isinstance(v, int):
        return "integer"
    if isinstance(v, float):
        return "float"
    if isinstance(v, str):
        return "string"
    if isinstance(v, list):
        return "array"
    if isinstance(v, dict):
        return "table"
    return type(v).__name__


def _same_type(default, value):
    d, v = _type_name(default), _type_name(value)
    return d == v or (d == "float" and v == "integer")


def _check_value(key, default, value, problems):
    if not _same_type(default, value):
        problems.append("%s: expected %s, got %s"
                        % (key, _type_name(default), _type_name(value)))
        return
    if isinstance(default, list) and default:
        for i, el in enumerate(value):
            if not _same_type(default[0], el):
                problems.append("%s[%d]: expected %s, got %s"
                                % (key, i, _type_name(default[0]), _type_name(el)))


def _merge(defaults, config, prefix, schema, problems):
    """Return defaults with config laid over, recording problems."""
    out = copy.deepcopy(defaults)
    open_tables = schema.get("open_tables", [])
    items = schema.get("items", {})
    for k, v in config.items():
        key = prefix + k
        if k not in defaults:
            if prefix.rstrip(".") in open_tables:
                out[k] = v
            else:
                problems.append("%s: unknown key" % key)
            continue
        d = defaults[k]
        if key in items:
            out[k] = _merge_items(key, items[key], v, problems)
        elif isinstance(d, dict) and isinstance(v, dict):
            out[k] = _merge(d, v, key + ".", schema, problems)
        else:
            _check_value(key, d, v, problems)
            out[k] = v
    for k, d in defaults.items():
        if prefix + k in items and k not in config:
            out[k] = []
    return out


def _merge_items(key, spec, value, problems):
    if not isinstance(value, list):
        problems.append("%s: expected array, got %s" % (key, _type_name(value)))
        return []
    item_defaults = spec.get("defaults", {})
    out = []
    for i, item in enumerate(value):
        ikey = "%s[%d]" % (key, i)
        if not isinstance(item, dict):
            problems.append("%s: expected table, got %s" % (ikey, _type_name(item)))
            continue
        merged = _merge(item_defaults, item, ikey + ".", {}, problems)
        for r in spec.get("required", []):
            if merged.get(r) in ("", None, []):
                problems.append("%s.%s: required" % (ikey, r))
        out.append(merged)
    return out


def _lookup(cfg, key):
    node = cfg
    for part in key.split("."):
        if isinstance(node, dict) and part in node:
            node = node[part]
        elif isinstance(node, list) and part.isdigit() and int(part) < len(node):
            node = node[int(part)]
        else:
            raise UnknownKey(key)
    return node


def _interpolate(cfg, problems):
    def resolve(s, where, depth=0):
        def sub(m):
            ref = m.group(1)
            try:
                v = _lookup(cfg, ref)
            except UnknownKey:
                problems.append("%s: unknown reference {%s}" % (where, ref))
                return m.group(0)
            if isinstance(v, (dict, list, bool)):
                problems.append("%s: {%s} is not a string or number" % (where, ref))
                return m.group(0)
            v = str(v)
            if depth < 5 and REF.search(v):
                v = resolve(v, where, depth + 1)
            return v
        s = REF.sub(sub, s)
        if s.startswith("~/"):
            s = os.path.expanduser("~") + s[1:]
        return s

    def walk(node, where):
        if isinstance(node, dict):
            for k in node:
                node[k] = walk(node[k], where + k + ".")
        elif isinstance(node, list):
            for i in range(len(node)):
                node[i] = walk(node[i], "%s[%d]." % (where.rstrip("."), i))
        elif isinstance(node, str):
            return resolve(node, where.rstrip("."))
        return node

    # Values are replaced in place; a reference to a key that itself holds
    # a reference resolves through resolve()'s own recursion, so key order
    # does not matter.
    walk(cfg, "")


def load(path=None):
    """Return the merged, validated config as a dict. Raises ConfigError."""
    path = config_path(path)
    if not path:
        raise ConfigError(EXIT_NO_CONFIG, None, [
            "NO CONFIG: pass --config <file> or set KOURAI_CONFIG"])
    defaults = _read_toml(defaults_path(), EXIT_INVALID)
    schema = defaults.pop("_schema", {})
    config = _read_toml(path, EXIT_NO_CONFIG)
    problems = []
    if "_schema" in config:
        problems.append("_schema: belongs to the plugin's defaults, not a config")
        config.pop("_schema")
    merged = _merge(defaults, config, "", schema, problems)
    for key in schema.get("required", []):
        try:
            v = _lookup(merged, key)
        except UnknownKey:
            v = None
        if v in ("", None, []):
            problems.append("%s: required" % key)
    if not problems:
        _interpolate(merged, problems)
    if problems:
        raise ConfigError(EXIT_INVALID, path, problems)
    return merged


def get(cfg, key):
    return _lookup(cfg, key)


def _scalar(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    return str(v)


def render(v):
    if isinstance(v, (dict, list)) and (
            isinstance(v, dict) or any(isinstance(e, (dict, list)) for e in v)):
        return json.dumps(v, indent=2)
    if isinstance(v, list):
        return "\n".join(_scalar(e) for e in v)
    return _scalar(v)


def shell_lines(cfg, prefix="KOURAI"):
    lines = []

    def walk(node, name):
        if isinstance(node, dict):
            for k, v in node.items():
                walk(v, name + "_" + re.sub(r"[^A-Za-z0-9]", "_", k).upper())
        elif isinstance(node, list):
            if all(not isinstance(e, (dict, list)) for e in node):
                lines.append("%s=%s" % (name, shlex.quote(" ".join(_scalar(e) for e in node))))
        else:
            lines.append("%s=%s" % (name, shlex.quote(_scalar(node))))

    walk(cfg, prefix)
    return lines


USAGE = """usage: kourai-config [--config FILE] <command>
  check          validate; prints CONFIG OK: <file> or CONFIG INVALID: <file> and the problems
  get KEY        one value (dotted key, array index as a number); tables print as JSON
  json [KEY]     the merged config (or one key) as JSON
  shell [KEY]    KOURAI_<KEY>=<value> lines for scalars and scalar arrays, quoted for eval
  path           the config file in use
  defaults       the defaults file in use"""


def main(argv):
    explicit = None
    args = list(argv)
    if len(args) >= 2 and args[0] == "--config":
        explicit = args[1]
        args = args[2:]
    if not args or args[0] in ("-h", "--help"):
        print(USAGE)
        return 0 if args else EXIT_USAGE
    cmd, rest = args[0], args[1:]
    if cmd == "defaults":
        print(defaults_path())
        return 0
    if cmd not in ("check", "get", "json", "shell", "path"):
        sys.stderr.write("unknown command: %s\n%s\n" % (cmd, USAGE))
        return EXIT_USAGE
    if cmd == "get" and len(rest) != 1:
        sys.stderr.write("get needs one KEY\n")
        return EXIT_USAGE
    try:
        cfg = load(explicit)
    except ConfigError as e:
        if e.path is None:
            sys.stderr.write(e.problems[0] + "\n")
        elif e.code == EXIT_NO_CONFIG:
            sys.stderr.write("NO CONFIG: %s\n" % e.problems[0])
        else:
            sys.stderr.write("CONFIG INVALID: %s\n" % e.path)
            for p in e.problems:
                sys.stderr.write("  %s\n" % p)
        return e.code
    path = config_path(explicit)
    try:
        if cmd == "check":
            print("CONFIG OK: %s" % path)
        elif cmd == "path":
            print(path)
        elif cmd == "get":
            print(render(get(cfg, rest[0])))
        elif cmd == "json":
            print(json.dumps(get(cfg, rest[0]) if rest else cfg, indent=2))
        elif cmd == "shell":
            node = get(cfg, rest[0]) if rest else cfg
            name = "KOURAI" + ("_" + re.sub(r"[^A-Za-z0-9]", "_", rest[0]).upper() if rest else "")
            print("\n".join(shell_lines(node, name)))
    except UnknownKey as e:
        sys.stderr.write("unknown key: %s\n" % e.args[0])
        return EXIT_USAGE
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
