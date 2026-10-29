// TLS
// ===

// The JavaScript lane's TLS: node:net and node:tls run in a worker thread
// (the lane's loop is synchronous, so callbacks on the main thread would
// never run). Each effect posts a request, then parks, polling the worker's
// replies every 2ms until its answer arrives, so other computations keep
// running. A connection's handle is its id (from 1 << 20, clear of real
// fds). Tls.dial opens a plain connection whose bytes Tls.send and Tls.recv
// carry until Tls.secure upgrades it in place; the server is verified as on
// the native lane: the given roots or the system's, by name or IP, TLS 1.2
// or later. Proxies are decided in Bend (proxy.bend), not here.

const TLS_WORKER = String.raw`
const { parentPort } = require("node:worker_threads");
const tls = require("node:tls");
const net = require("node:net");
let port;
const conns = new Map();
// A failed verification reads as on the native lane.
function why(e) {
  const m = String(e.message || e);
  return /CERT|ISSUER|SELF_SIGNED|ALTNAME|UNABLE_TO_VERIFY/.test(e.code || "")
    ? "server certificate rejected: " + m : m;
}
function wire(id, s, ready, ms) {
  conns.set(id, s);
  s.setTimeout(ms, () => s.destroy(new Error(ready === "connect" ? "connect timed out" : "handshake timed out")));
  s.once(ready, () => {
    s.setTimeout(0);
    port.postMessage({ id, type: "open" });
  });
  s.on("data", (d) => port.postMessage({ id, type: "data", bytes: new Uint8Array(d) }));
  s.on("end", () => port.postMessage({ id, type: "end" }));
  s.on("error", (e) => port.postMessage({ id, type: "error", text: why(e) }));
  s.on("close", () => { if (conns.get(id) === s) conns.delete(id); });
}
parentPort.once("message", ({ port: p }) => {
  port = p;
  port.on("message", (m) => {
    const fail = (e) => port.postMessage({ id: m.id, type: "error", text: String(e.message || e) });
    if (m.op === "dial") {
      let s;
      try { s = net.connect({ host: m.host, port: m.port, noDelay: true }); } catch (e) { fail(e); return; }
      s.setKeepAlive(true);
      wire(m.id, s, "connect", m.ms);
    } else if (m.op === "secure") {
      const plain = conns.get(m.id);
      if (!plain) { fail(new Error("not a connection")); return; }
      for (const ev of ["data", "end", "error", "close", "timeout", "connect"]) plain.removeAllListeners(ev);
      plain.setTimeout(0);
      const opts = { socket: plain, rejectUnauthorized: true, minVersion: "TLSv1.2",
        ALPNProtocols: ["http/1.1"] };
      if (!net.isIP(m.host)) opts.servername = m.host;
      if (m.ca) opts.ca = m.ca;
      if (m.cert) { opts.cert = m.cert; opts.key = m.key; }
      let s;
      try { s = tls.connect(opts); } catch (e) { plain.destroy(); fail(e); return; }
      wire(m.id, s, "secureConnect", m.ms);
    } else if (m.op === "send") {
      const s = conns.get(m.id);
      if (s) s.write(m.bytes);
    } else if (m.op === "close") {
      const s = conns.get(m.id);
      if (s) s.end();
      conns.delete(m.id);
    }
  });
});
`;

let tls_worker = null;
let tls_next = 1 << 20;
const tls_state = new Map();

function tls_start() {
  if (tls_worker === null) {
    const { Worker, MessageChannel, receiveMessageOnPort } = require("node:worker_threads");
    const { port1, port2 } = new MessageChannel();
    const worker = new Worker(TLS_WORKER, { eval: true });
    worker.unref();
    worker.postMessage({ port: port2 }, [port2]);
    tls_worker = { worker, port: port1, receive: receiveMessageOnPort };
  }
  return tls_worker;
}

