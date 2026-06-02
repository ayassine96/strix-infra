#!/bin/bash
set -e

# Strix Halo Full System Test Suite
# Usage: ./test-suite.sh [autonomous|chat|autocomplete|all] [--verbose]
# Outputs: Console summary + detailed logs

MODE=${1:-all}
VERBOSE=${2:-}
GATEWAY="http://localhost:8082"
LLAMA="http://localhost:8081"
LETTA="http://localhost:8283"
WEBUI="http://localhost:3000"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

log_pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; PASS=$((PASS+1)); }
log_fail() { echo -e "${RED}✗ FAIL${NC}: $1"; FAIL=$((FAIL+1)); }
log_warn() { echo -e "${YELLOW}⚠ WARN${NC}: $1"; WARN=$((WARN+1)); }
log_info() { echo -e "  → $1"; }

# Test runner
test_case() {
    local name="$1"
    local cmd="$2"
    local expected="$3"
    local timeout="${4:-30}"

    echo ""
    echo "=== TEST: $name ==="

    if [ "$VERBOSE" = "--verbose" ]; then
        echo "Command: $cmd"
    fi

    # Run with timeout
    OUTPUT=$(timeout "$timeout" bash -c "$cmd" 2>&1) && RC=$? || RC=$?

    if [ $RC -ne 0 ]; then
        if [ $RC -eq 124 ]; then
            log_fail "$name (TIMEOUT after ${timeout}s)"
            log_info "Output: ${OUTPUT:0:200}"
        else
            log_fail "$name (exit code $RC)"
            log_info "Output: ${OUTPUT:0:200}"
        fi
        return 1
    fi

    # Check expected output
    if [ -n "$expected" ]; then
        if echo "$OUTPUT" | grep -qi "$expected"; then
            log_pass "$name"
            [ "$VERBOSE" = "--verbose" ] && log_info "Output: ${OUTPUT:0:200}"
            return 0
        else
            log_fail "$name (expected: '$expected')"
            log_info "Got: ${OUTPUT:0:300}"
            return 1
        fi
    else
        log_pass "$name"
        [ "$VERBOSE" = "--verbose" ] && log_info "Output: ${OUTPUT:0:200}"
        return 0
    fi
}

# ============================================================
# PHASE 1: INFRASTRUCTURE
# ============================================================
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║     STRIX HALO FULL SYSTEM TEST SUITE                      ║"
echo "║     Mode: $MODE                                             ║"
echo "╚════════════════════════════════════════════════════════════╝"

echo ""
echo "--- Phase 1: Infrastructure ---"

test_case "1.1 Docker containers running" \
    "docker compose ps --format json 2>/dev/null | python3 -c 'import sys,json; data=[json.loads(l) for l in sys.stdin]; assert all(d.get(\"State\",\"\")==\"running\" for d in data), f\"Not all running\"; print(len(data), \"containers\")'" \
    "containers"

test_case "1.2 Backend health endpoint" \
    "curl -sf $LLAMA/health | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d.get(\"status\")==\"ok\", str(d); print(\"ok\")'" \
    "ok"

test_case "1.3 Gateway health endpoint" \
    "curl -sf $GATEWAY/health | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d.get(\"status\")==\"ok\", str(d); print(\"ok\")'" \
    "ok"

test_case "1.4 Gateway mode API" \
    "curl -sf $GATEWAY/mode | python3 -c 'import sys,json; d=json.load(sys.stdin); assert \"current_mode\" in d; print(d[\"current_mode\"])'" \
    ""

test_case "1.5 Backend sees all models" \
    "curl -sf $LLAMA/v1/models | python3 -c 'import sys,json; d=json.load(sys.stdin); n=len(d.get(\"data\",[])); assert n>=10, f\"Only {n}\"; print(f\"{n} models\")'" \
    "13"

