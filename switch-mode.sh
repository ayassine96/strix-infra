#!/bin/bash
set -e

MODE=${1:-chat}
HARD=${2:-}
GATEWAY="http://localhost:8082"
LLAMA="http://localhost:8081"

if [[ "$MODE" != "autonomous" && "$MODE" != "chat" && "$MODE" != "autocomplete" ]]; then
    echo "Usage: $0 {autonomous|chat|autocomplete} [--hard]"
    echo "  --hard  Restart strix-backend to clear all loaded models"
    exit 1
fi

echo "=== Switching to Mode: $MODE ==="

# Hard reset: restart backend to free all memory
if [[ "$HARD" == "--hard" ]]; then
    echo "HARD MODE: Restarting strix-backend..."
    docker compose stop strix-backend
    docker compose rm -f strix-backend
    docker compose up -d strix-backend
    
    # Wait for llama-server to actually be ready (not just container started)
    echo "Waiting for llama-server to initialize..."
    for i in {1..60}; do
        if curl -s "$LLAMA/health" >/dev/null 2>&1; then
            echo "  Backend ready after ${i}s"
            break
        fi
        sleep 1
    done
    
    # Extra wait for model preset parsing
    sleep 3
fi

# Ensure core is up
docker compose up -d strix-backend gateway

# Stop all frontends to prevent cross-mode contention
echo "Pausing inactive frontends..."
docker compose stop letta 2>/dev/null || true
docker compose stop open-webui 2>/dev/null || true
docker compose stop hermes 2>/dev/null || true

# Start only the frontend for this mode
case $MODE in
  autonomous)
    echo "Starting Letta (Agent Runtime)..."
    docker compose up -d letta
    ;;
  chat)
    echo "Starting Open-WebUI..."
    docker compose up -d open-webui
    ;;
  autocomplete)
    echo "Autocomplete mode active."
    ;;
esac

# Verify gateway is alive
echo ""
echo "Checking Gateway..."
for i in {1..30}; do
    if curl -s -o /dev/null -w "%{http_code}" "$GATEWAY/health" | grep -q "200"; then
        break
    fi
    sleep 1
done

if ! curl -s -o /dev/null -w "%{http_code}" "$GATEWAY/health" | grep -q "200"; then
    echo "ERROR: Gateway not responding on $GATEWAY"
    exit 1
fi

# Switch mode (with longer timeout for heavy model preloading)
echo ""
echo "Configuring Gateway mode..."
RESULT=$(curl -s -X POST "$GATEWAY/mode/$MODE" --max-time 600 || echo '{"error":"curl failed"}')
echo "$RESULT" | python3 -m json.tool 2>/dev/null || echo "$RESULT"

# Wait for preloading to complete (poll until we see the right count)
echo ""
echo "Waiting for models to load..."
EXPECTED_COUNT=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('active_models',[])))" 2>/dev/null || echo "0")

for i in {1..120}; do
    LOADED=$(curl -s "$GATEWAY/v1/models" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('data',[])))" 2>/dev/null || echo "0")
    if [[ "$LOADED" == "$EXPECTED_COUNT" && "$EXPECTED_COUNT" != "0" ]]; then
        echo "  All $EXPECTED_COUNT models loaded after ${i}s"
        break
    fi
    sleep 1
done

# Final verification
echo ""
echo "=== Loaded Models ==="
curl -s "$GATEWAY/v1/models" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(f'{len(data.get(\"data\",[]))} models loaded:')
for m in data.get('data', []):
    status = m.get('status', {}).get('value', 'unknown')
    print(f'  - {m[\"id\"]}: {status}')
" 2>/dev/null || echo "  (could not verify)"

echo ""
echo "=== Mode '$MODE' is ready ==="
case $MODE in
  autonomous)
    echo "Letta Agents:  http://localhost:8283"
    echo "Gateway API:   $GATEWAY/v1"
    echo "Models: Orchestrator + Dev + Tester"
    ;;
  chat)
    echo "Open-WebUI:    http://localhost:3000"
    echo "Gateway API:   $GATEWAY/v1"
    echo "All models available. LRU auto-eviction active."
    ;;
  autocomplete)
    echo "Gateway API:   $GATEWAY/v1"
    echo "Models: fast coder + fast general + utility"
    ;;