// Moves every reply the worker sent into the connections' state.
function tls_drain() {
  const w = tls_start();
  for (let m = w.receive(w.port); m !== undefined; m = w.receive(w.port)) {
    const st = tls_state.get(m.message.id);
    if (st === undefined) continue;
    const msg = m.message;
    if (msg.type === "open") st.open = true;
    else if (msg.type === "data") st.chunks.push(msg.bytes);
    else if (msg.type === "end") st.ended = true;
    else if (msg.type === "error") st.error = st.error ?? msg.text;
  }
}

function tls_poll(k, more) {
  io_park_on(undefined, false, k, more, performance.now() + 2);
  return undefined;
}

// Parks until the worker opens (or fails) connection id.
function tls_await(id, st, ms, k, what) {
  const limit = Number(ms) === 0 ? 30000 : Number(ms);
  const at = performance.now() + limit;
  const go = () => {
    tls_drain();
    if (st.open) return io_done(id);
    if (st.error !== undefined || performance.now() >= at) {
      tls_state.delete(id);
      tls_start().port.postMessage({ op: "close", id });
      return io_fail(st.error === undefined ? 60 : 104,
        what + ": " + (st.error ?? (what === "TLS" ? "handshake timed out" : "timed out")));
    }
    return tls_poll(k, go);
  };
  return go();
}

function tls_dial(host, port, ms, k) {
  const id = tls_next++;
  const st = { open: false, chunks: [], ended: false, error: undefined };
  tls_state.set(id, st);
  const limit = Number(ms) === 0 ? 30000 : Number(ms);
  tls_start().port.postMessage({ op: "dial", id, host, port: Number(port), ms: limit });
  return tls_await(id, st, ms, k, "connect " + host + ":" + Number(port));
}

function tls_secure(sock, host, ca, cert, key, ms, k) {
  const st = tls_state.get(sock);
  if (st === undefined || st.secure) return io_fail(9, "TLS: not a plain connection from Tls.dial");
  st.open = false;
  st.secure = true;
  st.chunks = [];
  const limit = Number(ms) === 0 ? 30000 : Number(ms);
  tls_start().port.postMessage({ op: "secure", id: sock, host, ca, cert, key, ms: limit });
  return tls_await(sock, st, ms, k, "TLS");
}

function tls_send(sock, text, ms) {
  const st = tls_state.get(sock);
  if (st === undefined) return io_tup(sock, io_fail(9));
  if (st.error !== undefined) return io_tup(sock, io_fail(32, "TLS: " + st.error));
  tls_start().port.postMessage({ op: "send", id: sock, bytes: io_bytes(text) });
  return io_tup(sock, io_done({ $: CID(Unit) }));
}

function tls_recv(sock, max, ms, k) {
  const st = tls_state.get(sock);
  if (st === undefined) return io_tup(sock, io_fail(9));
  const cap = Number(max) === 0 ? 16384 : Number(max);
  const at = Number(ms) === 0 ? undefined : performance.now() + Number(ms);
  const go = () => {
    tls_drain();
    if (st.chunks.length > 0) {
      const head = st.chunks[0];
      const n = Math.min(cap, head.length);
      if (n === head.length) st.chunks.shift();
      else st.chunks[0] = head.subarray(n);
      return io_tup(sock, io_done(io_list(head, n)));
    }
    if (st.error !== undefined) return io_tup(sock, io_fail(104, "TLS: " + st.error));
    if (st.ended) return io_tup(sock, io_done({ $: CID(Nil) }));
    if (at !== undefined && performance.now() >= at) return io_tup(sock, io_fail(60));
    return tls_poll(k, go);
  };
  return go();
}

function tls_close(sock) {
  if (tls_state.has(sock)) {
    tls_start().port.postMessage({ op: "close", id: sock });
    tls_state.delete(sock);
  }
  return { $: CID(Unit) };
}

io_eff(CID(Tls.dial), tls_dial);
io_eff(CID(Tls.secure), tls_secure);
io_eff(CID(Tls.send), tls_send);
io_eff(CID(Tls.recv), tls_recv);
io_eff(CID(Tls.close), tls_close);
