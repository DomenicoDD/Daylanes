"""Reference rates from the public OpenRouter catalog, in USD per token."""

import json
import re
from decimal import Decimal, InvalidOperation
from urllib.request import Request, urlopen

from .openrouter import endpoint, now as utc_now
from .store import setting, set_setting

URL = "https://openrouter.ai/api/v1/models"
CACHE_KEY = "openrouter_catalog"
RATE_FIELDS = {"input": "prompt", "cached": "input_cache_read",
               "cache_write": "input_cache_write", "cache_write_1h": "input_cache_write_1h",
               "output": "completion", "web_search": "web_search"}
TOKEN_RATES = ("input", "cached", "cache_write", "output")
# A 1-hour cache write costs twice the input rate on Anthropic models when the catalog has no own rate.
ONE_HOUR_WRITE = {"anthropic": Decimal(2)}
# Cache rates as multiples of the input rate (5-minute write, 1-hour write, read), for catalog rows
# that leave them out, from each provider's published pricing as collected by ccusage
# (rust/crates/ccusage-core/src/pricing/data.rs).
CACHE_DEFAULTS = {
    "anthropic": ("1.25", "2", "0.1"), "openai": ("1", "1", "0.1"), "google": ("1", "1", "0.1"),
    "deepseek": ("1", "1", "0.02"), "x-ai": ("1", "1", "0.25"), "moonshotai": ("1", "2", "0.1"),
    "z-ai": ("1", "1", "0.2"), "qwen": ("1", "1", "0.2"), "minimax": ("1", "1", "0.2"),
    "mistralai": ("1", "1", "0.1"),
}
# Bare model names that other agents log, and the catalog namespace they belong to.
MODEL_NAMESPACES = (
    (re.compile(r"(claude|opus|sonnet|haiku|fable)"), "anthropic"),
    (re.compile(r"(gpt-|o\d(-|$)|codex|chatgpt)"), "openai"),
    (re.compile(r"(gemini|gemma)"), "google"),
    (re.compile(r"grok"), "x-ai"),
    (re.compile(r"deepseek"), "deepseek"),
    (re.compile(r"kimi"), "moonshotai"),
    (re.compile(r"glm"), "z-ai"),
    (re.compile(r"(qwen|qwq)"), "qwen"),
    (re.compile(r"minimax"), "minimax"),
    (re.compile(r"(mistral|devstral|codestral)"), "mistralai"),
)

# Speed tiers bill the whole request at a multiple of the standard rate. The catalog lists standard
# rates only, so these come from the providers' published multipliers, as collected by ccusage
# (MIT, github.com/ryoppippi/ccusage, rust/crates/ccusage-core/src/*-multiplier-overrides.json).
TIER_MULTIPLIERS = {
    "fast": {"exact": {"gpt-5.6-sol": "2", "gpt-5.6-terra": "2", "gpt-5.6-luna": "2", "gpt-5.5": "2.5",
                       "gpt-5.4": "2", "gpt-5.3-codex": "2", "gpt-6-astra": "2", "gpt-6-sol": "2",
                       "gpt-6.1-sol": "2", "gpt-6.1-terra": "2", "gpt-6-luna": "2"},
             "prefix": {"claude-opus-4-6": "6", "claude-opus-4-7": "6", "claude-opus-4-8": "2"}},
    "ultrafast": {"exact": {"gpt-6-astra": "6", "gpt-6.1-sol": "6"}, "prefix": {}},
    "flex": {"exact": {model: "0.5" for model in (
        "gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-luna", "gpt-6-sol", "gpt-5.6-sol", "gpt-5.6-terra",
        "gpt-5.6-luna", "gpt-5.5", "gpt-5.5-pro", "gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano", "gpt-5.4-pro",
        "gpt-5.2", "gpt-5.1", "gpt-5", "gpt-5-mini", "gpt-5-nano", "o3", "o4-mini")}, "prefix": {}},
}
# Codex names its review model by role; the model behind it changed on 2026-07-30.
AUTO_REVIEW = "codex-auto-review"
AUTO_REVIEW_SWITCH = 1785369600000  # 2026-07-30T00:00:00Z
KIMI_K2_6_SWITCH = 1776698890072  # 2026-04-20T15:28:10.072Z, when Kimi's coding plan moved to K2.6
NAMESPACES = {"codex": "openai", "claude": "anthropic"}
PROVIDER_NAMESPACES = {"xai": "x-ai", "grok": "x-ai", "gemini": "google", "vertex_ai": "google", "moonshot": "moonshotai",
                       "zai": "z-ai", "alibaba": "qwen", "claude": "anthropic", "mistral": "mistralai"}