esac

# #!/bin/bash
# set -e

# MODE=${1:-chat}
# HARD=${2:-}
# GATEWAY="http://localhost:8082"

# if [[ "$MODE" != "autonomous" && "$MODE" != "chat" && "$MODE" != "autocomplete" ]]; then
#     echo "Usage: $0 {autonomous|chat|autocomplete} [--hard]"
#     echo "  --hard  Restart strix-backend to clear all loaded models (slower, but guaranteed clean memory)"
#     exit 1
# fi

# echo "=== Switching to Mode: $MODE ==="

# # Hard reset: restart backend to free all memory
# if [[ "$HARD" == "--hard" ]]; then
#     echo "HARD MODE: Restarting strix-backend to clear memory..."
#     docker compose stop strix-backend
#     docker compose rm -f strix-backend
#     docker compose up -d strix-backend
#     sleep 5
# fi

# # Ensure core is up
# docker compose up -d strix-backend gateway

# # Stop all frontends to prevent cross-mode contention
# echo "Pausing inactive frontends..."
# docker compose stop letta 2>/dev/null || true
# docker compose stop open-webui 2>/dev/null || true

# # Start only the frontend for this mode
# case $MODE in
#   autonomous)
#     echo "Starting Letta (Agent Runtime)..."
#     docker compose up -d letta
#     ;;
#   chat)
#     echo "Starting Open-WebUI..."
#     docker compose up -d open-webui
#     ;;
#   autocomplete)
#     echo "Autocomplete mode active. Connect clients to $GATEWAY/v1"
#     ;;
# esac

# # Verify gateway is alive
# echo ""
# echo "Checking Gateway..."
# if ! curl -s -o /dev/null -w "%{http_code}" "$GATEWAY/health" | grep -q "200"; then
#     echo "ERROR: Gateway not responding on $GATEWAY"
#     echo "Check: docker compose logs gateway"
#     exit 1
# fi

# # Switch mode
# echo "Configuring Gateway mode..."
# RESULT=$(curl -s -X POST "$GATEWAY/mode/$MODE" || echo '{"error":"curl failed"}')
# echo "$RESULT" | python3 -m json.tool 2>/dev/null || echo "$RESULT"

# # Show current state
# echo ""
# echo "=== Current State ==="
# curl -s "$GATEWAY/mode" | python3 -m json.tool 2>/dev/null || curl -s "$GATEWAY/mode"

# echo ""
# echo "=== Mode '$MODE' is ready ==="
# case $MODE in
#   autonomous)
#     echo "Letta Agents:  http://localhost:8283"
#     echo "Gateway API:   $GATEWAY/v1"
#     echo "Pinned models: orchestrator-Qwen2.5-72B + Coder-Qwen3.6-35B + tool-caller-Qwen2.5-32B"
#     echo ""
#     echo "NOTE: These 3 models are now loaded and locked in memory."
#     echo "      No other models can be loaded until you switch modes."
#     ;;
#   chat)
#     echo "Open-WebUI:    http://localhost:3000"
#     echo "Gateway API:   $GATEWAY/v1"
#     echo "All models available. LRU auto-eviction active."
#     echo ""
#     echo "NOTE: Refresh Open-WebUI (Ctrl+Shift+R) to see the full model list."
#     ;;
#   autocomplete)
#     echo "Gateway API:   $GATEWAY/v1"
#     echo "Models:        tool-caller-Qwen2.5-32B + Carnice-9B"
#     echo ""
#     echo "VS Code/Continue.dev settings:"
#     echo "  Provider: OpenAI-compatible"
#     echo "  API URL:  $GATEWAY/v1"
#     echo "  Model:    tool-caller-Qwen2.5-Coder-32B-Instruct-Q4_K_M"
#     ;;
# esac