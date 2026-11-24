#!/bin/bash
# End-to-end check of the smsbackup-mcp binary: imports the sample zip into a throwaway
# database, then talks MCP over stdio (initialize, tools/list, search, conversation, calls).
#   ./Scripts/mcp-smoke-test.sh [path/to/smsbackup-mcp]
set -euo pipefail
cd "$(dirname "$0")/.."

BIN="${1:-$(swift build -c release --show-bin-path)/smsbackup-mcp}"
[[ -x "$BIN" ]] || { echo "smsbackup-mcp not found at: $BIN"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
DB="$WORK/test.sqlite"

echo "==> CLI import"
"$BIN" --db "$DB" import Samples/sample-backup.zip
"$BIN" --db "$DB" stats

echo "==> MCP session"
{
  echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke-test","version":"1"}}}'
  echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  echo '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_messages","arguments":{"query":"lighthouse"}}}'
  echo '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_conversations","arguments":{}}}'
  echo '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"search_calls","arguments":{"type":"missed"}}}'
  echo '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"get_stats","arguments":{}}}'
  echo '{"jsonrpc":"2.0","id":7,"method":"no/such/method"}'
} | "$BIN" --db "$DB" > "$WORK/out.jsonl" 2> "$WORK/err.log"

python3 - "$WORK/out.jsonl" <<'PY'
import json, sys
lines = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
by_id = {m.get("id"): m for m in lines}

def check(cond, msg):
    if not cond:
        print("FAIL:", msg)
        print(json.dumps(lines, indent=2)[:4000])
        sys.exit(1)
    print("ok  ", msg)

def tool_json(i):
    r = by_id[i]["result"]
    check(not r.get("isError"), f"tool call {i} succeeded")
    return json.loads(r["content"][0]["text"])

check(by_id.get(1, {}).get("result", {}).get("protocolVersion") == "2025-06-18", "initialize negotiates protocol version")
check(len(lines) == 7, "notification produced no response (7 responses for 7 requests)")
names = {t["name"] for t in by_id[2]["result"]["tools"]}
check({"search_messages", "list_conversations", "get_conversation", "get_message",
       "get_attachment", "search_calls", "get_stats", "import_backup"} <= names, "tools/list has all 8 tools")
hits = tool_json(3)
check(hits["count"] >= 1 and any("ighthouse" in m.get("text", "") for m in hits["messages"]), "full-text search finds 'lighthouse'")
convs = tool_json(4)
check(convs["count"] >= 3, "conversations listed")
calls = tool_json(5)
check(calls["count"] == 1 and calls["calls"][0]["type"] == "missed", "call search filters by type")
stats = tool_json(6)
check(stats["messages"] >= 8 and stats["calls"] == 4, "stats reflect sample import")
check(by_id[7]["error"]["code"] == -32601, "unknown method returns -32601")
print("All MCP smoke tests passed.")
PY
