import time, base64, hmac, hashlib, os
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

class IceServers(BaseModel):
    iceServers: list

app = FastAPI(title="wunder-api")

TURN_SECRET_B64 = os.getenv("TURN_SECRET_B64", "")        # общий секрет с coturn (base64)
TURN_REALM = os.getenv("TURN_REALM", "wunder")
TURN_URIS = os.getenv("TURN_URIS", "turns:turn.example.com:443?transport=tcp,turn:turn.example.com:3478?transport=udp")

@app.get("/healthz")
async def healthz(): return {"ok": True}

@app.get("/turn/credentials", response_model=IceServers)
async def credentials(user_id: str):
    if not TURN_SECRET_B64:
        raise HTTPException(500, "TURN secret not configured")
    ttl = 10 * 60
    username = f"{int(time.time()) + ttl}:{user_id}"
    key = base64.b64decode(TURN_SECRET_B64)
    credential = base64.b64encode(hmac.new(key, username.encode(), hashlib.sha1).digest()).decode()
    uris = [u.strip() for u in TURN_URIS.split(",") if u.strip()]
    return {"iceServers": [{"urls": uris, "username": username, "credential": credential}]}
