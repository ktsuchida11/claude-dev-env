import debugpy

try:
    debugpy.listen(("0.0.0.0", 5678))
except Exception:
    pass  # --reload 時の再起動でポートが既に使用中の場合はスキップ

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI(title="Backend API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/api/health")
def health():
    status = "ok"  # ← ブレークポイントを設定してステップ実行を確認
    return {"status": status}


@app.get("/api/greet")
def greet(name: str = "World"):
    message = f"Hello, {name}!"  # ← ブレークポイントを設定してステップ実行を確認
    return {"message": message}
