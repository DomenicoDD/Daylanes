"""Importers for coding agents beyond Claude Code, Codex and OpenCode.

Each tool keeps its history in its own files. The formats here follow ccusage's adapters (MIT,
github.com/ryoppippi/ccusage, rust/adapters/<tool>), which are kept current with each tool's releases;
where Tracker reads a tool differently, the reason is noted in place.

Conventions, as for Claude and Codex entries: input excludes cached tokens, output includes reasoning
(`reasoning` keeps that share for reference), and `recorded_usd` is a cost the tool recorded itself.
Entry IDs are stable across reads, so reading a file again updates its entries instead of adding more,
and a record copied into another file (a fork, an archive, a migration) lands on the same entry.
"""

import hashlib
import json
import os
import re
import sqlite3
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import unquote

from . import importers

TOKENS = ("input", "cached", "cache_write", "output")
USD_PER_AIU = 0.01  # GitHub bills one AI credit (AIU) at $0.01
GROK_TICKS_PER_USD = 10 ** 10


# Shared helpers ------------------------------------------------------------------------------------

def home():
    return Path.home()


def env_roots(variable, defaults):
    """A tool's data roots: a comma-separated environment variable replaces the defaults."""
    configured = [part.strip() for part in os.getenv(variable, "").split(",") if part.strip()]
    paths = [Path(part).expanduser() for part in configured] if configured else defaults
    return list(importers.unique_paths(paths))


def count(value):
    if isinstance(value, bool):
        return 0
    if isinstance(value, float) and value == value and abs(value) != float("inf"):
        value = int(value)
    return value if type(value) is int and 0 <= value <= 10 ** 12 else 0


def pick(record, *keys):
    for key in keys:
        if isinstance(record, dict) and record.get(key) is not None:
            return count(record[key])
    return 0


def text(value):
    return value.strip() if isinstance(value, str) and value.strip() else None


def obj(value):
    return value if isinstance(value, dict) else {}