MODEL_ID = re.compile(r"[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._:-]*")


def catalog(conn):
    return json.loads(setting(conn, CACHE_KEY, '{"models": {}}'))


def fetch_models():
    with urlopen(Request(endpoint(URL), headers={"Accept": "application/json"}), timeout=8) as response:
        body = response.read(8 * 1024 * 1024 + 1)
    if len(body) > 8 * 1024 * 1024:
        raise ValueError("Catalog exceeds the size limit")
    return json.loads(body)["data"]


def rate(raw):
    try:
        value = Decimal(str(raw))
        if value.is_finite() and 0 <= value <= 100:
            return str(value)
    except InvalidOperation:
        pass
    return None


def tiers(overrides, base, multiplier=None):
    """Long-context prices: OpenRouter lists them as overrides that apply once a request's prompt
    (input, cache reads and cache writes together) reaches min_prompt_tokens. Rates an override leaves
    out stay at the base price."""
    found = []
    for override in overrides if isinstance(overrides, list) else ():
        if not isinstance(override, dict):
            continue
        threshold = override.get("min_prompt_tokens")
        if type(threshold) is not int or threshold <= 0:
            continue
        rates = {field: rate(override.get(key)) for field, key in RATE_FIELDS.items()}
        if any(value is not None for value in rates.values()):
            if rates["cache_write_1h"] is None and rates["input"] is not None and multiplier:
                rates["cache_write_1h"] = str(Decimal(rates["input"]) * multiplier)
            found.append({"min_prompt_tokens": threshold,
                          "rates": {field: value if value is not None else base[field] for field, value in rates.items()}})
    return sorted(found, key=lambda tier: tier["min_prompt_tokens"])


def refresh(conn, if_stale=False):
    now = int(utc_now().timestamp())
    previous = catalog(conn) if if_stale else {}
    if 0 <= now - previous.get("fetched_at", 0) < 86400:
        return {"models": len(previous["models"]), "fetched_at": previous["fetched_at"], "refreshed": False}
    models = {}
    try:
        rows = fetch_models()
        if not isinstance(rows, list):
            raise ValueError("Invalid catalog")
        for row in rows:
            if not isinstance(row, dict):
                continue
            model, prices = row.get("id"), row.get("pricing")
            if not isinstance(model, str) or not MODEL_ID.fullmatch(model) or not isinstance(prices, dict):
                continue
            rates = {field: rate(prices.get(key)) for field, key in RATE_FIELDS.items()}
            if rates["input"] is not None and rates["output"] is not None:
                if rates["cache_write_1h"] is None and model.split("/")[0] in ONE_HOUR_WRITE:
                    rates["cache_write_1h"] = str(Decimal(rates["input"]) * ONE_HOUR_WRITE[model.split("/")[0]])
                canonical = row.get("canonical_slug")
                models[model] = {"rates": rates, "canonical": canonical if isinstance(canonical, str) else None,
                                 "tiers": tiers(prices.get("overrides"), rates, ONE_HOUR_WRITE.get(model.split("/")[0]))}
        if not models:
            raise ValueError("No token rates found")
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise ValueError(f"Could not refresh OpenRouter prices: {error}") from None
    set_setting(conn, CACHE_KEY, json.dumps({"fetched_at": now, "models": models}))
    return {"models": len(models), "fetched_at": now, "refreshed": True}


def anthropic_id(model):
    # Anthropic and OpenRouter spell some of the same versions differently.
    for pattern in (r"anthropic/claude-(?P<family>haiku|sonnet|opus|fable)-(?P<version>\d+(?:[.-]\d{1,2})?)(?P<date>-\d{8})?",
                    r"anthropic/claude-(?P<version>\d+(?:[.-]\d{1,2})?)-(?P<family>haiku|sonnet|opus|fable)(?P<date>-\d{8})?"):
        match = re.fullmatch(pattern, model)
        if match:
            version = match["version"].replace("-", ".")
            return f"anthropic/claude-{match['family']}-{version}{match['date'] or ''}"
    return model


