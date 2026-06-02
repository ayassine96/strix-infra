# Strix Halo — infra-node

Self-hosted local LLM inference infrastructure running on **AMD Strix Halo** hardware via ROCm. Hosts 13+ GGUF models across 3 operational modes, managed through a custom FastAPI gateway for model lifecycle and visibility control.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                     Caddy (optional)                     │
│             reverse_proxy /v1/* → backend                │
│             reverse_proxy /* → open-webui               │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  ~/Desktop/models    models.ini                         │
│         │                │                              │
│    ┌────▼────────────────▼────┐   Port 8081              │
│    │   strix-backend (ROCm)   │ ←─── llama-server       │
│    │   --models-max 3         │      --flash-attn        │
│    │   --mlock --no-mmap      │      q8_0 KV cache       │
│    └────────────┬─────────────┘                          │
│                 │ http://strix-backend:8081              │
│    ┌────────────▼─────────────┐   Port 8082              │
│    │  gateway (FastAPI proxy) │ ←─── Mode controller     │
│    │  3 modes: auton/chat/auto│      Model filtering      │
│    │  Health chain            │      Model preloading     │
│    └────┬──────────┬──────────┘                          │
│         │          │                                     │
│    ┌────▼───┐ ┌────▼────┐                                │
│    │  Letta │ │Open-WebUI│  Port 8283 / 3000            │
│    │ Agents │ │ Chat UI  │                               │
│    └────▲───┘ └─────────┘                                │
│    ┌────┴────┐                                           │
│    │ Hermes  │  (CLI, no port, docker exec)              │
│    └─────────┘                                           │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  searxng-stack (separate compose)                       │
│  SearXNG + Valkey (privacy search engine)               │
└─────────────────────────────────────────────────────────┘
```

**6 Docker services** orchestrated in layers:

| Service | Port | Role | Depends On |
|---|---|---|---|
| `strix-backend` | 8081 | llama.cpp inference server on ROCm | — |
| `gateway` | 8082 | FastAPI mode-based proxy | backend (healthy) |
| `letta` | 8283 | AI agent runtime (Letta) | gateway (healthy) |
| `open-webui` | 3000 | Chat UI | gateway (healthy) |
| `hermes` | — | CLI coding agent (docker exec) | gateway (healthy) |
| searxng+valkey | 8080 | Private metasearch (separate stack) | — |

---

## Component Deep Dive

### 1. strix-backend — llama.cpp on ROCm

- **Image**: `kyuz0/amd-strix-halo-toolboxes:rocm-7.2.3` (custom ROCm build)
- **Hardware**: passthrough `/dev/kfd` + `/dev/dri`, groups 44 (video) / 992 (render)
- **ROCm hack**: `HSA_OVERRIDE_GFX_VERSION=11.5.1` — Strix Halo not in ROCm 7.2.3's device table
- **Config**: `models.ini` — 13 models across 4 tiers with per-model context windows and mmproj for VLMs
- **Limits**: `--models-max 3` — only 3 models resident in VRAM at once
- **Memory pinned**: `--mlock` + `--no-mmap` prevents swapping; KV cache in `q8_0`
- **Flash attention**: `--flash-attn on`

### 2. gateway — Mode-based Model Router

- **Stack**: Python 3.11 + FastAPI + httpx, built from `./gateway/`
- **Purpose**: OpenAI-compatible proxy that filters model visibility and preloads models per mode
- **3 operational modes**:

| Mode | Models Visible | Preloading | Frontend |
|---|---|---|---|
| `autonomous` | 3 pinned (72B/30B/32B) | Yes — all 3 loaded on switch | Letta |
| `chat` | All 13+ | No — LRU on-demand loading | Open-WebUI |
| `autocomplete` | 3 fast (30B/35B/9B) | Yes — all 3 loaded on switch | None |

- **Preloading**: sends dummy warmup requests to llama.cpp to force model loading into VRAM
- **State**: `current_mode` is an in-memory Python variable — resets to `chat` on container restart
- **No auth**: API key is `strix-local` everywhere, no rate limiting, no TLS

### 3. switch-mode.sh — Mode Orchestrator

- **Hard reset** (`--hard`): stops backend, removes container, starts fresh → clears VRAM completely
- **Soft reset**: stops inactive frontends to prevent resource contention, switches gateway mode, waits for preload completion
- **Poll loop**: watches `/v1/models` until expected model count matches

### 4. hermes — CLI Coding Agent

- **Image**: Nous Research Hermes agent with Playwright (browser tools) installed
- **Runtime**: container stays alive via `tail -f /dev/null`, used exclusively through `docker compose exec hermes hermes <cmd>`
- **No port exposed**
- **Model**: `dev-Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL` with 16K context
- **Config**: `hermes/config.yaml` — 150 max iterations, tool compression at 50% threshold

### 5. searxng-stack — Private Search Engine

- **Separate Docker Compose** — not integrated into main compose or Caddy routing
- SearXNG metasearch + Valkey (Redis fork) cache
- API available in JSON and HTML formats

### 6. Caddyfile — Alternative Deployment Topology

- Routes `/v1/*` to backend on port **8080** (not 8081 as in compose)
- Routes `/*` to Open-WebUI
- Domain `ali-ws1.ts.net` (likely Tailscale Funnel for remote access)
- Not wired into any compose stack — standalone

---

## Model Inventory (13+)

| Tier | Model | Size | Context | Notes |
|---|---|---|---|---|
| Orchestrator | Qwen2.5-72B-Instruct-Q4_K_M | 72B | 16K | Pinned in autonomous mode |
| Dev | Qwen3-Coder-30B-A3B-UD-Q4_K_XL | 30B MoE | 16K | Pinned for coding |
| Tester | Qwen2.5-Coder-32B-Instruct-Q4_K_M | 32B | 16K | Pinned code reviewer |
| Heavy | Qwen3.5-122B-A10B-Claude-distill-Q4_K_M | 122B MoE | 16K | ~70GB in Q4 |
| Heavy | Huihui-Qwen3-Reasoning-Q5_K_M | ~? | 16K | Reasoning-distilled |
| Heavy | Qwen2.5-VL-72B-UD-Q4_K_XL | 72B | 8K | With mmproj (vision) |
| General | Qwen3.6-35B-A3B-UD-Q5_K_XL | 35B MoE | 16K | With mmproj |
| General | Kimi-Linear-48B-A3B-Instruct-Q4_K_L | 48B MoE | 16K | |
| Fast | Qwen3-Coder-30B-A3B-UD-Q4_K_XL | 30B MoE | 8K | Autocomplete |
| Fast | Qwen3.6-35B-A3B-Q5_K_XL | 35B MoE | 8K | With mmproj |
| Fast | Carnice-9b-Q8_0 | 9B | default | Embeddings (used by Letta) |
| Vision | Qwen2.5-VL-7B-Q4_K_M | 7B | 8K | Lightweight vision |
| Dropped | GLM-4.6V-Q4_K_M | ~? | — | Commented out in config |
| Dropped | Gemma-4-31B-it-Q8_0 | ~? | — | Commented out in config |

Models stored at `~/Desktop/models/*.gguf`. All quantized GGUF. Vision models require `mmproj` file.

---

## Critical Engineering Concerns

### 1. No explicit model unload API
llama.cpp `llama-server` has no API endpoint to evict a model from VRAM. Hard-resetting the container (`--hard` flag) is the only reliable way to free GPU memory. The built-in LRU eviction mechanism is opaque and untested.

### 2. `--models-max 3` contention
Only 3 models can be resident in VRAM simultaneously. Chat mode advertises 13+ models but each request to a non-resident model triggers a full disk-to-VRAM load (minute-scale). Switching between modes that use disjoint model sets requires a hard reset.

### 3. Mode switching is destructive
`switch-mode.sh` stops all non-relevant frontends before starting the target mode's frontend. No graceful degradation or partial mode overlap.

### 4. Gateway state is ephemeral
`current_mode` is an in-memory Python variable in `gateway/main.py`. Gateway restarts reset to `chat` default. No persistence or database backing.

### 5. No observability
No structured logging, metrics, tracing, or monitoring. Only simple health check endpoints (`/health` returning `{"status": "ok"}`). Debugging requires `docker compose logs` grepping.

### 6. Hermes idle pattern is fragile
Container runs `tail -f /dev/null` as entrypoint, intended for `docker exec` usage. No supervisor, no healthcheck, no restart policy if Hermes crashes.

### 7. No authentication or authorization
API key `strix-local` is hardcoded everywhere. Gateway, backend, Letta, and Open-WebUI are all accessible without real auth. Internal-only by design, but exposes the full model inference surface.

### 8. ROCm version pinning
`HSA_OVERRIDE_GFX_VERSION=11.5.1` forces GFX IP detection because Strix Halo isn't in ROCm 7.2.3's official device table. Any ROCm upgrade or transition to official support requires config changes.

### 9. Test suite is slow and sequential
`test-suite.sh` covers infrastructure, all 3 modes, Letta API, Hermes CLI, and memory checks comprehensively but runs fully sequentially with destructive mode switches — 8+ minutes for a full run. Each mode switch triggers a backend restart.

### 10. Scattered compose topology
Main services use `docker-compose.yml` in root. SearXNG uses its own `searxng-stack/docker-compose.yml`. Caddyfile exists but isn't referenced by any compose. No unified network or shared reverse proxy.

---

## Commands

```bash
# Switch modes (--hard restarts backend to clear VRAM)
./switch-mode.sh autonomous [--hard]
./switch-mode.sh chat [--hard]
./switch-mode.sh autocomplete [--hard]

# Full test suite (all modes, 8+ min)
./test-suite.sh [all|autonomous|chat|autocomplete] [--verbose]

# Debug logs
docker compose logs strix-backend --tail 50
docker compose logs gateway --tail 30
docker compose logs letta --tail 30
docker compose logs hermes --tail 30

# Hermes CLI coding agent
docker compose exec hermes hermes <subcommand>

# Health checks
curl http://localhost:8081/health   # Backend
curl http://localhost:8082/health   # Gateway
curl http://localhost:8082/mode     # Current mode info

# Direct inference
curl http://localhost:8082/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"fast-Carnice-9b-Q8_0","messages":[{"role":"user","content":"hello"}],"max_tokens":20}'
```

---

## Testing

`test-suite.sh` covers 7 phases:
1. **Infrastructure** — containers running, health endpoints, model count (expects 13)
2. **Autonomous mode** — mode switch, 3 models loaded, all 3 respond to inference
3. **Chat mode** — mode switch, all models visible, heavy 122B model loads, Open-WebUI accessible
4. **Autocomplete mode** — mode switch, 3 fast models visible, fast response time
5. **Letta API** — Letta responds, models endpoint, agents list
6. **Hermes CLI** — container running, config loaded, CLI works
7. **Memory & Resources** — system memory, backend memory usage, no OOM errors

---

## ROCm / GPU Configuration

- **AMD GPUs**: `Strix Halo` (integrated GPU + CPU chiplet)
- **Container devices**: `/dev/kfd` (kernel driver), `/dev/dri` (DRM)
- **Host groups**: 44 (video), 992 (render)
- **Security**: `seccomp=unconfined`, `memlock=unlimited`
- **ROCm version**: 7.2.3 with GFX override `HSA_OVERRIDE_GFX_VERSION=11.5.1`
- **Backend flags**: `--flash-attn on --no-mmap --mlock --cache-type-k q8_0 --cache-type-v q8_0`

---

## Volumes

| Volume | Purpose |
|---|---|
| `open-webui-data` | Open-WebUI state (chats, settings, user data) |
| `letta-data` | Letta agent memory, personas, conversations |
| `hermes-data` | Hermes agent state |
| `ollama_data/` | Local directory for Ollama data (unused) |

---

## Related

- [AGENTS.md](AGENTS.md) — compact instruction file for OpenCode sessions