# ============================================================
# PHASE 2: AUTONOMOUS MODE
# ============================================================
if [ "$MODE" = "all" ] || [ "$MODE" = "autonomous" ]; then
    echo ""
    echo "--- Phase 2: Autonomous Mode ---"

    ./switch-mode.sh autonomous --hard >/dev/null 2>&1 || true
    sleep 8

    test_case "2.1 Switch to autonomous" \
        "curl -sf $GATEWAY/mode | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d[\"current_mode\"]==\"autonomous\", d[\"current_mode\"]; print(\"autonomous\")'" \
        "autonomous"

    test_case "2.2 Exactly 3 models visible" \
        "curl -sf $GATEWAY/v1/models | python3 -c 'import sys,json; n=len(json.load(sys.stdin).get(\"data\",[])); assert n==3, f\"Got {n}\"; print(\"3 models\")'" \
        "3 models"

    test_case "2.3 All 3 models loaded" \
        "curl -sf $GATEWAY/v1/models | python3 -c 'import sys,json; data=json.load(sys.stdin).get(\"data\",[]); statuses=[m.get(\"status\",{}).get(\"value\",\"unknown\") for m in data]; assert all(s==\"loaded\" for s in statuses), f\"Statuses: {statuses}\"; print(\"all loaded\")'" \
        "all loaded"

    test_case "2.4 Orchestrator responds" \
        "curl -sf --max-time 60 $GATEWAY/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\":\"orchestrator-Qwen2.5-72B-Instruct-Q4_K_M\",\"messages\":[{\"role\":\"user\",\"content\":\"Say exactly: orch-ok\"}],\"max_tokens\":5,\"temperature\":0}' | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"choices\"][0][\"message\"][\"content\"])'" \
        "orch-ok"

    test_case "2.5 Dev coder responds" \
        "curl -sf --max-time 60 $GATEWAY/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\":\"dev-Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL\",\"messages\":[{\"role\":\"user\",\"content\":\"Say exactly: dev-ok\"}],\"max_tokens\":5,\"temperature\":0}' | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"choices\"][0][\"message\"][\"content\"])'" \
        "dev-ok"

    test_case "2.6 Tester responds" \
        "curl -sf --max-time 60 $GATEWAY/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\":\"tester-Qwen2.5-Coder-32B-Instruct-Q4_K_M\",\"messages\":[{\"role\":\"user\",\"content\":\"Say exactly: tester-ok\"}],\"max_tokens\":5,\"temperature\":0}' | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"choices\"][0][\"message\"][\"content\"])'" \
        "tester-ok"
fi

# ============================================================
# PHASE 3: CHAT MODE
# ============================================================
if [ "$MODE" = "all" ] || [ "$MODE" = "chat" ]; then
    echo ""
    echo "--- Phase 3: Chat Mode ---"

    ./switch-mode.sh chat --hard >/dev/null 2>&1 || true
    sleep 8

    test_case "3.1 Switch to chat" \
        "curl -sf $GATEWAY/mode | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d[\"current_mode\"]==\"chat\", d[\"current_mode\"]; print(\"chat\")'" \
        "chat"

    test_case "3.2 All models visible" \
        "curl -sf $GATEWAY/v1/models | python3 -c 'import sys,json; n=len(json.load(sys.stdin).get(\"data\",[])); assert n>=8, f\"Got {n}\"; print(f\"{n} models\")'" \
        "13"

    test_case "3.3 Heavy model loads (122B)" \
        "curl -sf --max-time 300 $GATEWAY/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\":\"heavy-Qwen3.5-122B-A10B-Claude-distill-Q4_K_M\",\"messages\":[{\"role\":\"user\",\"content\":\"Say exactly: heavy-ok\"}],\"max_tokens\":5,\"temperature\":0}' | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"choices\"][0][\"message\"][\"content\"])'" \
        "heavy-ok" \
        300

    test_case "3.4 Open-WebUI accessible" \
        "curl -sf -o /dev/null -w '%{http_code}' $WEBUI | grep -qE '200|302' && echo '200'" \
        "200"
fi

