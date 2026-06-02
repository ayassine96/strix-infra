# Strix Halo — infra-node

## Architecture (6 services, 2 compose stacks)

**Main stack** (`docker compose` in root):
- `strix-backend` — llama-server on ROCm (port 8081). GPU via `/dev/kfd` + `/dev/dri`. Config: `models.ini`
- `gateway` — FastAPI proxy (port 8082). Mode-based model filtering + preloading. Python 3.11, built from `./gateway/`
- `letta` — agent runtime. Depends on gateway healthy. Data: `letta-data` volume
- `open-webui` — chat UI (port 3000). Data: `open-webui-data` volume
- `hermes` — CLI coding agent, no exposed port. Use `docker exec`. Built from `./hermes/`. Data: `hermes-data` volume

**Separate stack** (`searxng-stack/docker-compose.yml`):
- SearXNG + Valkey. Not integrated with main compose or Caddy.

**Caddyfile** — alternative routing for Tailscale Funnel (`ali-ws1.ts.net`), not wired into compose.

## Modes

Gateway exposes 3 modes, switched via `switch-mode.sh`:

| Mode | Models | Frontend | Preloads |
|---|---|---|---|
| `autonomous` | orchestrator-Qwen2.5-72B, dev-Qwen3-Coder-30B, tester-Qwen2.5-Coder-32B | Letta | Yes |
| `chat` | All 13+ models (LRU on-demand) | Open-WebUI | No |
| `autocomplete` | fast-Qwen3-Coder-30B, fast-Qwen3.6-35B, fast-Carnice-9b | — | Yes |

Model names use prefixes: `orchestrator-`, `dev-`, `tester-`, `heavy-`, `general-`, `fast-`, `vision-`.

## Commands

```bash
# Switch modes (--hard restarts backend to clear VRAM)
./switch-mode.sh autonomous [--hard]
./switch-mode.sh chat [--hard]
./switch-mode.sh autocomplete [--hard]

# Full test suite (all modes sequentially, 8+ min)
./test-suite.sh [all|autonomous|chat|autocomplete] [--verbose]

# Debug logs
docker compose logs strix-backend --tail 50
docker compose logs gateway --tail 30

# Hermes (CLI agent, no port)
docker compose exec hermes hermes <subcommand>
```

## Key constraints

- **backend:max 3 models** in VRAM simultaneously. llama.cpp has no explicit unload API — `--hard` restart is the only way to clear.
- **Gateway state is ephemeral** — `current_mode` resets to `chat` on restart.
- **No authentication** anywhere. API key is `strix-local` everywhere.
- **ROCm hack**: `HSA_OVERRIDE_GFX_VERSION=11.5.1` — Strix Halo not officially in ROCm 7.2.3's device table.
- **Health chain**: backend → gateway → frontend. Ordered startup enforced by `depends_on` + healthchecks.
- **No package.json/JS toolchain** in this repo. Gateway is Python/FastAPI. No lint/typecheck scripts.

## ROCm specifics

- Devices: `/dev/kfd`, `/dev/dri`
- Groups: 44 (video), 992 (render)
- seccomp: unconfined, memlock: unlimited
- `--flash-attn on`, `--no-mmap`, `--mlock`
- KV cache quantized to `q8_0`

## Models

Located at `~/Desktop/models/*.gguf`. Configured in `models.ini`. 13+ models across tiers. 3 concurrently loadable. Context up to 16K. Vision models need `mmproj` path.

## Testing

- `test-suite.sh` covers: infra (containers/health), all 3 modes, model inference, Letta API, Hermes CLI, memory/OOM checks.
- Tests curl endpoints directly against gateway (port 8082).
- Expects exactly 13 models visible in backend (`test 1.5`).
- Runs mode switches destructively — stops all frontends, restarts backend for each phase.

## Volumes

```yaml
open-webui-data:  # Open-WebUI state
letta-data:       # letta agent state
hermes-data:      # hermes agent state
```
