/**
 * DSH NEXT 浏览器会话认证 cookie 生成器。
 * 协议（逆向自 DSH NEXT 的 browser-auth）：
 *   cookie 名 = 'dsh-auth-' + base64url(sha256(authority))
 *   cookie 值 = 'v1.' + base64url(JSON{version,authority,issuedAt,expiresAt}) + '.' + base64url(hmacSha256(secret, body))
 *   authority：http 时为 host[:port]（默认 80 省略），https 时为 'https://host[:port]'（默认 443 省略）
 *   secret：DSH 数据目录 .credentials.yaml 里 client-connection/browser-session 的 secret（base64url 32 字节）
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';

export class AuthCookie {
  private static textEncoder: util.TextEncoder = new util.TextEncoder();
  private static base64Helper: util.Base64Helper = new util.Base64Helper();

  /** 标准 base64 转 base64url（无填充） */
  private static toBase64Url(standard: string): string {
    return standard.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }

  /** base64url 解码为字节（secret 用） */
  private static fromBase64Url(value: string): Uint8Array {
    let std = value.replace(/-/g, '+').replace(/_/g, '/');
    const padding = (4 - std.length % 4) % 4;
    std += '='.repeat(padding);
    return AuthCookie.base64Helper.decodeSync(std);
  }

  private static utf8Bytes(text: string): Uint8Array {
    return AuthCookie.textEncoder.encodeInto(text);
  }

  private static utf8Text(bytes: Uint8Array): string {
    return new util.TextDecoder('utf-8').decodeWithStream(bytes);
  }

  private static async sha256(data: Uint8Array): Promise<Uint8Array> {
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: data });
    const out = await md.digest();
    return new Uint8Array(out.data);
  }

  private static async hmacSha256(keyBytes: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
    // 鸿蒙 cryptoFramework：Mac 的算法名是摘要算法名 'SHA256'，不是 'SHA256|HMAC'
    const mac = cryptoFramework.createMac('SHA256');
    const keyGen = cryptoFramework.createSymKeyGenerator('HMAC');
    const keyBlob: cryptoFramework.DataBlob = { data: keyBytes };
    const symKey = await keyGen.convertKey(keyBlob);
    await mac.init(symKey);
    await mac.update({ data: data });
    const out = await mac.doFinal();
    return new Uint8Array(out.data);
  }

  /**
   * 计算某个 authority 对应的认证 cookie 头值（形如 name=value）。
   * @param secretB64url .credentials.yaml 里的 secret 字符串
   * @param authority 规范化 authority（http: host[:port]；https: https://host[:port]）
   */
  static async compute(secretB64url: string, authority: string): Promise<string> {
    const secretBytes = AuthCookie.fromBase64Url(secretB64url.trim());
    const now = Date.now();
    const maxAgeMs = 30 * 24 * 3600 * 1000; // 30 天
    const payloadObj: Record<string, Object> = {
      'version': 1,
      'authority': authority,
      'issuedAt': now,
      'expiresAt': now + maxAgeMs,
    };
    const body = AuthCookie.toBase64Url(
      AuthCookie.base64Helper.encodeToStringSync(AuthCookie.utf8Bytes(JSON.stringify(payloadObj))));
    const sigBytes = await AuthCookie.hmacSha256(secretBytes, AuthCookie.utf8Bytes(body));
    const sig = AuthCookie.toBase64Url(AuthCookie.base64Helper.encodeToStringSync(sigBytes));
    const nameHash = await AuthCookie.sha256(AuthCookie.utf8Bytes(authority));
    const name = 'dsh-auth-' + AuthCookie.toBase64Url(AuthCookie.base64Helper.encodeToStringSync(nameHash));
    return `${name}=v1.${body}.${sig}`;
  }

  /**
   * 从配置的服务器地址计算 authority。
   * 实测结论：DSH 的 LAN/隧道入口都把请求转发到 HTTP loopback 层并保留 Host，
   * 认证 authority = host:port（不带 scheme）。
   * 例：http://127.0.0.1:57575 -> '127.0.0.1:57575'
   *     https://100.71.188.95:57580 -> '100.71.188.95:57580'
   *     https://abc.cpolar.cn -> 'abc.cpolar.cn'
   */
  static authorityOf(baseUrl: string): string {
    const trimmed = baseUrl.trim().replace(/\/+$/, '');
    const m = trimmed.match(/^https?:\/\/([^\/]+)/i);
    if (!m) {
      return '';
    }
    let hostPort = m[1];
    // 拆 host 与 port
    let host = hostPort;
    let port = '';
    if (hostPort.startsWith('[')) {
      // IPv6，跳过
      host = hostPort;
    } else {
      const idx = hostPort.lastIndexOf(':');
      if (idx > 0 && hostPort.indexOf(':') === idx) {
        host = hostPort.slice(0, idx);
        port = hostPort.slice(idx + 1);
      }
    }
    // 默认端口省略（与 WHATWG URL.host 规范化一致）
    return port === '443' || port === '80' || port === '' ? host : `${host}:${port}`;
  }
}
