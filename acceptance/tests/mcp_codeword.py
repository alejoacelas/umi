"""A minimal MCP server over stdio with one tool, `codeword`, that returns the word given on the
command line. Used by the real-agent tests to check that a worker loads a project's MCP servers."""

import json
import sys

WORD = sys.argv[1] if len(sys.argv) > 1 else "none"


def reply(rid, result):
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": rid, "result": result}) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    method, rid = msg.get("method"), msg.get("id")
    if rid is None:
        continue
    if method == "initialize":
        reply(rid, {"protocolVersion": msg.get("params", {}).get("protocolVersion", "2025-06-18"),
                    "capabilities": {"tools": {}}, "serverInfo": {"name": "codeword", "version": "1.0"}})
    elif method == "tools/list":
        reply(rid, {"tools": [{"name": "codeword", "description": "Returns the project's secret codeword.",
                               "inputSchema": {"type": "object", "properties": {}}}]})
    elif method == "tools/call":
        reply(rid, {"content": [{"type": "text", "text": WORD}]})
    else:
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": rid,
                                     "error": {"code": -32601, "message": "method not found"}}) + "\n")
        sys.stdout.flush()
