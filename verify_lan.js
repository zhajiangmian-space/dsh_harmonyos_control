// DSH LAN 模式验证脚本：DSH 重启后运行，验证手机 App 的接入条件
// 用法：node verify_lan.js <电脑IP> [端口] [secret]
// 例：node verify_lan.js 100.64.0.10 57580
const https = require('https');
const fs = require('fs');
const os = require('os');
const crypto = require('crypto');

const ip = process.argv[2];
const port = parseInt(process.argv[3] ?? '57580', 10);
const secret = process.argv[4];

function encodeBase64Url(b) { return Buffer.from(b).toString('base64').replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, ''); }

function readSecret() {
  if (secret) return secret;
  const home = os.homedir();
  const p = home + '/.dsh/.credentials.yaml';
  const c = fs.readFileSync(p, 'utf8');
  const m = c.match(/browser-session[\s\S]*?secret:\s*(\S+)/);
  if (!m) throw new Error('secret not found in .credentials.yaml');
  return m[1];
}

function makeCookie(authority, secretB64url) {
  const secretBytes = Buffer.from(secretB64url.replaceAll('-', '+').replaceAll('_', '/'), 'base64');
  const cookieName = 'dsh-auth-' + encodeBase64Url(crypto.createHash('sha256').update(authority).digest());
  const now = Date.now();
  const payload = { version: 1, authority, issuedAt: now, expiresAt: now + 30 * 24 * 3600 * 1000 };
  const body = encodeBase64Url(Buffer.from(JSON.stringify(payload), 'utf8'));
  const sig = crypto.createHmac('sha256', secretBytes).update(body).digest();
  return cookieName + '=' + 'v1.' + body + '.' + encodeBase64Url(sig);
}

function findTailscaleIp() {
  const ifs = os.networkInterfaces();
  const ips = [];
  for (const k of Object.keys(ifs)) for (const a of ifs[k] ?? []) {
    if (a.family === 'IPv4' && a.address.startsWith('100.')) ips.push(a.address);
  }
  return ips;
}

function rpc(host, port, endpoint, cookie) {
  return new Promise((resolve) => {
    const body = JSON.stringify({ type: 'client-request', rpcId: 'v-' + Math.random().toString(36).slice(2), method: endpoint, payload: { args: { _request: {} } } });
    const req = https.request({
      host, port, path: '/api/' + endpoint, method: 'POST',
      rejectUnauthorized: false,
      headers: { 'Cookie': cookie, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, (res) => { let data = ''; res.on('data', (c) => data += c);
      res.on('end', () => resolve({ status: res.statusCode, body: data })); });
    req.on('error', (e) => resolve({ error: e.message }));
    req.write(body);
    req.end();
  });
}

(async () => {
  const ips = findTailscaleIp();
  console.log('本机 Tailscale 地址:', ips.length > 0 ? ips.join(', ') : '未找到（Tailscale 未安装或未登录）');
  if (!ip) {
    if (ips.length === 0) process.exit(1);
    console.log('用法：node verify_lan.js <IP> [端口]  将自动用 100 开头地址验证');
  }
  const targetIp = ip ?? ips[0];
  const s = readSecret();
  const authority = `${targetIp}:${port}`;
  console.log('验证目标: https://' + authority + '（cookie authority=' + authority + '）');
  const cookie = makeCookie(authority, s);
  const r = await rpc(targetIp, port, 'session/list', cookie);
  console.log('\n=== 验证结果 ===');
  console.log('HTTP', r.status);
  if (r.status === 200) {
    const j = JSON.parse(r.body);
    if (j.result?.ok) {
      console.log('✅ LAN 模式认证成功！会话数:', (j.result.value?.items ?? []).length);
      console.log('手机 App 配置：地址 https://' + targetIp + ':' + port + '，密钥 + 证书即可连接');
    } else {
      console.log('❌ RPC 失败:', JSON.stringify(j.result?.error ?? j).slice(0, 300));
    }
  } else if (r.status === 401) {
    console.log('❌ 认证失败（401）：密钥或 authority 不匹配');
  } else if (r.status === 403) {
    console.log('❌ 信任检查失败（403）：LAN 监听器未绑定该 IP，或 Host 检查不通过');
  } else {
    console.log('❌ 异常:', (r.body ?? r.error ?? '').toString().slice(0, 300));
  }
})();
