// Development stand-in for the phone side of the relay: exposes a Mac's room
// as a local TCP port, so any client (openssl, the simulator app) can reach
// the Mac's TLS server through the relay.
//
//   node test/bridge.mjs <relay ws url> <room> [local port=18480]
import net from "node:net";

const [relay, room, port = "18480"] = process.argv.slice(2);
if (!relay || !room) {
  console.error("usage: node test/bridge.mjs <relay ws url> <room> [local port]");
  process.exit(2);
}

net.createServer((sock) => {
  sock.pause();
  const ws = new WebSocket(`${relay.replace(/\/$/, "")}/v1/rooms/${room}/client`);
  ws.binaryType = "arraybuffer";
  let ready = false;
  ws.addEventListener("message", (e) => {
    if (!ready) {
      if (e.data === "ready") { ready = true; sock.resume(); }
      return;
    }
    if (typeof e.data !== "string") sock.write(Buffer.from(e.data));
  });
  sock.on("data", (d) => ws.send(d));
  const end = () => { try { ws.close(); } catch {} sock.destroy(); };
  ws.addEventListener("close", end);
  ws.addEventListener("error", end);
  sock.on("close", end);
  sock.on("error", end);
}).listen(Number(port), "127.0.0.1", () => console.log(`bridge on 127.0.0.1:${port} -> ${relay} room ${room}`));