class Catalog:
    def __init__(self, conn):
        data = catalog(conn)
        self.fetched_at = data.get("fetched_at")
        def decimals(rates):
            return {k: Decimal(v) if v is not None else None for k, v in rates.items()}

        self.rates = {model: decimals(row["rates"]) for model, row in data["models"].items()}
        self.tiers = {model: [(tier["min_prompt_tokens"], decimals(tier["rates"])) for tier in row.get("tiers", ())]
                      for model, row in data["models"].items() if row.get("tiers")}
        aliases = {}
        for model, row in data["models"].items():
            if ":" in model:  # Batch/free rates are eligible only when explicitly named.
                continue
            candidates = [anthropic_id(model)]
            canonical = row["canonical"]
            if canonical and MODEL_ID.fullmatch(canonical) and canonical.split("/")[0] == model.split("/")[0]:
                candidates.extend((canonical, anthropic_id(canonical)))
            for alias in candidates:
                aliases.setdefault(alias, set()).add(model)
        self.aliases = {alias: next(iter(matches)) for alias, matches in aliases.items() if len(matches) == 1}

    def model(self, harness, model):
        if not model:
            return None
        if model.startswith("openrouter/"):
            model = model[len("openrouter/"):]
        if "/" not in model:
            namespace = NAMESPACES.get(harness) or next(
                (name for pattern, name in MODEL_NAMESPACES if pattern.match(model.lower())), None)
            if namespace:
                model = f"{namespace}/{model}"
        elif model.split("/")[0] in PROVIDER_NAMESPACES:
            # Agents name providers their own way (google/, xai/, moonshot/ ...).
            head, rest = model.split("/", 1)
            model = f"{PROVIDER_NAMESPACES[head]}/{rest}"
        if model in self.rates:
            return model
        return self.aliases.get(model) or self.aliases.get(anthropic_id(model))

    def quote(self, entry):
        """API value of an entry: the cost the agent recorded when it has one, else the estimate."""
        recorded = entry.get("recorded_usd")
        if recorded:
            try:
                return Decimal(recorded)
            except InvalidOperation:
                pass
        return self.estimate(entry)

    def estimate(self, entry):
        model = self.model(entry["provider"], served_model(entry["model"], entry.get("at")))
        if model is None:
            return None
        rates = self.rates_for(model, entry.get("prompt_tokens"))
        one_hour = min(entry.get("cache_write_1h") or 0, entry["cache_write"] or 0)
        counts = {"input": entry["input"], "cached": entry["cached"], "output": entry["output"],
                  "cache_write": (entry["cache_write"] or 0) - one_hour, "cache_write_1h": one_hour}
        if one_hour and rates.get("cache_write_1h") is None:
            # No published 1-hour rate: price it like other cache writes rather than leaving it out.
            counts["cache_write"], counts["cache_write_1h"] = entry["cache_write"], 0
        if any(count and rates.get(field) is None for field, count in counts.items()):
            return None
        total = sum((count * rates[field] for field, count in counts.items() if count), Decimal(0))
        total *= tier_multiplier(entry.get("tier"), model)
        searches = entry.get("web_searches") or 0
        if searches and rates.get("web_search") is not None:
            total += searches * rates["web_search"]
        return total

    def rates_for(self, model, prompt_tokens):
        """The whole request is billed at the long-context rate once its prompt reaches the threshold.
        prompt_tokens is the largest single request in the entry; older imports have none."""
        rates = self.rates[model]
        for threshold, tier in self.tiers.get(model, ()):
            if prompt_tokens and prompt_tokens >= threshold:
                rates = tier
        defaults = CACHE_DEFAULTS.get(model.split("/")[0])
        if defaults and rates.get("input") is not None:
            filled = dict(rates)
            for field, factor in zip(("cache_write", "cache_write_1h", "cached"), defaults):
                if filled.get(field) is None:
                    filled[field] = rates["input"] * Decimal(factor)
            rates = filled
        return rates


def served_model(model, at):
    """Models some agents name by role, and the priced model behind each name at that time."""
    if model == AUTO_REVIEW and at:
        return "gpt-5.6-luna" if at >= AUTO_REVIEW_SWITCH else "gpt-5.4"
    if model == "kimi-for-coding" and at:
        return "moonshotai/kimi-k2.6" if at >= KIMI_K2_6_SWITCH else "moonshotai/kimi-k2.5"
    return model


def tier_multiplier(tier, model):
    table = TIER_MULTIPLIERS.get("fast" if tier == "priority" else tier)
    if not table:
        return Decimal(1)
    name = model.split("/")[-1]
    base = re.sub(r"-\d{8}$", "", name)
    for candidate in (name, base):
        if candidate in table["exact"]:
            return Decimal(table["exact"][candidate])
    # Anthropic and OpenRouter write versions as 4-6 and 4.6.
    dashed = base.replace(".", "-")
    for prefix, value in table["prefix"].items():
        if dashed.startswith(prefix):
            return Decimal(value)
    return Decimal(1)
