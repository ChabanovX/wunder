#!/usr/bin/env python3
import asyncio, json, secrets, os
from websockets.server import serve, WebSocketServerProtocol
from websockets.exceptions import ConnectionClosed

rooms: dict[str, set[WebSocketServerProtocol]] = {}
peers: dict[WebSocketServerProtocol, dict] = {}
last_offer: dict[str, str] = {}

async def jsend(ws: WebSocketServerProtocol, obj: dict):
    try:
        await ws.send(json.dumps(obj))
    except Exception:
        pass

async def send_to_peer_id(room_id: str, target_peer_id: str, obj: dict) -> bool:
    for w in rooms.get(room_id, set()):
        info = peers.get(w)
        if info and info.get("peerId") == target_peer_id:
            await jsend(w, obj)
            return True
    return False

async def broadcast(room_id: str, obj: dict, exclude: WebSocketServerProtocol | None = None):
    for w in list(rooms.get(room_id, set())):
        if w is not exclude:
            await jsend(w, obj)

def new_room_id() -> str:
    return str(int(secrets.randbits(32)) % 10_000_000).zfill(7)

async def handler(ws: WebSocketServerProtocol):
    try:
        async for raw in ws:
            try:
                msg = json.loads(raw)
            except Exception:
                continue
            t = msg.get("type")

            if t == "create":
                room_id = msg.get("roomId") or new_room_id()
                rooms.setdefault(room_id, set()).add(ws)
                peer_id = str(id(ws))
                peers[ws] = {"roomId": room_id, "peerId": peer_id, "role": "host"}
                await jsend(ws, {"type": "created", "roomId": room_id})
                continue

            if t == "join":
                room_id = msg.get("roomId")
                if not room_id or room_id not in rooms:
                    await jsend(ws, {"type": "error", "message": "Room not found"})
                    continue
                rooms[room_id].add(ws)
                peer_id = str(id(ws))
                peers[ws] = {"roomId": room_id, "peerId": peer_id, "role": "guest"}
                await jsend(ws, {"type": "joined", "roomId": room_id})
                if room_id in last_offer:
                    await jsend(ws, {"type": "offer", "sdp": last_offer[room_id]})
                await broadcast(room_id, {"type": "peer-joined", "peerId": peer_id}, exclude=ws)
                continue

            if t == "leave":
                info = peers.get(ws)
                if info:
                    rid, pid = info["roomId"], info["peerId"]
                    rooms.get(rid, set()).discard(ws)
                    await broadcast(rid, {"type": "peer-left", "peerId": pid}, exclude=ws)
                continue

            if t in ("offer", "answer", "ice"):
                info = peers.get(ws)
                if not info:
                    continue
                rid, pid = info["roomId"], info["peerId"]
                if t == "offer" and info.get("role") == "host" and "sdp" in msg:
                    last_offer[rid] = msg["sdp"]
                fwd = dict(msg); fwd["from"] = pid
                target = msg.get("to")
                if target:
                    sent = await send_to_peer_id(rid, target, fwd)
                    if not sent:
                        await jsend(ws, {"type": "error", "message": "target peer not found"})
                else:
                    await broadcast(rid, fwd, exclude=ws)
                continue

            if t == "ping":
                await jsend(ws, {"type": "pong"})
                continue

    except ConnectionClosed:
        pass
    finally:
        info = peers.pop(ws, None)
        if info:
            rid, pid = info["roomId"], info["peerId"]
            rooms.get(rid, set()).discard(ws)
            await broadcast(rid, {"type": "peer-left", "peerId": pid}, exclude=ws)
            if not rooms.get(rid):
                rooms.pop(rid, None)
                last_offer.pop(rid, None)

async def main():
    host = os.getenv("SIGNALING_HOST", "0.0.0.0")
    port = int(os.getenv("SIGNALING_PORT", "8080"))
    print(f"Signaling server on ws://{host}:{port}")
    async with serve(handler, host, port, ping_interval=20, ping_timeout=20, max_size=2**20):
        await asyncio.Future()

if __name__ == "__main__":
    asyncio.run(main())
