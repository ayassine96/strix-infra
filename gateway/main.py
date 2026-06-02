import os
import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse

app = FastAPI(title="Strix Gateway")
LLAMA_URL = os.getenv("LLAMA_SERVER_URL", "http://strix-backend:8081")

MODES = {
    "autonomous": {
        "desc": "1 Orchestrator + 1 Dev + 1 Tester (24/7 Agent)",
        "models": [
            "orchestrator-Qwen2.5-72B-Instruct-Q4_K_M",
            "dev-Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL",
            "tester-Qwen2.5-Coder-32B-Instruct-Q4_K_M"
        ],
        "preload": True
    },
    "chat": {
        "desc": "Open-WebUI chatting with any model (LRU auto-load/unload)",
        "models": [],
        "preload": False
    },
    "autocomplete": {
        "desc": "Fast coding autocomplete for mobile/laptop",
        "models": [
            "fast-Qwen3-Coder-30B-A3B-Instruct-UD-Q4_K_XL",
            "fast-Qwen3.6-35B-A3B-UD-Q5_K_XL",
            "fast-Carnice-9b-Q8_0"
        ],
        "preload": True
    }
}

current_mode = "chat"

HOP_HEADERS = {
    "connection", "keep-alive", "proxy-authenticate",
    "proxy-authorization", "te", "trailers", "transfer-encoding", "upgrade"
}

async def proxy(request: Request, path: str):
    client = httpx.AsyncClient(timeout=300.0)
    try:
        method = request.method
        body = await request.body()
        headers = {k: v for k, v in request.headers.items()
                   if k.lower() not in ("host", "content-length")}
        url = f"{LLAMA_URL}/{path}"
        req = client.build_request(method, url, content=body, headers=headers, params=request.query_params)
        resp = await client.send(req, stream=True)

        response_headers = {k: v for k, v in resp.headers.items()
                           if k.lower() not in HOP_HEADERS and k.lower() not in ("content-length", "content-encoding")}

        async def stream_generator():
            try:
                async for chunk in resp.aiter_raw():
                    yield chunk
            finally:
                await resp.aclose()
                await client.aclose()

        return StreamingResponse(
            content=stream_generator(),
            status_code=resp.status_code,
            headers=response_headers
        )
    except Exception:
        await client.aclose()
        raise

@app.post("/mode/{mode_name}")
async def set_mode(mode_name: str):
    global current_mode
    if mode_name not in MODES:
        return JSONResponse({"error": f"Pick from: {list(MODES.keys())}"}, status_code=400)

    current_mode = mode_name
    cfg = MODES[mode_name]
    loaded = []

    if cfg["preload"]:
        async with httpx.AsyncClient() as client:
            for model_id in cfg["models"]:
                try:
                    await client.post(
                        f"{LLAMA_URL}/v1/chat/completions",
                        json={"model": model_id, "messages": [{"role": "user", "content": "warmup"}], "max_tokens": 1, "temperature": 0},
                        timeout=300.0
                    )
                    loaded.append(model_id)
                except Exception as e:
                    print(f"Preload warning for {model_id}: {e}")

    return {
        "mode": mode_name,
        "description": cfg["desc"],
        "active_models": cfg["models"],
        "preloaded": loaded
    }

@app.get("/mode")
async def get_mode():
    async with httpx.AsyncClient() as client:
        try:
            resp = await client.get(f"{LLAMA_URL}/v1/models", timeout=10.0)
            all_models = [m.get("id") for m in resp.json().get("data", [])]
        except Exception:
            all_models = []
    return {
        "current_mode": current_mode,
        "modes": {k: v["desc"] for k, v in MODES.items()},
        "available_models": all_models
    }

@app.get("/health")
async def health():
    return {"status": "ok", "mode": current_mode}

# CATCH-ALL MUST BE LAST so specific routes match first
@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "OPTIONS", "HEAD", "PATCH", "TRACE"])
async def catch_all(request: Request, path: str):
    global current_mode

    if path == "v1/models" and request.method == "GET":
        async with httpx.AsyncClient() as client:
            resp = await client.get(f"{LLAMA_URL}/v1/models", timeout=30.0)
            data = resp.json()
            allowed = MODES.get(current_mode, {}).get("models", [])
            if allowed:
                data["data"] = [m for m in data.get("data", []) if m.get("id") in allowed]
            return JSONResponse(content=data, status_code=resp.status_code)

    return await proxy(request, path)