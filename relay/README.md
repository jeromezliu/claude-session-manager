# csm-relay

A tiny Cloudflare Worker that lets the phone app reach the Mac from any
network. Both sides dial **out** over HTTPS WebSockets and the relay splices
them; nothing listens on the Mac, and it works behind NAT, carrier networks
and HTTPS-inspecting proxies.

The relay only moves bytes. The app's own TLS runs inside, with the
certificate pinned on the phone and device tokens checked by the Mac, so the
relay — and anything inspecting the HTTPS hop — sees ciphertext only.

```
phone app ──wss──▶ 127.0.0.1 bridge ──wss──▶ relay ◀──wss── Mac RelayLink ──tcp──▶ Mac TLS server
          (pinned TLS + token, end to end, inside the relay's WebSockets)
```

## Protocol

| Path                               | Who               | Auth                  |
| ---------------------------------- | ----------------- | --------------------- |
| `GET /v1/rooms/<room>/host`        | Mac control socket | `Bearer <host secret>` |
| `GET /v1/rooms/<room>/client`      | phone, one per connection | none (inner TLS + token) |
| `GET /v1/rooms/<room>/host/<conn>` | Mac data socket   | `Bearer <host secret>` |

`<room>` is `base64url(SHA-256(host secret))`, so the relay verifies the Mac
without storing anything. When a phone connects, the control socket gets
`{"t":"open","c":"<conn>"}`; the Mac dials the matching data socket, the phone
receives a `ready` text frame, and from then on binary frames pass straight
through. A text `ping` is answered with `pong` at the edge without waking the
Durable Object.

One Durable Object per room, using the WebSocket Hibernation API, so a Mac
idling on its control socket costs nothing.

## Run locally

```sh
npm install
npm run dev      # ws://127.0.0.1:8787
npm test         # end-to-end checks against the dev relay
```

Point the Mac at it with *Remote Access… → From anywhere (relay)* =
`ws://127.0.0.1:8787` (or `CSM_REMOTE_RELAY=ws://127.0.0.1:8787` for a dev
run), then pair the phone again so it learns the relay.

`test/bridge.mjs` is a stand-in for the phone side (exposes a room as a local
TCP port), handy for poking the Mac with `openssl s_client`.

## Deploy

```sh
npx wrangler login
npm run deploy   # → https://csm-relay.<your-subdomain>.workers.dev
```

Use `wss://csm-relay.<your-subdomain>.workers.dev` as the relay address. A
custom domain (*Workers → Settings → Domains*) avoids networks that filter
`workers.dev`.

## Cost

Pricing as of October 2026 (Workers and Durable Objects pricing pages). The
relay uses requests and Durable Object duration only; storage is unused and
there are no bandwidth charges.

| Plan  | Price     | Included                                                                 |
| ----- | --------- | ------------------------------------------------------------------------ |
| Free  | $0        | 100k Worker requests/day; DO: 100k requests/day, 13,000 GB-s/day         |
| Paid  | $5/month  | 10M Worker requests/month; DO: 1M requests/month, 400,000 GB-s/month     |

How the relay is billed:

- Each WebSocket connection is one request; incoming WebSocket messages count
  20 messages to 1 request; outgoing messages are free.
- Duration is 128 MB × wall time while the object is awake. A hibernated
  object (idle sockets) and edge auto-responses (`ping`) cost no duration.

Estimate for one person, one Mac, a phone used heavily (about 3 hours a day
with the app open, about 1 hour of streamed replies):

| Item                              | Per day         | Per month   |
| --------------------------------- | --------------- | ----------- |
| Mac keep-alives (1 per 20 s)      | ~220 requests   | ~6.5k       |
| Connections (~50 reconnects × 2)  | ~100 requests   | ~3k         |
| Relayed frames (~50k incoming)    | ~2.5k requests  | ~75k        |
| **DO requests**                   | **~2.8k**       | **~85k**    |
| DO duration (3 h awake × 0.125 GB)| ~1,350 GB-s     | ~40k GB-s   |

That is under 3% of the Free plan's daily allowance and under 10% of what the
Paid plan includes, so the expected cost is **$0** on Free, or a flat
**$5/month** on Paid (no overage) if you want headroom and no daily cap. Even
ten times this usage (a small team) stays inside the Paid plan's included
amounts. Free-plan limits reset at 00:00 UTC; going over makes new
connections fail until then.

Optional extras: a custom domain (about $10/year at cost through Cloudflare
Registrar).
