#!/usr/bin/env bash
# stage6-common.sh — Shared MCP helpers for stage6 sub-scripts
# Source this file, do not execute directly.

set -euo pipefail

# Env var defaults (callers may set these before sourcing)
GLB_INPUT="${GLB_INPUT:-asset_00001_.glb}"
ASSET_NAME="${ASSET_NAME:-asset}"
MCP_URL="${MCP_URL:-http://localhost:8000}"
RAW_3D_DIR="${RAW_3D_DIR:-/assets/raw_3d}"
PBR_DIR="${PBR_DIR:-/assets/pbr_maps}"
FINAL_DIR="${FINAL_DIR:-/assets/final_glb}"
ASSET_TYPE="${ASSET_TYPE:-creature}"

# --- MCP helpers (same pattern as test-mcp-e2e.sh) ---

init_mcp_session() {
    local request_body
    request_body=$(cat <<EOF
{
  "jsonrpc": "2.0",
  "id": 0,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-03-26",
    "capabilities": {},
    "clientInfo": {
      "name": "stage6-test",
      "version": "1.0.0"
    }
  }
}
EOF
    )

    local tmpheaders
    tmpheaders=$(mktemp)

    curl -sf --max-time 10 \
        -D "$tmpheaders" \
        -o /dev/null \
        -X POST \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -d "$request_body" \
        "${MCP_URL}/mcp" 2>/dev/null || true

    MCP_SESSION_ID=$(grep -i 'mcp-session-id' "$tmpheaders" 2>/dev/null | tr -d '\r' | awk '{print $2}')
    rm -f "$tmpheaders"
}

call_mcp_tool() {
    local tool_name="$1"
    shift
    local arguments="${1:-\{\}}"

    local request_body
    request_body=$(cat <<EOF
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "${tool_name}",
    "arguments": ${arguments}
  }
}
EOF
    )

    local session_hdr=""
    if [[ -n "$MCP_SESSION_ID" ]]; then
        session_hdr="-H"
    fi

    local response
    response=$(curl -sf --max-time 120 \
        -X POST \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        ${session_hdr:+"$session_hdr"} ${MCP_SESSION_ID:+"Mcp-Session-Id: $MCP_SESSION_ID"} \
        -d "$request_body" \
        "${MCP_URL}/mcp" 2>/dev/null \
    | grep '^data: ' | sed 's/^data: //')

    echo "$response"
}

run_blender_code() {
    local code="$1"
    local arguments
    arguments="{\"code\": $(echo "$code" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}"
    call_mcp_tool "execute_blender_code" "$arguments"
}

check_mcp_error() {
    local response="$1"
    local step="$2"
    # Check both isError flag AND error text (MCP server often returns isError:false with error text)
    if echo "$response" | grep -qi '"isError":\s*true' || \
       echo "$response" | grep -qi 'Error executing code:'; then
        echo "  ❌ $step FAILED"
        echo "$response" | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        data = json.loads(line)
        result = data.get('result', {})
        for item in result.get('content', []):
            print('    ', item.get('text', '')[:200])
    except: print('    ', line[:200])
" 2>/dev/null || echo "$response" | head -5
        return 1
    fi
    return 0
}

# --- Health check + MCP init (skip if already initialized) ---

if [[ -z "${MCP_SESSION_ID:-}" ]]; then
    MCP_SESSION_ID=""

    echo ""
    echo "── Checking Blender MCP server ──"
    if curl -sf --max-time 30 "${MCP_URL}/mcp" -X POST \
         -H "Content-Type: application/json" \
         -H "Accept: application/json, text/event-stream" \
         -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
         2>/dev/null | grep -q '^data: '; then
        echo "  ✅ MCP server reachable"
    else
        echo "  ❌ MCP server unreachable at $MCP_URL"
        exit 1
    fi

    init_mcp_session
    echo ""
fi
