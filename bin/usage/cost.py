"""The one price table of the usage scripts: what a request costs, by model and token type.

Not run on its own (an agent with no allow entry for a run reads the tables below with Read
and prices by hand). Every usage script loads this file by its own path (python3 -I leaves
the script's folder off the import path, so a plain `import cost` would fail):

    import importlib.util, os
    _s = importlib.util.spec_from_file_location(
        "cost", os.path.join(os.path.dirname(os.path.abspath(__file__)), "cost.py"))
    cost = importlib.util.module_from_spec(_s)
    _s.loader.exec_module(cost)

Prices are USD per million tokens, copied exactly as published on Anthropic's pricing page
(RATES_URL), read on RATES_DATE. They are API list prices: the Max plan's weights are not
published, so list prices are the stated proxy. Each row has the five published numbers (base
input, 5-minute cache write, 1-hour cache write, cache read, output); none is derived from
another. To update: re-read the page, replace the rows and RATES_DATE; never copy from memory
or from another table.
"""
import datetime

RATES_URL = "https://platform.claude.com/docs/en/about-claude/pricing"
RATES_DATE = "2026-10-18"

KINDS = ("input", "cache_write_5m", "cache_write_1h", "cache_read", "output")

# USD per million tokens, in KINDS order.
RATES = {
    "claude-opus-5-5": (4.00, 5.00, 8.00, 0.20, 20.00),
    "claude-sonnet-5-5": (2.00, 2.50, 4.00, 0.10, 10.00),
    "claude-haiku-5-5": (0.10, 0.125, 0.20, 0.01, 0.50),
    "claude-haiku-4-5-20251001": (1.00, 1.25, 2.00, 0.10, 5.00),
}
# Claude Haiku 5.5 is priced by prompt length: a request whose prompt (all input tokens,
# cache reads and writes included) is over 100,000 tokens pays the higher row. Each request is
# priced on its own. No other model in RATES has a long-context tier ("Claude 4.6 and later
# models (except Claude Haiku 5.5) ... include the full 1M token context window at standard
# pricing").
LONG_THRESHOLD = {"claude-haiku-5-5": 100_000}
LONG_RATES = {"claude-haiku-5-5": (0.50, 0.625, 1.00, 0.05, 2.50)}
LONG_SUFFIX = ">100k"

# Not a model: costs nothing and is never listed as unpriced.
FREE = {"<synthetic>"}

# A transcript message with no model id is totalled under this name (never the string "None");
# it has no row, so it is priced at the fallback and listed as unpriced.
UNKNOWN_MODEL = "unknown-model"

FOOTER = (f"Prices: API list prices from {RATES_URL} as of {RATES_DATE}; "
          "Max plan weights are unpublished, so list prices are the proxy.")


def _check():
    if not RATES_DATE:
        raise SystemExit("cost.py: RATES_DATE is empty; the price table must carry its date")
    for table in (RATES, LONG_RATES):
        for k, row in table.items():
            if len(row) != len(KINDS):
                raise SystemExit(f"cost.py: {k} needs {len(KINDS)} prices")


_check()


def rates_age_days(today=None):
    today = today or datetime.date.today()
    return (today - datetime.date.fromisoformat(RATES_DATE)).days


def fallback_rates():
    """The most expensive known price for each kind: an id with no row is never priced low."""
    rows = list(RATES.values()) + list(LONG_RATES.values())
    return tuple(max(r[i] for r in rows) for i in range(len(KINDS)))


def bucket(model, ctx):
    """The key a request is totalled under: the model id, or id + '>100k' for a long prompt."""
    if model in LONG_THRESHOLD and ctx > LONG_THRESHOLD[model]:
        return model + LONG_SUFFIX
    return model


def rates_for(key):
    """(prices in KINDS order, priced) for a bucket key. Unknown ids get the fallback and priced=False."""
    if key is None:
        return fallback_rates(), False
    if key in FREE:
        return (0.0,) * len(KINDS), True
    if key.endswith(LONG_SUFFIX) and key[:-len(LONG_SUFFIX)] in LONG_RATES:
        return LONG_RATES[key[:-len(LONG_SUFFIX)]], True
    if key in RATES:
        return RATES[key], True
    return fallback_rates(), False


def usd(key, tokens):
    """USD for a dict of tokens by kind (missing kinds are 0) under one bucket key."""
    r, _ = rates_for(key)
    return sum(tokens.get(k, 0) * p for k, p in zip(KINDS, r)) / 1e6


def usage_tokens(u):
    """A transcript message's usage as a dict by kind."""
    w1h = (u.get("cache_creation") or {}).get("ephemeral_1h_input_tokens", 0)
    return {"input": u.get("input_tokens", 0),
            "cache_write_5m": u.get("cache_creation_input_tokens", 0) - w1h,
            "cache_write_1h": w1h,
            "cache_read": u.get("cache_read_input_tokens", 0),
            "output": u.get("output_tokens", 0)}


def context(u):
    """A request's prompt length: input + cache reads + cache writes."""
    return (u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0)
            + u.get("cache_creation_input_tokens", 0))


def request_key(model, u):
    if model is None:
        return UNKNOWN_MODEL
    return bucket(model, context(u))


def request_cost(model, u):
    """(USD, priced) of one request: its model, its usage, the long tier by its own prompt length."""
    key = request_key(model, u)
    return usd(key, usage_tokens(u)), rates_for(key)[1]


def cache_read_rate(model, u):
    """USD per token of re-reading this request's context from cache."""
    return rates_for(request_key(model, u))[0][3] / 1e6


class Unpriced:
    """Collects the model ids priced at the fallback, for the report's own line."""

    def __init__(self):
        self.ids = set()

    def note(self, key, priced):
        if not priced:
            self.ids.add(str(key))

    def line(self):
        ids = ", ".join(sorted(self.ids)) or "none"
        return (f"unpriced models (priced at the most expensive known rate): {ids}; "
                f"price table dated {RATES_DATE} ({rates_age_days()} days old)")
