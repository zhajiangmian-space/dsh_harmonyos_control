// DSH WebSocket 反代：剥离 Origin 头（鸿蒙 WebSocket 强制带连接域名的 Origin，
// 与 DSH 的 Host 检查冲突），并改写 Host 为 loopback，再转发给 DSH。
// 监听 127.0.0.1:57590，目标 127.0.0.1:57575。
const http = require('http');
const net = require('net');

const PROXY_PORT = 57590;
const TARGET_HOST = '127.0.0.1';
const TARGET_PORT = 57575;

const stripHeaders = (headers) => {
  const out = {};
  for (const [k, v] of Object.entries(headers)) {
    const lk = k.toLowerCase();
    if (lk === 'origin' || lk === 'x-forwarded-for' || lk === 'x-forwarded-proto' ||
        lk === 'x-original-host' || lk === 'x-real-ip' || lk === 'sec-fetch-site') {
      continue;
    }
    out[k] = v;
  }
  out['host'] = `${TARGET_HOST}:${TARGET_PORT}`;
  return out;
};

const server = http.createServer((req, res) => {
  const headers = stripHeaders(req.headers);
  const proxy = http.request({
    host: TARGET_HOST,
    port: TARGET_PORT,
    method: req.method,
    path: req.url,
    headers,
  }, (pres) => {
    res.writeHead(pres.statusCode ?? 502, pres.headers);
    pres.pipe(res);
  });
  proxy.on('error', () => {
    if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain' });
    res.end('bad gateway');
  });
  req.pipe(proxy);
});

server.on('upgrade', (req, socket, head) => {
  const headers = stripHeaders(req.headers);
  const upstream = net.connect(TARGET_PORT, TARGET_HOST, () => {
    let raw = `${req.method} ${req.url} HTTP/1.1\r\n`;
    for (const [k, v] of Object.entries(headers)) {
      if (v !== undefined) raw += `${k}: ${Array.isArray(v) ? v.join(', ') : String(v)}\r\n`;
    }
    raw += '\r\n';
    upstream.write(raw);
    if (head && head.length > 0) upstream.write(head);
    socket.pipe(upstream);
    upstream.pipe(socket);
  });
  upstream.on('error', () => socket.destroy());
  socket.on('error', () => upstream.destroy());
});

server.listen(PROXY_PORT, '127.0.0.1', () => {
  console.log(`dsh-ws-proxy listening on 127.0.0.1:${PROXY_PORT} -> ${TARGET_HOST}:${TARGET_PORT}`);
});
