/**
 * DSH NEXT RPC 客户端。
 * 协议：POST /api/<endpoint>
 *   body: {type:'client-request', rpcId, method:endpoint, payload:{args}}
 *   响应: {type:'server-response', rpcId, result:{ok, value|error}}
 * 认证：浏览器会话 cookie（AuthCookie.compute 生成）。
 * LAN 模式：HTTPS + 自签名证书，通过 caPath 信任 DSH 导出的 CA 证书。
 */
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { AuthCookie } from './AuthCookie';

export class RpcError extends Error {
  code: string = '';
  details: string = '';

  constructor(code: string, message: string, details: string = '') {
    super(message);
    this.name = 'RpcError';
    this.code = code;
    this.details = details;
  }
}

export class RpcClient {
  baseUrl: string = '';
  authority: string = '';
  caPath: string = '';
  private cookie: string = '';
  private configured: boolean = false;

  /**
   * 配置服务器。
   * @param baseUrl 入口地址（LAN 模式：https://<电脑地址>:<lanPort>）
   * @param secretB64url 认证密钥
   * @param innerAuthority cookie 的 authority（缺省从 baseUrl 推导）
   * @param caPath 自签名 CA 证书路径（LAN 模式必填）
   */
  async configure(baseUrl: string, secretB64url: string, innerAuthority: string = '', caPath: string = ''): Promise<void> {
    this.baseUrl = baseUrl.trim().replace(/\/+$/, '');
    if (this.baseUrl === '') {
      throw new RpcError('config', '服务器地址不能为空');
    }
    if (innerAuthority !== '') {
      this.authority = innerAuthority.trim();
    } else {
      this.authority = AuthCookie.authorityOf(this.baseUrl);
    }
    if (this.authority === '') {
      throw new RpcError('config', '服务器地址格式不对，需要 http(s):// 开头');
    }
    this.caPath = caPath.trim();
    this.cookie = await AuthCookie.compute(secretB64url, this.authority);
    this.configured = true;
  }

  isConfigured(): boolean {
    return this.configured;
  }

  /** 认证 cookie（流连接也要带） */
  getCookie(): string {
    return this.cookie;
  }

  /** 调用一个 RPC 方法，返回 result.value */
  async invoke(endpoint: string, args: object): Promise<object> {
    if (!this.configured) {
      throw new RpcError('config', '尚未配置服务器');
    }
    const rpcId = util.generateRandomUUID();
    const payloadObj: Record<string, Object> = { 'args': args };
    const envelope: Record<string, Object> = {
      'type': 'client-request',
      'rpcId': rpcId,
      'method': endpoint,
      'payload': payloadObj,
    };
    const body = JSON.stringify(envelope);
    const header: Record<string, string> = {
      'Content-Type': 'application/json',
      'Cookie': this.cookie,
    };
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: header,
      extraData: body,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 15000,
      readTimeout: 60000,
    };
    if (this.caPath !== '') {
      options.caPath = this.caPath;
    }

    const httpRequest = http.createHttp();
    let resp: http.HttpResponse;
    try {
      resp = await httpRequest.request(`${this.baseUrl}/api/${endpoint}`, options);
    } finally {
      httpRequest.destroy();
    }

    if (resp.responseCode !== 200) {
      throw new RpcError('http', `HTTP ${resp.responseCode}`, String(resp.result ?? ''));
    }
    const parsed = JSON.parse(resp.result as string) as Record<string, Object>;
    const result = parsed['result'] as Record<string, Object>;
    if (result === undefined || result['ok'] !== true) {
      const err = (result !== undefined ? result['error'] : undefined) as Record<string, Object> | undefined;
      const code = (err !== undefined && err['code'] !== undefined) ? String(err['code']) : 'unknown';
      const msg = (err !== undefined && err['message'] !== undefined) ? String(err['message']) : 'unknown error';
      const details = (err !== undefined && err['details'] !== undefined) ? JSON.stringify(err['details']) : '';
      throw new RpcError(code, msg, details);
    }
    const value = result['value'];
    if (value !== undefined) {
      return value as object;
    }
    const empty: Record<string, Object> = {};
    return empty;
  }

  /** GET 一个路径（保留给 /remote 文件接口等） */
  async getText(path: string): Promise<string> {
    if (!this.configured) {
      throw new RpcError('config', '尚未配置服务器');
    }
    const header: Record<string, string> = {
      'Cookie': this.cookie,
    };
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: header,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: 15000,
      readTimeout: 60000,
    };
    if (this.caPath !== '') {
      options.caPath = this.caPath;
    }
    const httpRequest = http.createHttp();
    let resp: http.HttpResponse;
    try {
      resp = await httpRequest.request(`${this.baseUrl}${path}`, options);
    } finally {
      httpRequest.destroy();
    }
    if (resp.responseCode !== 200) {
      throw new RpcError('http', `HTTP ${resp.responseCode}`);
    }
    return resp.result as string;
  }

  /** 把 http(s) 基础地址转成 ws(s) 地址 */
  wsUrl(path: string): string {
    const ws = this.baseUrl.startsWith('https://') ? 'wss://' : 'ws://';
    return ws + this.baseUrl.replace(/^https?:\/\//, '') + path;
  }

  /** 测试连接：调用 session/list 验证认证是否通过 */
  async testConnection(): Promise<string> {
    const emptyRequest: Record<string, Object> = {};
    const args: Record<string, Object> = { '_request': emptyRequest };
    const value = await this.invoke('session/list', args) as Record<string, Object>;
    const items = value['items'] as object[] | undefined;
    return `连接成功，共 ${items !== undefined ? items.length : 0} 个会话`;
  }
}