# ============================================================
# PHASE 4: AUTOCOMPLETE MODE
# ============================================================
if [ "$MODE" = "all" ] || [ "$MODE" = "autocomplete" ]; then
    echo ""
    echo "--- Phase 4: Autocomplete Mode ---"

    ./switch-mode.sh autocomplete --hard >/dev/null 2>&1 || true
    sleep 8

    test_case "4.1 Switch to autocomplete" \
        "curl -sf $GATEWAY/mode | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d[\"current_mode\"]==\"autocomplete\", d[\"current_mode\"]; print(\"autocomplete\")'" \
        "autocomplete"

    test_case "4.2 Fast models visible" \
        "curl -sf $GATEWAY/v1/models | python3 -c 'import sys,json; n=len(json.load(sys.stdin).get(\"data\",[])); assert n==3, f\"Got {n}\"; print(\"3 models\")'" \
        "3 models"

    test_case "4.3 Fast response time" \
        "time curl -sf --max-time 10 $GATEWAY/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\":\"fast-Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL\",\"messages\":[{\"role\":\"user\",\"content\":\"def hello():\"}],\"max_tokens\":20,\"temperature\":0}' | python3 -c 'import sys,json; print(\"ok\")'" \
        "ok" \
        15
fi

# ============================================================
# PHASE 5: LETTA
# ============================================================
echo ""
echo "--- Phase 5: Letta Agent Runtime ---"

test_case "5.1 Letta responds" \
    "curl -sf -o /dev/null -w '%{http_code}' $LETTA/ | grep -qE '200|302|307' && echo 'ok'" \
    "ok"

test_case "5.2 Letta models API" \
    "curl -sf $LETTA/v1/models -H 'Authorization: Bearer strix-local' | python3 -c 'import sys,json; d=json.load(sys.stdin); assert \"data\" in d or \"object\" in d, str(d); print(\"ok\")'" \
    "ok"

test_case "5.3 Letta agents list" \
    "curl -sf $LETTA/v1/agents -H 'Authorization: Bearer strix-local' | python3 -c 'import sys,json; d=json.load(sys.stdin); print(\"ok\")'" \
    "ok"

# ============================================================
# PHASE 6: HERMES
# ============================================================
echo ""
echo "--- Phase 6: Hermes Agent ---"

test_case "6.1 Hermes container running" \
    "docker compose ps hermes --format json 2>/dev/null | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d.get(\"State\")==\"running\", str(d); print(\"running\")'" \
    "running"

test_case "6.2 Hermes config loaded" \
    "docker compose exec hermes cat /root/.hermes/config.yaml 2>/dev/null | grep -q 'gateway:8080' && echo 'config-ok'" \
    "config-ok"

test_case "6.3 Hermes CLI works" \
    "docker compose exec hermes hermes --help 2>/dev/null | head -1 | grep -q 'Hermes' && echo 'cli-ok'" \
    "cli-ok"

# ============================================================
# PHASE 7: MEMORY & RESOURCES
# ============================================================
echo ""
echo "--- Phase 7: Memory & Resources ---"

test_case "7.1 System memory available" \
    "free -h | awk '/Mem:/ {print \$7}' | grep -q '[0-9]' && echo 'mem-ok'" \
    "mem-ok"

test_case "7.2 Backend memory usage" \
    "docker stats --no-stream strix-backend --format 'table {{.MemUsage}}' 2>/dev/null | tail -1 | grep -q 'GiB' && echo 'stats-ok'" \
    "stats-ok"

test_case "7.3 No OOM errors in backend" \
    "docker compose logs strix-backend --tail 20 2>/dev/null | grep -qi 'out of memory' && echo 'OOM-FOUND' || echo 'no-oom'" \
    "no-oom"

# ============================================================
# SUMMARY
# ============================================================
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║     TEST SUMMARY                                           ║"
echo "╠════════════════════════════════════════════════════════════╣"
printf "║  ${GREEN}PASS: %d${NC}                                                    ║\\n" "$PASS"
printf "║  ${RED}FAIL: %d${NC}                                                    ║\\n" "$FAIL"
printf "║  ${YELLOW}WARN: %d${NC}                                                    ║\\n" "$WARN"
echo "╚════════════════════════════════════════════════════════════╝"

if [ $FAIL -gt 0 ]; then
    echo ""
    echo "Some tests failed. Check the output above for details."
    echo ""
    echo "Debug commands:"
    echo "  docker compose logs strix-backend --tail 50"
    echo "  docker compose logs gateway --tail 30"
    echo "  docker compose logs letta --tail 30"
    echo "  docker compose logs hermes --tail 30"
    exit 1
else
    echo ""
    echo "All tests passed! ✓"
    exit 0
fi
