"""A local MCP tools server for clients using the 2025 initialization handshake."""

import json
import sqlite3

from . import reports, store

VERSIONS = {"2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"}
DATE_FIELDS = {
    "start": {"type": "string", "format": "date", "description": "Inclusive date in the local reporting timezone."},
    "end": {"type": "string", "format": "date", "description": "Exclusive date in the local reporting timezone."},
    "period": {"type": "string", "enum": ["week", "month"]},
}


def tool(name, description, properties, required=()):
    return {
        "name": name, "description": description, "annotations": {"readOnlyHint": True, "openWorldHint": False},
        "inputSchema": {"type": "object", "properties": properties,
                        "required": list(required), "additionalProperties": False},
    }


TOOLS = [
    tool("list_projects", "List configured projects, clients, billing classification and mapped folders.", {}),
    tool("usage_report", "Read human hours, agent runtime and tokens, actual expenses and configured estimates.",
         {**DATE_FIELDS, "client": {"type": "string"}, "project": {"type": "string"}, "task": {"type": "string"}}),
    tool("review_unassigned", "List captured activity whose folder is not mapped to a project.", DATE_FIELDS),
]

OPERATIONS = {
    "list_projects": store.project_list,
    "usage_report": reports.report,
    "review_unassigned": reports.review,
}


def validate(name, args):
    if not isinstance(args, dict):
        raise ValueError("Tool arguments must be an object")
    schema = next(item["inputSchema"] for item in TOOLS if item["name"] == name)
    allowed = schema["properties"]
    for key in schema["required"]:
        if key not in args:
            raise ValueError(f"Missing required argument: {key}")
    for key, value in args.items():
        if key not in allowed:
            raise ValueError(f"Unknown argument: {key}")
        expected = str if allowed[key]["type"] == "string" else bool
        if not isinstance(value, expected):
            raise ValueError(f"Invalid value for {key}")
        if "enum" in allowed[key] and value not in allowed[key]["enum"]:
            raise ValueError(f"Invalid value for {key}")


def result(data, is_error=False):
    return {"content": [{"type": "text", "text": json.dumps(data, ensure_ascii=False)}], "isError": is_error}


def error_response(request_id, code, message):
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def serve(path, stdin, stdout):
    initialized = False
    for line in stdin:
        try:
            message = json.loads(line)
        except ValueError:
            send(stdout, error_response(None, -32700, "Parse error"))
            continue
        if not isinstance(message, dict) or message.get("jsonrpc") != "2.0" or not isinstance(message.get("method"), str):
            send(stdout, error_response(None, -32600, "Invalid request"))
            continue
        method, request_id = message["method"], message.get("id")
        if "id" not in message:
            continue
        params = message.get("params", {})
        if not isinstance(params, dict):
            send(stdout, error_response(request_id, -32602, "Invalid params"))
            continue
        if method == "initialize":
            version = params.get("protocolVersion")
            protocol = version if isinstance(version, str) and version in VERSIONS else "2025-11-25"
            data = {
                "protocolVersion": protocol, "serverInfo": {"name": "tracker", "version": "0.1.0"},
                "capabilities": {"tools": {"listChanged": False}},
                "instructions": "Tracker returns local project, time, usage, and cost metadata. CLI sync imports new agent activity.",
            }
            initialized = True
        elif method == "ping":
            data = {}
        elif method == "tools/list" and initialized:
            data = {"tools": TOOLS}
        elif method == "tools/call" and initialized:
            name = params.get("name")
            if not isinstance(name, str) or name not in OPERATIONS:
                send(stdout, error_response(request_id, -32602, "Unknown tool"))
                continue
            args = params.get("arguments", {})
            try:
                validate(name, args)
                with store.database(path) as conn:
                    data = result(OPERATIONS[name](conn, **args))
            except (ValueError, OSError, sqlite3.Error) as exc:
                data = result({"error": str(exc)}, is_error=True)
        else:
            send(stdout, error_response(request_id, -32601, "Method not found"))
            continue
        send(stdout, {"jsonrpc": "2.0", "id": request_id, "result": data})


def send(stdout, message):
    print(json.dumps(message, ensure_ascii=True), file=stdout, flush=True)