def cost(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if value != value or value < 0 or value > 10 ** 6:
        return None
    return repr(round(float(value), 10))


def millis(value):
    """A timestamp in whatever form a tool writes it: ISO text, SQLite datetime text, Unix seconds or
    milliseconds."""
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        if value != value or value <= 0 or value > 10 ** 14:
            return None
        return int(value * 1000) if value < 10 ** 11 else int(value)
    if isinstance(value, str) and value.strip():
        raw = value.strip()
        if re.fullmatch(r"\d+(\.\d+)?", raw):
            return millis(float(raw))
        try:
            stamp = datetime.fromisoformat(re.sub(r"Z$", "+00:00", raw).replace(" ", "T", 1))
        except ValueError:
            return importers.parse_at(raw)
        if stamp.tzinfo is None:
            stamp = stamp.replace(tzinfo=timezone.utc)  # SQLite's datetime() writes UTC
        return int(stamp.timestamp() * 1000)
    return None


def mtime(path):
    try:
        return int(path.stat().st_mtime * 1000)
    except OSError:
        return None


def digest(*parts):
    return hashlib.sha1(json.dumps(parts, sort_keys=True, default=str).encode()).hexdigest()[:20]


def usage(provider, key, at, model, session=None, folder=None, branch=None, input=0, cached=0,
          cache_write=0, output=0, reasoning=0, recorded=None, extra=0, total=None):
    """One usage entry. Tokens a tool counts in its total but in none of the parts (reasoning written
    separately) are billed as output, as providers bill them."""
    counts = dict(input=input, cached=cached, cache_write=cache_write, output=output)
    known = sum(counts.values()) + extra
    if total and total > known:
        extra += total - known
    counts["output"] += extra
    if at is None or (not any(counts.values()) and recorded is None):
        return None
    return dict(id=f"harness:{provider}:{key}", kind="usage", at=at, model=model or "unknown",
                prompt_tokens=counts["input"] + counts["cached"] + counts["cache_write"],
                reasoning=max(reasoning, extra), recorded_usd=recorded, **counts,
                **importers.metadata(provider, session, folder, branch))


def read_json(path):
    with path.open("rb") as source:
        return json.load(source)


def jsonl(path, stats):
    return importers.json_records(path, stats)


def sqlite_rows(path, query, parameters=()):
    """Read a tool's database without writing to it, including committed WAL data."""
    uri = path.resolve().as_uri() + "?mode=ro"
    with closing(sqlite3.connect(uri, uri=True, timeout=2)) as db:
        db.row_factory = sqlite3.Row
        db.execute("BEGIN")
        return [dict(row) for row in db.execute(query, parameters)]


def sqlite_tables(path):
    names = [row["name"] for row in sqlite_rows(path, "SELECT name FROM sqlite_master WHERE type = 'table'")]
    return {name: {column["name"] for column in sqlite_rows(path, f"PRAGMA table_info(\"{name.replace(chr(34), '')}\")")}
            for name in names}


def files(roots, *patterns, skip=None):
    found = set()
    for root in roots:
        if not root.is_dir():
            continue
        for pattern in patterns:
            for path in root.glob(pattern):
                if path.is_file() and not path.is_symlink() and not (skip and skip(path)):
                    found.add(path)
    return sorted(found)


def existing(paths):
    return [path for path in importers.unique_paths(paths) if path.is_file()]


def strip_suffixes(model, *suffixes):
    for suffix in suffixes:
        if model and model.endswith(suffix):
            return model[:-len(suffix)]
    return model


def prefixed(provider, model, ignore=()):
    """Qualify a bare model name with the provider an agent logged, so the price lookup finds it."""
    if model and provider and "/" not in model and provider.lower() not in ignore:
        return f"{provider.lower()}/{model}"
    return model


# Amp ------------------------------------------------------------------------------------------------

def amp_roots():
    return env_roots("AMP_DATA_DIR", [home() / ".local" / "share" / "amp"])


def amp_entries(path, stats):
    thread = obj(read_json(path))
    thread_id = text(thread.get("id"))
    if not thread_id:
        return
    messages = [obj(message) for message in thread.get("messages") or ()]
    events = obj(thread.get("usageLedger")).get("events")
    if isinstance(events, list):
        # The ledger has one event per request; cache counts are on the message it produced.
        cache = {}
        for message in messages:
            if type(message.get("messageId")) is int:
                record = obj(message.get("usage"))
                cache[message["messageId"]] = (pick(record, "cacheCreationInputTokens"),
                                               pick(record, "cacheReadInputTokens"))
        for index, event in enumerate(obj(event) for event in events):
            tokens = obj(event.get("tokens"))
            model = text(event.get("model"))
            writes, reads = cache.get(event.get("toMessageId"), (0, 0))
            entry = usage("amp", f"{thread_id}:{text(event.get('id')) or index}", millis(event.get("timestamp")),
                          model, session=thread_id, input=pick(tokens, "input"), output=pick(tokens, "output"),
                          cached=reads, cache_write=writes, total=pick(tokens, "total"))
            if entry and model:
                yield entry
        return
    for index, message in enumerate(messages):
        record = obj(message.get("usage"))
        if message.get("role") != "assistant" or not record:
            continue
        model = text(record.get("model")) or text(message.get("model"))
        at = millis(record.get("timestamp")) or millis(message.get("timestamp"))
        key = message.get("messageId") if message.get("messageId") is not None else index
        entry = usage("amp", f"{thread_id}:{key}", at, model, session=thread_id,
                      input=pick(record, "inputTokens"), output=pick(record, "outputTokens"),
                      cached=pick(record, "cacheReadInputTokens"), cache_write=pick(record, "cacheCreationInputTokens"),
                      total=pick(record, "totalTokens"))
        if entry and model:
            yield entry


# Droid (Factory) -------------------------------------------------------------------------------------

def droid_roots():
    return env_roots("DROID_SESSIONS_DIR", [home() / ".factory" / "sessions"])


def droid_model(raw):
    """Droid writes names such as "custom:Claude-Sonnet-4.5-[Proxy]"; catalog IDs use dashes."""
    raw = re.sub(r"\[[^\]]*\]", "", raw[len("custom:"):] if raw.startswith("custom:") else raw)
    return re.sub(r"[-.\s]+", "-", raw.strip().rstrip("-").lower()).strip("-")


def droid_entries(path, stats):
    # A session's settings file holds its running totals, so the session is one entry that grows.
    settings = obj(read_json(path))
    tokens = obj(settings.get("tokenUsage"))
    if not tokens:
        return
    session = path.name[:-len(".settings.json")]
    model = text(settings.get("model"))
    sidecar = path.with_name(f"{session}.jsonl")
    if not model and sidecar.is_file():
        with sidecar.open("rb") as source:
            for number, line in enumerate(source):
                found = re.search(rb'Model:\s*([^"\\\[]+)', line)
                if found or number >= 500:
                    model = found and found.group(1).decode(errors="replace").strip() or None
                    break
    thinking = pick(tokens, "thinkingTokens")
    entry = usage("droid", f"{session}:session", millis(settings.get("providerLockTimestamp")) or mtime(path),
                  droid_model(model) if model else None, session=session, folder=text(settings.get("cwd")),
                  input=pick(tokens, "inputTokens"), output=pick(tokens, "outputTokens"),
                  cached=pick(tokens, "cacheReadTokens"), cache_write=pick(tokens, "cacheCreationTokens"),
                  extra=thinking, reasoning=thinking, total=pick(tokens, "totalTokens"))
    if entry:
        yield entry


# Codebuff ---------------------------------------------------------------------------------------------

def codebuff_roots():
    config = home() / ".config"
    return env_roots("CODEBUFF_DATA_DIR", [config / "manicode", config / "manicode-dev", config / "manicode-staging"])


def codebuff_usage(record):
    record = obj(record)
    if not record:
        return None
    separate = pick(record, "cacheReadInputTokens", "cache_read_input_tokens")
    # OpenAI-style usage counts cached tokens inside the prompt; Anthropic-style keeps them apart.
    included = max(pick(obj(record.get("promptTokensDetails")), "cachedTokens"),
                   pick(obj(record.get("prompt_tokens_details")), "cached_tokens"))
    prompt = pick(record, "inputTokens", "input_tokens", "promptTokens", "prompt_tokens")
    return dict(
        input=prompt - min(prompt, included) if included and not separate else prompt,
        cached=max(separate, included),
        cache_write=pick(record, "cacheCreationInputTokens", "cache_creation_input_tokens", "cacheCreationTokens",
                         "cache_creation_tokens", "cachedTokensCreated", "cached_tokens_created"),
        output=pick(record, "outputTokens", "output_tokens", "completionTokens", "completion_tokens"),
        total=pick(record, "totalTokens", "total_tokens", "total")), text(record.get("model"))


def codebuff_entries(path, stats):
    messages = read_json(path)
    if not isinstance(messages, list):
        return
    chat_dir = path.parent
    chat, project = chat_dir.name, chat_dir.parent.parent.name
    channel = chat_dir.parent.parent.parent.parent.name or "manicode"
    session = f"{channel}/{project}/{chat}"
    date, _, clock = chat.partition("T")
    chat_at = millis(f"{date}T{clock.replace('-', ':', 2)}") if clock else None
    for index, message in enumerate(obj(message) for message in messages):
        if (text(message.get("variant")) or text(message.get("role"))) not in ("ai", "agent", "assistant"):
            continue
        metadata = obj(message.get("metadata"))
        candidates = [metadata.get("usage"), obj(metadata.get("codebuff")).get("usage")]
        history = obj(obj(obj(metadata.get("runState")).get("sessionState")).get("mainAgentState")).get("messageHistory")
        for item in reversed(history if isinstance(history, list) else []):
            options = obj(obj(item).get("providerOptions"))
            if obj(item).get("role") == "assistant":
                candidates += [options.get("usage"), obj(options.get("codebuff")).get("usage")]
        found, model = next(((counts, name) for counts, name in filter(None, map(codebuff_usage, candidates))
                             if any(counts.values())), (None, None))
        if not found:
            continue
        at = millis(message.get("timestamp")) or millis(message.get("createdAt")) or millis(metadata.get("timestamp")) \
            or chat_at
        model = text(metadata.get("model")) or model
        key = text(message.get("id")) or digest(at, model, index, found)
        entry = usage("codebuff", f"{session}:{key}", at, model, session=session, **found)
        if entry:
            yield entry


# Cline -----------------------------------------------------------------------------------------------

EDITORS = ("Code", "Code - Insiders", "Cursor", "Windsurf", "VSCodium")


def cline_roots():
    bases = [home() / "Library" / "Application Support",
             Path(os.getenv("XDG_CONFIG_HOME") or home() / ".config"),
             Path(os.getenv("APPDATA") or home() / "AppData" / "Roaming")]
    defaults = [home() / ".cline"] + [base / editor / "User" / "globalStorage" / "saoudrizwan.claude-dev"
                                      for base in bases for editor in EDITORS]
    return env_roots("CLINE_DATA_DIR", defaults)


def cline_files(roots):
    return files(roots, "tasks/*/ui_messages.json", "data/tasks/*/ui_messages.json",
                 "data/sessions/*/*.messages.json", "sessions/*/*.messages.json")


def cline_model(info, key):
    model = text(obj(info).get(key))
    return None if not model or model.lower() == "unknown" else model


def cline_entries(path, stats):
    data = read_json(path)
    if path.name == "ui_messages.json":
        # Editor extension: each finished request is an api_req_started event with its counts as JSON text.
        session = f"task:{path.parent.name}"
        for message in (obj(message) for message in (data if isinstance(data, list) else [])):
            if message.get("type") != "say" or message.get("say") != "api_req_started" or message.get("partial") is True:
                continue
            try:
                metrics = obj(json.loads(message.get("text") or ""))
            except (TypeError, ValueError):
                continue
            model = cline_model(message.get("modelInfo"), "modelId")
            if not model or any(type(metrics.get(field)) is not int
                                for field in ("tokensIn", "tokensOut", "cacheReads", "cacheWrites")):
                continue
            at = message.get("ts") if type(message.get("ts")) is int else None
            key = text(metrics.get("requestId")) or text(metrics.get("id")) or text(message.get("id")) or at
            entry = usage("cline", f"{session}:{key}", at, model, session=session, input=count(metrics["tokensIn"]),
                          output=count(metrics["tokensOut"]), cached=count(metrics["cacheReads"]),
                          cache_write=count(metrics["cacheWrites"]), recorded=cost(metrics.get("cost")))
            if entry and any(entry[field] for field in TOKENS):
                yield entry
        return
    session = f"cli:{path.parent.name}"
    for message in (obj(message) for message in obj(data).get("messages") or ()):
        metrics = obj(message.get("metrics"))
        model = cline_model(message.get("modelInfo"), "id")
        if message.get("role") != "assistant" or not model or any(
                type(metrics.get(field)) is not int
                for field in ("inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens")):
            continue
        # The CLI counts cache reads and writes inside its input figure.
        reads, writes = count(metrics["cacheReadTokens"]), count(metrics["cacheWriteTokens"])
        if reads + writes > count(metrics["inputTokens"]):
            continue
        at = message.get("ts") if type(message.get("ts")) is int else millis(message.get("timestamp"))
        key = text(message.get("requestId")) or text(message.get("id")) or text(message.get("messageId")) or at
        entry = usage("cline", f"{session}:{key}", at, model, session=session,
                      input=count(metrics["inputTokens"]) - reads - writes, output=count(metrics["outputTokens"]),
                      cached=reads, cache_write=writes, recorded=cost(metrics.get("cost")))
        if entry and any(entry[field] for field in TOKENS):
            yield entry


# Hermes Agent ----------------------------------------------------------------------------------------

def hermes_databases():
    return existing(root / "state.db" for root in env_roots("HERMES_HOME", [home() / ".hermes"]))


def optional_columns(columns, wanted):
    return ", ".join(column if column in columns else f"NULL AS {column}" for column in wanted)


def hermes_entries(path, stats):
    columns = sqlite_tables(path).get("sessions", set())
    if not {"id", "model", "started_at"} <= columns:
        raise ValueError("Unrecognized Hermes database schema")
    selected = optional_columns(columns, ("input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens",
                                          "reasoning_tokens", "estimated_cost_usd", "actual_cost_usd",
                                          "billing_provider", "cwd"))
    for row in sqlite_rows(path, f"SELECT id, model, started_at, {selected} FROM sessions "
                                 "WHERE model IS NOT NULL AND trim(model) != ''"):
        session = text(str(row["id"])) if row["id"] is not None else None
        # The actual cost wins over the estimate; a recorded zero says nothing, so tokens are priced instead.
        recorded = next((value for value in (cost(row["actual_cost_usd"]), cost(row["estimated_cost_usd"]))
                         if value is not None), None)
        reasoning = count(row["reasoning_tokens"])
        model = prefixed(text(row["billing_provider"]), row["model"], ("openrouter", "custom", "local"))
        entry = usage("hermes", f"{session}:session", millis(row["started_at"]), model, session=session,
                      folder=row["cwd"], input=count(row["input_tokens"]), output=count(row["output_tokens"]),
                      cached=count(row["cache_read_tokens"]), cache_write=count(row["cache_write_tokens"]),
                      extra=reasoning, reasoning=reasoning, recorded=recorded if recorded != "0.0" else None)
        if session and entry:
            yield entry


# pi-agent and OpenClaw (which writes pi's session format) ------------------------------------------

def pi_roots():
    return env_roots("PI_AGENT_DIR", [home() / ".pi" / "agent" / "sessions"])


def model_change(row):
    if row.get("type") == "model_change" or (row.get("type") == "custom" and row.get("customType") == "model-snapshot"):
        source = obj(row.get("data")) or row
        return text(source.get("modelId")) or text(source.get("model")), text(source.get("provider"))
    return None


def pi_record(provider, row, session, folder, model, model_provider, fallback=None):
    """An assistant message with usage. A forked log copies its parent's records with their
    timestamps, so a record without an ID of its own is keyed by its content and counts once."""
    message = obj(row.get("message"))
    record = obj(message.get("usage"))
    if row.get("type") not in (None, "message") or message.get("role") != "assistant" or not record:
        return None
    at = millis(message.get("timestamp")) or millis(row.get("timestamp")) or fallback
    name = text(message.get("modelId")) or text(message.get("model")) or model
    name = prefixed(text(message.get("provider")) or model_provider, name)
    counts = dict(input=pick(record, "input"), output=pick(record, "output"), cached=pick(record, "cacheRead"),
                  cache_write=pick(record, "cacheWrite"))
    recorded = cost(obj(record.get("cost")).get("total"))
    key = digest(at, name, counts, recorded) if provider == "pi" else \
        f"{session}:{text(row.get('id')) or digest(at, name, counts)}"
    return usage(provider, key, at, name, session=session, folder=folder, recorded=recorded,
                 total=pick(record, "totalTokens"), **counts)


def pi_entries(path, stats):
    session, folder, model, model_provider = path.name.split(".jsonl")[0], None, None, None
    for row in jsonl(path, stats):
        if row.get("type") == "session":
            folder = text(row.get("cwd"))
            continue
        changed = model_change(row)
        if changed:
            model, model_provider = changed[0] or model, changed[1] or model_provider
            continue
        entry = pi_record("pi", row, session, folder, model, model_provider)
        if entry:
            yield entry


def openclaw_roots():
    return env_roots("OPENCLAW_DIR", [home() / name for name in (".openclaw", ".clawdbot", ".moltbot", ".moldbot")])


def openclaw_files(roots):
    # Deleted and reset transcripts keep the usage they recorded.
    return files(roots, "**/*.jsonl", "**/*.jsonl.deleted.*", "**/*.jsonl.reset.*", "**/openclaw-agent.sqlite")


def openclaw_agent(path):
    parts = path.parts
    if "agents" in parts and parts.index("agents") + 1 < len(parts) - 1:
        index = parts.index("agents")
        return Path(*parts[:index + 2])
    return None


def openclaw_channels(agent_dir):
    """sessions.json maps session keys such as agent:main:telegram:dm:42 to session IDs."""
    try:
        data = read_json(agent_dir / "sessions" / "sessions.json")
    except (OSError, ValueError):
        return {}
    found = {}
    for key, value in obj(data).items():
        session = text(obj(value).get("sessionId"))
        if session and isinstance(key, str):
            found[session] = "/".join(segment for segment in key.split(":")[2:] if segment) or None
    return found


def openclaw_entries(path, stats):
    # An OpenClaw agent works outside any repository, so its entries carry the agent's folder, plus the
    # channel the session came from (telegram/dm/42): a project's folder rule can then claim a whole
    # agent or a single channel.
    agent_dir = openclaw_agent(path)
    channels = openclaw_channels(agent_dir) if agent_dir else {}

    def place(session, cwd=None):
        if cwd or agent_dir is None:
            return cwd
        channel = channels.get(session)
        return str(agent_dir / "channels" / channel) if channel and channel != "main" else str(agent_dir)

    if path.name == "openclaw-agent.sqlite":
        if "transcript_events" not in sqlite_tables(path):
            return
        state = {}
        for row in sqlite_rows(path, "SELECT session_id, seq, event_json, created_at FROM transcript_events "
                                     "ORDER BY session_id, seq"):
            try:
                event = obj(json.loads(row["event_json"]))
            except (TypeError, ValueError):
                continue
            session = str(row["session_id"])
            entry = openclaw_event(event, session, state, place, millis(row["created_at"]))
            if entry:
                yield entry
        return
    session, state = path.name.split(".jsonl")[0], {}
    for row in jsonl(path, stats):
        entry = openclaw_event(row, session, state, place, None)
        if entry:
            yield entry


def openclaw_event(row, session, state, place, fallback):
    model, model_provider, cwd = state.get(session, (None, None, None))
    if row.get("type") == "session":
        state[session] = (model, model_provider, text(row.get("cwd")) or cwd)
        return None
    changed = model_change(row)
    if changed:
        state[session] = (changed[0] or model, changed[1] or model_provider, cwd)
        return None
    # The database and the files it was migrated from hold the same events under the same IDs.
    return pi_record("openclaw", row, session, place(session, cwd), model, model_provider, fallback)


# Goose ------------------------------------------------------------------------------------------------

def goose_databases():
    configured = os.getenv("GOOSE_PATH_ROOT", "").strip()
    if configured:
        return existing([Path(configured).expanduser() / "data" / "sessions" / "sessions.db"])
    return existing([home() / ".local" / "share" / "goose" / "sessions" / "sessions.db",
                     home() / "Library" / "Application Support" / "goose" / "sessions" / "sessions.db",
                     home() / ".local" / "share" / "Block" / "goose" / "sessions" / "sessions.db"])


def goose_entries(path, stats):
    columns = sqlite_tables(path).get("sessions", set())
    if not {"id", "model_config_json", "created_at"} <= columns:
        raise ValueError("Unrecognized Goose database schema")
    selected = optional_columns(columns, ("provider_name", "total_tokens", "input_tokens", "output_tokens",
                                          "accumulated_total_tokens", "accumulated_input_tokens",
                                          "accumulated_output_tokens", "working_dir"))
    for row in sqlite_rows(path, f"SELECT id, model_config_json, created_at, {selected} FROM sessions "
                                 "WHERE model_config_json IS NOT NULL AND trim(model_config_json) != ''"):
        try:
            model = text(obj(json.loads(row["model_config_json"])).get("model_name"))
        except (TypeError, ValueError):
            continue

        def first(*names):
            # Session totals: the accumulated columns include every turn, the plain ones only the last.
            return next((count(row[name]) for name in names if row[name] is not None), 0)

        # Goose keeps no cache counts. Tokens in the total beyond input and output are reasoning.
        entry = usage("goose", f"{row['id']}:session", millis(row["created_at"]),
                      prefixed(text(row["provider_name"]), model), session=str(row["id"]), folder=row["working_dir"],
                      input=first("accumulated_input_tokens", "input_tokens"),
                      output=first("accumulated_output_tokens", "output_tokens"),
                      total=first("accumulated_total_tokens", "total_tokens"))
        if model and entry:
            yield entry


# Kilo ------------------------------------------------------------------------------------------------

def kilo_databases():
    return existing(root / "kilo.db" for root in env_roots("KILO_DATA_DIR", [home() / ".local" / "share" / "kilo"]))


def kilo_entries(path, stats):
    tables = sqlite_tables(path)
    if not {"id", "session_id", "data"} <= tables.get("message", set()):
        raise ValueError("Unrecognized Kilo database schema")
    directories = {}
    if {"id", "directory"} <= tables.get("session", set()):
        directories = {row["id"]: row["directory"] for row in sqlite_rows(path, "SELECT id, directory FROM session")}
    for row in sqlite_rows(path, "SELECT id, session_id, data FROM message"):
        try:
            data = obj(json.loads(row["data"]))
        except (TypeError, ValueError):
            continue
        tokens = obj(data.get("tokens"))
        if data.get("role") != "assistant" or not tokens:
            continue
        cache = obj(tokens.get("cache"))
        reasoning = pick(tokens, "reasoning")
        entry = usage("kilo", str(data.get("id") or row["id"]), millis(obj(data.get("time")).get("created")),
                      prefixed(text(data.get("providerID")), text(data.get("modelID")), ("kilo", "unknown")),
                      session=row["session_id"],
                      folder=text(obj(data.get("path")).get("cwd")) or directories.get(row["session_id"]),
                      input=pick(tokens, "input"), output=pick(tokens, "output"), cached=pick(cache, "read"),
                      cache_write=pick(cache, "write"), extra=reasoning, reasoning=reasoning,
                      total=pick(tokens, "total"), recorded=cost(data.get("cost")))
        if entry:
            yield entry


# Kimi ------------------------------------------------------------------------------------------------

def kimi_roots():
    return env_roots("KIMI_DATA_DIR", [home() / ".kimi", home() / ".kimi-code"])


def kimi_files(roots):
    return files(roots, "sessions/*/*/wire.jsonl", "sessions/*/*/agents/*/wire.jsonl")


def kimi_entries(path, stats):
    parts = path.parts
    index = len(parts) - 1 - parts[::-1].index("sessions")
    root, session = Path(*parts[:index]), parts[index + 2]
    configured = None
    for row in jsonl(path, stats):
        if row.get("type") == "usage.record":
            # Kimi Code: turn records count once; session records repeat them as running totals.
            record = obj(row.get("usage"))
            if row.get("usageScope") != "turn" or not record:
                continue
            at = millis(row.get("time"))
            name = (text(row.get("model")) or "kimi-for-coding").removeprefix("kimi-code/")
            counts = dict(input=pick(record, "inputOther"), output=pick(record, "output"),
                          cached=pick(record, "inputCacheRead"), cache_write=pick(record, "inputCacheCreation"))
        else:
            message = obj(row.get("message"))
            record = obj(obj(message.get("payload")).get("token_usage"))
            if message.get("type") != "StatusUpdate" or not record:
                continue
            if configured is None:
                try:
                    configured = text(obj(read_json(root / "config.json")).get("model")) or "kimi-for-coding"
                except (OSError, ValueError):
                    configured = "kimi-for-coding"
            at, name = millis(row.get("timestamp")), configured
            counts = dict(input=pick(record, "input_other"), output=pick(record, "output"),
                          cached=pick(record, "input_cache_read"), cache_write=pick(record, "input_cache_creation"),
                          total=pick(record, "total"))
        entry = usage("kimi", digest(session, at, name, counts), at, name, session=session, **counts)
        if entry:
            yield entry


# Qwen Code -----------------------------------------------------------------------------------------

def qwen_roots():
    return env_roots("QWEN_DATA_DIR", [home() / ".qwen"])


def qwen_files(roots):
    return files(roots, "projects/*/chats/*.jsonl", "projects/*/chats/archive/*.jsonl")


def qwen_entries(path, stats):
    chats = path.parent if path.parent.name == "chats" else path.parent.parent
    project = chats.parent.name
    for row in jsonl(path, stats):
        record = obj(row.get("usageMetadata"))
        if row.get("type") != "assistant" or not record:
            continue
        # Gemini-style usage: the prompt count includes the cached content (ccusage adds it on top).
        prompt, cached = pick(record, "promptTokenCount"), pick(record, "cachedContentTokenCount")
        cached = min(cached, prompt)
        thoughts = pick(record, "thoughtsTokenCount")
        session = text(row.get("sessionId")) or f"{project}-{path.stem}"
        model, at = text(row.get("model")), millis(row.get("timestamp"))
        counts = dict(input=prompt - cached, cached=cached, output=pick(record, "candidatesTokenCount"))
        # An archived copy of a chat holds the same records: the same ID keeps them once.
        key = text(row.get("uuid")) or digest(session, row.get("timestamp"), model, counts, thoughts)
        entry = usage("qwen", key, at, model, session=session, folder=text(row.get("cwd")), extra=thoughts,
                      reasoning=thoughts, total=pick(record, "totalTokenCount"), **counts)
        if entry:
            yield entry


# GitHub Copilot CLI ---------------------------------------------------------------------------------

def copilot_roots():
    root = os.getenv("COPILOT_HOME", "").strip()
    return [Path(root).expanduser() if root else home() / ".copilot"]


def copilot_counts(record):
    # inputTokens includes both cache buckets; reasoning is part of output.
    reads, writes = pick(record, "cacheReadTokens"), pick(record, "cacheWriteTokens")
    return dict(input=max(pick(record, "inputTokens") - reads - writes, 0), cached=reads, cache_write=writes,
                output=pick(record, "outputTokens")), pick(record, "reasoningTokens")


def credits_usd(nano):
    return cost(nano / 1e9 * USD_PER_AIU) if isinstance(nano, (int, float)) and not isinstance(nano, bool) else None


def copilot_entries(path, stats):
    """Current versions write one usage record per call. Older sessions only have shutdown snapshots
    with running totals per model. OpenTelemetry exports are not read: they repeat these calls and
    carry no credits."""
    session = path.parent.name
    rows = list(jsonl(path, stats))
    records = [row for row in rows if row.get("type") == "session.usage_record"]
    first_record = min((millis(row.get("timestamp")) or 0 for row in records), default=None)
    for row in records:
        record = obj(obj(row.get("data")).get("usage"))
        accounting = obj(record.get("accounting"))
        source, sequence = text(accounting.get("sourceSessionId")), accounting.get("sequence")
        # A record repeated in several sessions' files carries one accounting identity.
        key = f"{source}:{sequence}" if source and type(sequence) is int and sequence > 0 \
            else f"{session}:{text(row.get('id')) or digest(row)}"
        counts, reasoning = copilot_counts(record)
        entry = usage("copilot", f"call:{key}", millis(row.get("timestamp")),
                      strip_suffixes(text(record.get("model")), "-1m-internal", "-1m"), session=source or session,
                      reasoning=reasoning, recorded=credits_usd(obj(record.get("copilotUsage")).get("totalNanoAiu")),
                      **counts)
        if entry:
            yield entry
    # Each shutdown adds what grew since the previous one. Once a session writes a record per call,
    # its later shutdowns repeat those calls, so only the earlier ones count.
    previous = {}
    for index, row in enumerate(rows):
        at = millis(row.get("timestamp"))
        if row.get("type") != "session.shutdown" or at is None or (first_record is not None and at >= first_record):
            continue
        data = obj(row.get("data"))
        if data.get("usageAccountingWatermarks"):
            continue  # its totals include calls recorded with the sessions they belong to
        for model, metrics in obj(data.get("modelMetrics")).items():
            metrics = obj(metrics)
            counts, reasoning = copilot_counts(obj(metrics.get("usage")))
            nano = metrics.get("totalNanoAiu") if isinstance(metrics.get("totalNanoAiu"), (int, float)) else None
            before = previous.get(model, (dict.fromkeys(counts, 0), 0, 0))
            previous[model] = (counts, reasoning, nano)
            delta = {field: max(counts[field] - before[0][field], 0) for field in counts}
            spent = credits_usd(max(nano - before[2], 0)) if nano is not None and before[2] is not None else None
            if not any(delta.values()) and spent in (None, "0.0"):
                continue
            entry = usage("copilot", f"shutdown:{session}:{model}:{index}", at,
                          strip_suffixes(model, "-1m-internal", "-1m"), session=session,
                          reasoning=max(reasoning - before[1], 0), recorded=spent, **delta)
            if entry:
                yield entry


# Gemini CLI ----------------------------------------------------------------------------------------

GEMINI_KEYS = {
    "input": ("input", "prompt", "input_tokens", "prompt_tokens"),
    "output": ("output", "candidates", "output_tokens", "candidates_tokens"),
    "cached": ("cached", "cached_tokens"),
    "thoughts": ("thoughts", "reasoning", "thoughts_tokens", "reasoning_tokens"),
    "tool": ("tool", "tool_tokens"),
}


def gemini_roots():
    return env_roots("GEMINI_DATA_DIR", [home() / ".gemini" / "tmp"])


def gemini_tokens(record, message):
    record = obj(record)
    if not record:
        return None
    values = {name: pick(record, *keys) for name, keys in GEMINI_KEYS.items()}
    total = next((count(record[key]) for key in ("total", "total_tokens") if key in record), None)
    cached = values["cached"]
    if message:
        # A message's input includes its cached prompt only when the total says so.
        inclusive = values["input"] + values["output"] + values["thoughts"] + values["tool"]
        overlap = cached > 0 and total == inclusive and total != inclusive + cached
    else:
        overlap = True  # session statistics count the cached prompt inside input
    fresh = values["input"] - min(values["input"], cached) if overlap else values["input"]
    return dict(input=fresh + values["tool"], cached=cached, output=values["output"], extra=values["thoughts"],
                reasoning=values["thoughts"],
                total=total if total is not None else fresh + values["tool"] + values["output"] + cached + values["thoughts"])


def gemini_stats(record, model_hint):
    stats = obj(record.get("stats")) or obj(obj(record.get("result")).get("stats"))
    found = [(model, tokens) for model, tokens in
             ((model, gemini_tokens(obj(data).get("tokens"), False)) for model, data in obj(stats.get("models")).items())
             if tokens]
    if not found and stats:
        tokens = gemini_tokens(stats, False)
        if tokens and any(tokens[field] for field in ("input", "cached", "output", "extra")):
            found.append((model_hint or "unknown", tokens))
    return found


def gemini_entries(path, stats):
    session = path.stem
    events, totals = {}, []
    model = None
    if path.suffix == ".json":
        document = obj(read_json(path))
        session = text(document.get("sessionId")) or text(document.get("session_id")) or session
        start = millis(document.get("startTime")) or millis(document.get("lastUpdated")) or mtime(path)
        messages = document.get("messages")
        if isinstance(messages, list):
            for record in map(obj, messages):
                model = text(record.get("model")) or model
                if record.get("type") == "gemini":
                    events[text(record.get("id")) or len(events)] = (record, model, start)
        elif document.get("type") == "gemini":
            events["0"] = (document, text(document.get("model")), mtime(path))
        else:
            totals.append((document, text(document.get("model")), mtime(path)))
    else:
        for record in jsonl(path, stats):
            session = text(record.get("sessionId")) or text(record.get("session_id")) or session
            model = text(record.get("model")) or model
            if record.get("type") == "gemini":
                # A message written again as it streams keeps its ID: the last copy wins.
                events[text(record.get("id")) or len(events)] = (record, model, None)
            else:
                totals.append((record, model, None))
    for key, (record, name, fallback) in events.items():
        tokens = gemini_tokens(record.get("tokens"), True)
        at = millis(record.get("timestamp")) or millis(record.get("created_at")) or fallback
        name = text(record.get("model")) or name
        entry = usage("gemini", f"{session}:{key}", at, name, session=session, **tokens) if tokens and name else None
        if entry:
            yield entry
    if events:
        return  # session statistics repeat the messages above
    for index, (record, name, fallback) in enumerate(totals):
        at = millis(record.get("timestamp")) or millis(record.get("created_at")) or fallback
        for model_name, tokens in gemini_stats(record, name):
            entry = usage("gemini", f"{session}:stats:{index}:{model_name}", at, model_name, session=session, **tokens)
            if entry:
                yield entry


# Antigravity ---------------------------------------------------------------------------------------

ANTIGRAVITY_IDS = {246: "gemini-2.5-pro", 312: "gemini-2.5-flash", 313: "gemini-2.5-flash-thinking",
                   329: "gemini-2.5-flash-thinking", 330: "gemini-2.5-flash-lite", 281: "claude-sonnet-4",
                   282: "claude-sonnet-4", 290: "claude-opus-4", 291: "claude-opus-4", 333: "claude-sonnet-4.5",
                   334: "claude-sonnet-4.5", 340: "claude-haiku-4.5", 341: "claude-haiku-4.5", 342: "gpt-oss-120b"}
ANTIGRAVITY_NAMES = {
    "model_placeholder_m26": "claude-opus-4-6", "model_placeholder_m35": "claude-sonnet-4-6",
    "model_placeholder_m402": "claude-opus-5-5", "model_placeholder_m50": "gemini-3.1-flash-lite",
    "model_placeholder_m36": "gemini-3.1-pro", "model_placeholder_m37": "gemini-3.1-pro",
    "model_placeholder_m16": "gemini-3.1-pro", "model_placeholder_m18": "gemini-3-flash-preview",
    "model_placeholder_m84": "gemini-3-flash-preview", "model_placeholder_m47": "gemini-3-flash-preview",
    "model_placeholder_m417": "gemini-4-argon", "model_placeholder_m418": "gemini-4-argon",
    "model_placeholder_m419": "gemini-4-argon", "model_placeholder_m318": "gemini-3.8-flash-high",
    "model_placeholder_m319": "gemini-3.8-flash-medium", "model_placeholder_m320": "gemini-3.8-flash-low",
    "model_placeholder_m298": "gemini-3.7-flash-high", "model_placeholder_m299": "gemini-3.7-flash-medium",
    "model_placeholder_m300": "gemini-3.7-flash-low", "model_placeholder_m71": "gemini-3.6-flash-high",
    "model_placeholder_m72": "gemini-3.6-flash-medium", "model_placeholder_m73": "gemini-3.6-flash-low",
    "model_placeholder_m132": "gemini-3.5-flash-high", "model_placeholder_m133": "gemini-3.5-flash-high",
    "model_placeholder_m187": "gemini-3.5-flash-extra-low", "model_placeholder_m20": "gemini-3.5-flash-medium",
    "gemini-pro-default": "gemini-3.1-pro", "gemini-pro-agent": "gemini-3.1-pro",
    "gemini-3-flash": "gemini-3-flash-preview", "gemini-3-flash-c": "gemini-3-flash-preview",
    "gemini-3.1-pro-high": "gemini-3.1-pro", "gemini-3.1-pro-low": "gemini-3.1-pro",
    "gemini-3-pro-high": "gemini-3-pro", "gemini-3-pro-low": "gemini-3-pro",
    "model_openai_gpt_oss_120b_medium": "gpt-oss-120b",
}


def antigravity_roots():
    gemini = home() / ".gemini"
    defaults = [gemini / name / "conversations" for name in
                ("antigravity", "antigravity-cli", "antigravity-ide", "antigravity-backup", "antigravity-acp")]
    roots = env_roots("ANTIGRAVITY_DATA_DIR", defaults + [home() / ".config" / "antigravity" / "conversations"])
    return [root / "conversations" if (root / "conversations").is_dir() else root for root in roots]


def varint(blob, position):
    value = shift = 0
    while True:
        if position >= len(blob) or shift > 63:
            raise ValueError("Truncated protobuf")
        byte = blob[position]
        position += 1
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, position
        shift += 7


def proto(blob):
    """Decode one protobuf message into (field number, value) pairs."""
    fields, position = [], 0
    blob = bytes(blob or b"")
    while position < len(blob):
        tag, position = varint(blob, position)
        number, wire = tag >> 3, tag & 7
        if number == 0:
            raise ValueError("Invalid protobuf field")
        if wire == 0:
            value, position = varint(blob, position)
            fields.append((number, value))
        elif wire == 2:
            length, position = varint(blob, position)
            if position + length > len(blob):
                raise ValueError("Truncated protobuf")
            fields.append((number, blob[position:position + length]))
            position += length
        elif wire in (1, 5):
            position += 8 if wire == 1 else 4
        else:
            raise ValueError("Unsupported protobuf wire type")
    return fields


def proto_all(fields, number, kind):
    return [value for field, value in fields if field == number and isinstance(value, kind)]


def proto_int(fields, number):
    values = proto_all(fields, number, int)
    return values[-1] if values else 0


def proto_message(fields, number):
    values = proto_all(fields, number, bytes)
    return proto(values[0]) if values else []


def proto_text(fields, number):
    for value in reversed(proto_all(fields, number, bytes)):
        try:
            decoded = value.decode()
        except UnicodeDecodeError:
            continue
        if decoded.strip():
            return decoded
    return None


def proto_time(fields):
    seconds = proto_int(fields, 1)
    return seconds * 1000 + min(proto_int(fields, 2), 999_999_999) // 1_000_000 if seconds > 0 else None


def packed_ints(fields, number):
    found = proto_all(fields, number, int)
    for blob in proto_all(fields, number, bytes):
        position = 0
        try:
            while position < len(blob):
                value, position = varint(blob, position)
                found.append(value)
        except ValueError:
            pass
    return found


def antigravity_usage(fields):
    identities = [f"{prefix}:{value}" for prefix, value in (
        ("response", proto_text(fields, 11)), ("provider", proto_text(fields, 12)), ("message", proto_text(fields, 7)))
        if value]
    return dict(model_id=proto_int(fields, 1), input=proto_int(fields, 2), total_output=proto_int(fields, 3),
                cache_write=proto_int(fields, 4), cached=proto_int(fields, 5), reasoning=proto_int(fields, 9),
                visible=proto_int(fields, 10), identities=identities)


def antigravity_calls(fields, primary, retries):
    """The primary usage of a step or generation, then its retries. The retry list repeats the
    primary attempt once, which is dropped."""
    first = [antigravity_usage(proto(blob)) for blob in proto_all(fields, primary, bytes)[:1]]
    again = [antigravity_usage(proto_message(proto(blob), 2)) for blob in proto_all(fields, retries, bytes)]
    if first:
        mirror = next((call for call in again if all(call[key] == first[0][key] for key in call)), None)
        if mirror is not None:
            again.remove(mirror)
    return first + again


def antigravity_model(raw, model_id):
    if raw:
        base = raw.strip().lower().split("(")[0].strip()
        if base in ANTIGRAVITY_NAMES:
            return ANTIGRAVITY_NAMES[base]
        base = re.sub(r"\s+thinking$", "", base)
        return base.replace(" ", "-") if base.startswith(("gemini", "claude", "gpt")) else raw.strip()
    if model_id in ANTIGRAVITY_IDS:
        return ANTIGRAVITY_IDS[model_id]
    if model_id and model_id >= 1000:
        placeholder = f"model_placeholder_m{model_id - 1000}"
        return ANTIGRAVITY_NAMES.get(placeholder, placeholder)
    return None


def antigravity_entries(path, stats):
    tables = sqlite_tables(path)
    if "gen_metadata" not in tables:
        return
    session = path.stem
    fallback = None
    if "trajectory_metadata_blob" in tables:
        for row in sqlite_rows(path, "SELECT data FROM trajectory_metadata_blob ORDER BY rowid"):
            fallback = fallback or proto_time(proto_message(proto(row["data"]), 2))
    fallback = fallback or mtime(path)
    calls = []  # (identities, at, model, call)
    if "steps" in tables:
        for row in sqlite_rows(path, "SELECT idx, metadata FROM steps WHERE metadata IS NOT NULL ORDER BY idx"):
            fields = proto(row["metadata"])
            info = proto_message(fields, 24)
            model = antigravity_model(proto_text(info, 12) or proto_text(info, 8), proto_int(info, 1))
            at = proto_time(proto_message(fields, 8) or proto_message(fields, 1))
            for number, call in enumerate(antigravity_calls(fields, 9, 28)):
                calls.append((call["identities"] or [f"step:{session}:{row['idx']}:{number}"], at, model, call))
    current = None
    for row in sqlite_rows(path, "SELECT idx, data FROM gen_metadata ORDER BY idx"):
        root = proto(row["data"])
        fields = proto_message(root, 1)
        if not fields:
            continue
        # Continuation rows without a model use the last one named.
        current = antigravity_model(proto_text(fields, 19) or proto_text(fields, 21), proto_int(fields, 3)) or current
        at = proto_time(proto_message(proto_message(fields, 9), 4))
        steps = [f"step:{session}:{step}" for step in packed_ints(root, 2)]
        for number, call in enumerate(antigravity_calls(fields, 4, 17)):
            fallback_ids = [f"{step}:{number}" for step in steps] or [f"gen:{session}:{row['idx']}:{number}"]
            calls.append((call["identities"] or fallback_ids, at, current, call))
    # A step and its generation list the same call: calls that share an identity count once.
    merged, owner = [], {}
    for identities, at, model, call in calls:
        if not any(call[key] for key in ("input", "total_output", "cache_write", "cached", "reasoning", "visible")):
            continue
        index = next((owner[identity] for identity in identities if identity in owner), None)
        if index is None:
            index = len(merged)
            merged.append([identities[0], at, model, call])
        else:
            known = merged[index]
            known[1] = min(filter(None, (known[1], at)), default=None)
            known[2] = known[2] or model
        for identity in identities:
            owner.setdefault(identity, index)
    for key, at, model, call in merged:
        model = antigravity_model(None, call["model_id"]) if call["model_id"] and not model else model
        output = max(call["total_output"], call["visible"] + call["reasoning"])
        entry = usage("antigravity", f"{session}:{key}", at or fallback, model or "gemini-internal-model",
                      session=session, input=call["input"], cached=call["cached"], cache_write=call["cache_write"],
                      output=output, reasoning=call["reasoning"])
        if entry:
            yield entry


# Grok Build ----------------------------------------------------------------------------------------

def grok_roots():
    root = os.getenv("GROK_HOME", "").strip()
    return [Path(root).expanduser() if root else home() / ".grok"]


def grok_entries(path, stats):
    session, folder, default_model = path.parent.name, unquote(path.parent.parent.name), None
    summary = path.with_name("summary.json")
    if summary.is_file():
        try:
            data = obj(read_json(summary))
            info = obj(data.get("info"))
            session = text(info.get("id")) or session
            folder = text(info.get("cwd")) or text(data.get("git_root_dir")) or folder
            default_model = text(data.get("current_model_id"))
        except (OSError, ValueError):
            pass
    for row in jsonl(path, stats):
        params = obj(row.get("params"))
        update = obj(params.get("update"))
        record = obj(update.get("usage"))
        if update.get("sessionUpdate") != "turn_completed" or not record:
            continue  # turns count once they complete
        meta = obj(params.get("_meta"))
        # agentTimestampMs is in milliseconds, the envelope's timestamp in seconds.
        at = count(meta.get("agentTimestampMs")) or count(row.get("timestamp")) * 1000 or None
        by_model = obj(record.get("modelUsage")) or {default_model or "unknown": record}
        event = text(meta.get("eventId"))
        session_id = text(params.get("sessionId")) or session
        for model, part in sorted(by_model.items()):
            part = obj(part)
            # inputTokens includes cache reads and writes; reasoning is part of output.
            prompt = pick(part, "inputTokens")
            reads = min(pick(part, "cachedReadTokens"), prompt)
            writes = min(pick(part, "cacheCreationTokens"), prompt - reads)
            counts = dict(input=prompt - reads - writes, cached=reads, cache_write=writes,
                          output=pick(part, "outputTokens"))
            ticks = pick(part, "costUsdTicks")
            key = f"{event}:{model}" if event else digest(session_id, at, model, counts)
            entry = usage("grok", key, at, strip_suffixes(model, "-build"), session=session_id,
                          folder=folder if folder.startswith("/") else None, reasoning=pick(part, "reasoningTokens"),
                          recorded=cost(ticks / GROK_TICKS_PER_USD) if ticks else None, **counts)
            if entry:
                yield entry


# ZCode ---------------------------------------------------------------------------------------------

def zcode_databases():
    return existing(root / "cli" / "db" / "db.sqlite" for root in env_roots("ZCODE_HOME", [home() / ".zcode"]))


def zcode_entries(path, stats):
    tables = sqlite_tables(path)
    columns = tables.get("model_usage", set())
    required = {"id", "session_id", "started_at", "model_id", "status", "input_tokens", "output_tokens"}
    if not required <= columns or not {"id", "directory"} <= tables.get("session", set()):
        raise ValueError("Unrecognized ZCode database schema")

    def column(name, fallback="0"):
        return f"m.{name}" if name in columns else fallback

    for row in sqlite_rows(path, f"""
            SELECT m.id, m.session_id, m.started_at, m.model_id, m.input_tokens, m.output_tokens,
                   {column('cache_creation_input_tokens')} AS writes, {column('cache_read_input_tokens')} AS reads,
                   {column('computed_total_tokens', 'm.input_tokens + m.output_tokens')} AS total,
                   {column('provider_id', 'NULL')} AS provider, s.directory
            FROM model_usage m LEFT JOIN session s ON s.id = m.session_id WHERE m.status = 'completed'"""):
        # input_tokens includes both cache buckets.
        prompt = count(row["input_tokens"])
        reads = min(count(row["reads"]), prompt)
        writes = min(count(row["writes"]), prompt - reads)
        model = text(row["model_id"])
        provider = (text(row["provider"]) or "").lower()
        if model and "/" not in model and ("zai" in provider or (not provider and model.lower().startswith("glm"))):
            model = f"z-ai/{model.lower()}"
        entry = usage("zcode", str(row["id"]), millis(row["started_at"]), model, session=str(row["session_id"]),
                      folder=row["directory"], input=prompt - reads - writes, cached=reads, cache_write=writes,
                      output=count(row["output_tokens"]), total=count(row["total"]))
        if entry and model:
            yield entry


# DeepSeek Harness ------------------------------------------------------------------------------------

def dsh_roots():
    return env_roots("DSH_HOME", [home() / ".dsh"])


def dsh_files(roots):
    """Only the newest log generation in each session folder: older ones hold the same requests."""
    newest = {}
    for path in files(roots, "sessions/*/*/session*.jsonl", "sessions/*/*/session*.jsonl.zstd"):
        found = re.fullmatch(r"session(?:\.v(\d+))?\.jsonl(\.zstd)?", path.name)
        if found:
            rank = (int(found.group(1) or 1), not found.group(2))
            if path.parent not in newest or rank > newest[path.parent][0]:
                newest[path.parent] = (rank, path)
    return sorted(path for _, path in newest.values())


def dsh_entries(path, stats):
    header, route, seeded, found = None, (None, None), False, []
    for row in jsonl(path, stats):
        if header is None:
            if row.get("type") != "session":
                return
            header, seeded = row, bool(row.get("isSeeded"))
            continue
        data = obj(row.get("data"))
        kind = row.get("type")
        if kind in ("request/header", "request/context"):
            source = obj(obj(data.get("header")).get("config")) if kind == "request/header" else data
            if text(source.get("model")):
                route = (text(source.get("provider")), text(source.get("model")))
        elif kind == "session/end-seed":
            if data.get("inherited"):
                found, seeded = [], False  # everything so far was copied from the parent session
        elif kind in ("assistant/message", "assistant/attempt"):
            record = obj(data.get("usage"))
            for chunk in reversed(data.get("stream") or [] if not record else []):
                inner = obj(obj(chunk).get("chunk"))
                if obj(chunk).get("type") == "chunk" and inner.get("type") == "usage" and obj(inner.get("usage")):
                    record = obj(inner.get("usage"))  # the last usage the stream reported
                    break
            if record:
                found.append((row, record, route))
        elif kind == "compaction/summary" and obj(data.get("usage")):
            found.append((row, obj(data.get("usage")), (text(data.get("provider")), text(data.get("model")))))
    if header is None or seeded:
        return  # a fork's log cut off before its own requests holds only its parent's usage
    session = text(header.get("id")) or path.parent.name
    for row, record, (provider, model) in found:
        name = model or "unknown"
        if provider and not provider.startswith("deepseek"):
            name = prefixed(provider, name)
        key = f"{session}:{row['seq']}" if type(row.get("seq")) is int else digest(session, row)
        entry = usage("dsh", key, millis(row.get("time")) or millis(header.get("createdAt")), name, session=session,
                      folder=text(header.get("cwd")), input=pick(record, "inputTokens"),
                      output=pick(record, "outputTokens"), cached=pick(record, "cacheReadTokens"),
                      cache_write=pick(record, "cacheWriteTokens"), total=pick(record, "totalTokens"))
        if entry:
            yield entry


# Registry ------------------------------------------------------------------------------------------

NAMES = {"amp": "Amp", "droid": "Droid", "codebuff": "Codebuff", "cline": "Cline", "hermes": "Hermes Agent",
         "pi": "pi", "openclaw": "OpenClaw", "goose": "Goose", "kilo": "Kilo", "kimi": "Kimi", "qwen": "Qwen Code",
         "copilot": "GitHub Copilot CLI", "gemini": "Gemini CLI", "antigravity": "Antigravity", "grok": "Grok Build",
         "zcode": "ZCode", "dsh": "DeepSeek Harness"}


def file_sources():
    sources = []

    def add(name, roots, read, list_files, database=False):
        source = importers.FileSource(name, roots, read, files=lambda: list_files(roots))
        source.database = database
        sources.append(source)

    add("amp", [root / "threads" for root in amp_roots()], amp_entries, lambda roots: files(roots, "**/*.json"))
    add("droid", droid_roots(), droid_entries, lambda roots: files(roots, "**/*.settings.json"))
    add("codebuff", codebuff_roots(), codebuff_entries,
        lambda roots: files(roots, "projects/*/chats/*/chat-messages.json"))
    add("cline", cline_roots(), cline_entries, cline_files)
    add("pi", pi_roots(), pi_entries,
        lambda roots: files(roots, "**/*.jsonl", skip=lambda path: "subagent-artifacts" in path.parts))
    add("openclaw", openclaw_roots(), openclaw_entries, openclaw_files, database=True)
    add("kimi", kimi_roots(), kimi_entries, kimi_files)
    add("qwen", qwen_roots(), qwen_entries, qwen_files)
    add("copilot", copilot_roots(), copilot_entries, lambda roots: files(roots, "session-state/*/events.jsonl"))
    add("gemini", gemini_roots(), gemini_entries, lambda roots: files(roots, "*/chats/*.json", "*/chats/*.jsonl"))
    add("grok", grok_roots(), grok_entries, lambda roots: files(roots, "sessions/*/*/updates.jsonl"))
    add("dsh", dsh_roots(), dsh_entries, dsh_files)
    add("antigravity", antigravity_roots(), antigravity_entries, lambda roots: files(roots, "*.db"), database=True)
    for name, databases, read in (("hermes", hermes_databases, hermes_entries), ("goose", goose_databases, goose_entries),
                                  ("kilo", kilo_databases, kilo_entries), ("zcode", zcode_databases, zcode_entries)):
        found = databases()
        add(name, sorted({path.parent for path in found}), read, lambda roots, found=found: found, database=True)
    return sources
