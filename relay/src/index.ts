/**
 * Claude Session Manager relay.
 *
 * Lets a phone reach the Mac when neither can accept connections from the
 * other: both dial out over HTTPS WebSockets and the relay splices them.
 * It only moves bytes. Inside runs the app's own TLS (certificate pinned on
 * the phone) and device-token auth, so the relay — and anything inspecting
 * the HTTPS hop — sees ciphertext only.
 *
 *   GET /v1/rooms/<room>/host          Mac control socket (Bearer host secret)
 *   GET /v1/rooms/<room>/client        phone data socket (one per connection)
 *   GET /v1/rooms/<room>/host/<conn>   Mac data socket for that connection
 *
 * <room> is base64url(SHA-256(host secret)), so the relay checks the Mac
 * without storing anything. When a phone connects, the control socket gets
 * {"t":"open","c":<conn>}; the Mac dials the matching data socket, the phone
 * gets a "ready" text frame, and from then on binary frames pass straight
 * through. Text "ping" is answered by the edge without waking the object.
 *
 * One Durable Object per room, using the hibernation API: an idle Mac
 * holding its control socket costs nothing.
 */

import { DurableObject } from "cloudflare:workers";

export interface Env {
  ROOMS: DurableObjectNamespace<Room>;
}

const ROOM_RE = /^[A-Za-z0-9_-]{43}$/;
const CONN_RE = /^[0-9a-f]{32}$/;
/** Concurrent phone connections per room. */
const MAX_CLIENTS = 8;

type Route = { room: string; role: "control" | "client" | "data"; conn?: string };

function route(url: URL): Route | null {
  const m = url.pathname.match(/^\/v1\/rooms\/([^/]+)\/(host|client)(?:\/([^/]+))?$/);
  if (!m) return null;
  const [, room, kind, conn] = m;
  if (!ROOM_RE.test(room)) return null;
  if (kind === "client") return conn ? null : { room, role: "client" };
  if (conn === undefined) return { room, role: "control" };
  return CONN_RE.test(conn) ? { room, role: "data", conn } : null;
}

async function roomFor(secret: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(secret)));
  let bin = "";
  for (const b of digest) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname === "/v1/health") return new Response("ok\n");
    const r = route(url);
    if (!r) return new Response("not found\n", { status: 404 });
    if (req.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("expected a WebSocket\n", { status: 426 });
    }
    if (r.role !== "client") {
      const auth = req.headers.get("Authorization") ?? "";
      const secret = auth.startsWith("Bearer ") ? auth.slice(7) : "";
      if (!secret || (await roomFor(secret)) !== r.room) return new Response("forbidden\n", { status: 403 });
    }
    return env.ROOMS.get(env.ROOMS.idFromName(r.room)).fetch(req);
  },
};

export class Room extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    // Keep-alives through proxies and NATs, answered without waking us.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(req: Request): Promise<Response> {
    const r = route(new URL(req.url))!;
    const [client, server] = Object.values(new WebSocketPair());

    switch (r.role) {
      case "control":
        // One Mac per room; a reconnect replaces the stale socket.
        for (const old of this.ctx.getWebSockets("ctl")) old.close(4000, "replaced");
        this.ctx.acceptWebSocket(server, ["ctl"]);
        break;

      case "client": {
        const ctl = this.ctx.getWebSockets("ctl")[0];
        if (!ctl) return new Response("host offline\n", { status: 503 });
        if (this.ctx.getWebSockets("c").length >= MAX_CLIENTS) {
          return new Response("too many connections\n", { status: 429 });
        }
        const conn = crypto.randomUUID().replace(/-/g, "");
        this.ctx.acceptWebSocket(server, ["c", `c:${conn}`]);
        ctl.send(JSON.stringify({ t: "open", c: conn }));
        break;
      }

      case "data": {
        const phone = this.ctx.getWebSockets(`c:${r.conn}`)[0];
        if (!phone || this.ctx.getWebSockets(`h:${r.conn}`).length) {
          return new Response("no such connection\n", { status: 410 });
        }
        this.ctx.acceptWebSocket(server, ["h", `h:${r.conn}`]);
        phone.send("ready");
        break;
      }
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  /** The other end of a spliced connection, if any. */
  private peer(ws: WebSocket): WebSocket | undefined {
    for (const tag of this.ctx.getTags(ws)) {
      if (tag.startsWith("c:")) return this.ctx.getWebSockets(`h:${tag.slice(2)}`)[0];
      if (tag.startsWith("h:")) return this.ctx.getWebSockets(`c:${tag.slice(2)}`)[0];
    }
    return undefined;
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (typeof message === "string") return;   // data is binary; text is control/keep-alive
    const peer = this.peer(ws);
    if (peer) peer.send(message);
    else ws.close(1011, "not connected");      // the phone waits for "ready" before sending
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    this.hangUp(ws, code, reason);
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    this.hangUp(ws, 1011, "error");
  }

  private hangUp(ws: WebSocket, code: number, reason: string): void {
    const ok = code >= 3000 && code <= 4999 || code === 1000;
    try { ws.close(ok ? code : 1000, reason); } catch { /* already closed */ }
    const peer = this.peer(ws);
    if (peer) try { peer.close(ok ? code : 1000, reason); } catch { /* already closed */ }
  }
}
