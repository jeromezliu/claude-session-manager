// End-to-end checks against a running relay: `npm run dev`, then `npm test`
// (RELAY=ws://127.0.0.1:8787 by default).
import { createHash, randomBytes } from "node:crypto";
import assert from "node:assert/strict";

const RELAY = process.env.RELAY ?? "ws://127.0.0.1:8787";
const HTTP = RELAY.replace(/^ws/, "http");

const secret = randomBytes(32).toString("base64url");
const room = createHash("sha256").update(secret).digest("base64url");
const auth = { headers: { Authorization: `Bearer ${secret}` } };

/** Open a socket and collect what arrives. Resolves once open, rejects if it can't. */
function open(path, opts) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${RELAY}${path}`, opts);
    ws.binaryType = "arraybuffer";
    ws.inbox = [];
    ws.waiters = [];
    ws.closed = new Promise((r) => ws.addEventListener("close", (e) => r(e.code)));
    ws.addEventListener("message", (e) => {
      const w = ws.waiters.shift();
      w ? w(e.data) : ws.inbox.push(e.data);
    });
    ws.addEventListener("open", () => resolve(ws), { once: true });
    ws.addEventListener("error", () => reject(new Error(`could not open ${path}`)), { once: true });
  });
}

function next(ws, ms = 3000) {
  if (ws.inbox.length) return Promise.resolve(ws.inbox.shift());
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error("timed out waiting for a message")), ms);
    ws.waiters.push((d) => { clearTimeout(t); resolve(d); });
  });
}

const bytes = (s) => new TextEncoder().encode(s);
const text = (b) => new TextDecoder().decode(b);

/** Phone connects; Mac accepts on its control socket; returns both data ends. */
async function splice(ctl) {
  const phone = await open(`/v1/rooms/${room}/client`);
  const { t, c } = JSON.parse(await next(ctl));
  assert.equal(t, "open");
  const mac = await open(`/v1/rooms/${room}/host/${c}`, auth);
  assert.equal(await next(phone), "ready");
  return { phone, mac };
}

const tests = {
  async health() {
    assert.equal((await fetch(`${HTTP}/v1/health`)).status, 200);
    assert.equal((await fetch(`${HTTP}/v1/rooms/${room}/client`)).status, 426);
    assert.equal((await fetch(`${HTTP}/nope`)).status, 404);
  },

  async "phone is refused while the Mac is offline"() {
    await assert.rejects(open(`/v1/rooms/${room}/client`));
  },

  async "host needs the room's secret"() {
    await assert.rejects(open(`/v1/rooms/${room}/host`));
    await assert.rejects(open(`/v1/rooms/${room}/host`, { headers: { Authorization: "Bearer wrong" } }));
  },

  async "bytes pass both ways, connections stay separate, closes propagate"() {
    const ctl = await open(`/v1/rooms/${room}/host`, auth);
    const a = await splice(ctl);
    const b = await splice(ctl);

    a.phone.send(bytes("hello from phone A"));
    b.phone.send(bytes("hello from phone B"));
    assert.equal(text(await next(a.mac)), "hello from phone A");
    assert.equal(text(await next(b.mac)), "hello from phone B");

    const big = randomBytes(512 * 1024);
    a.mac.send(big);
    assert.deepEqual(Buffer.from(await next(a.phone)), big);

    a.phone.close(1000);
    assert.equal(await a.mac.closed, 1000);
    b.mac.send(bytes("B still up"));
    assert.equal(text(await next(b.phone)), "B still up");

    b.mac.close(4001, "done");
    assert.equal(await b.phone.closed, 4001);
    ctl.close();
  },

  async "keep-alive is answered"() {
    const ctl = await open(`/v1/rooms/${room}/host`, auth);
    ctl.send("ping");
    assert.equal(await next(ctl), "pong");
    ctl.close();
  },

  async "a reconnecting Mac replaces the old control socket"() {
    const old = await open(`/v1/rooms/${room}/host`, auth);
    const fresh = await open(`/v1/rooms/${room}/host`, auth);
    assert.equal(await old.closed, 4000);
    const { phone, mac } = await splice(fresh);
    phone.send(bytes("x"));
    assert.equal(text(await next(mac)), "x");
    phone.close(); fresh.close();
  },

  async "a data socket can't hijack an unknown or taken connection"() {
    const ctl = await open(`/v1/rooms/${room}/host`, auth);
    await assert.rejects(open(`/v1/rooms/${room}/host/${"0".repeat(32)}`, auth));
    const { phone } = await splice(ctl);
    ctl.close(); phone.close();
  },
};

let failed = 0;
for (const [name, fn] of Object.entries(tests)) {
  try { await fn(); console.log(`✓ ${name}`); }
  catch (e) { failed++; console.log(`✗ ${name}\n  ${e.stack ?? e}`); }
}
console.log(failed ? `${failed} failed` : "all passed");
process.exit(failed ? 1 : 0);
