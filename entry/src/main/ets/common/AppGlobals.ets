/**
 * App 全局单例：持有网络客户端和配置状态。
 */
import { RpcClient } from '../net/RpcClient';
import { StreamClient } from '../net/StreamClient';
import { DshApi } from '../api/DshApi';
import { common } from '@kit.AbilityKit';
import { SettingsStore } from '../store/Settings';

export class AppGlobals {
  private static instance: AppGlobals | null = null;

  rpc: RpcClient = new RpcClient();
  stream: StreamClient = new StreamClient();
  api: DshApi = new DshApi(this.rpc);

  serverUrl: string = '';
  innerAuthority: string = '';
  secret: string = '';
  caPath: string = '';
  configured: boolean = false;

  static get(): AppGlobals {
    if (AppGlobals.instance === null) {
      AppGlobals.instance = new AppGlobals();
    }
    return AppGlobals.instance;
  }

  /** 从持久化设置加载并配置客户端 */
  async load(context: common.Context): Promise<void> {
    this.serverUrl = await SettingsStore.getServerUrl(context);
    this.innerAuthority = await SettingsStore.getInnerAuthority(context);
    this.secret = await SettingsStore.getSecret(context);
    this.caPath = await SettingsStore.getCaPath(context);
    if (this.serverUrl !== '' && this.secret !== '') {
      await this.rpc.configure(this.serverUrl, this.secret, this.innerAuthority, this.caPathForMode());
      this.configured = true;
    }
  }

  /** 保存设置并重新配置 */
  async save(context: common.Context, serverUrl: string, innerAuthority: string, secret: string, caPath: string): Promise<void> {
    await SettingsStore.save(context, serverUrl, innerAuthority, secret, caPath);
    this.serverUrl = serverUrl.trim().replace(/\/+$/, '');
    this.innerAuthority = innerAuthority.trim();
    this.secret = secret.trim();
    this.caPath = caPath.trim();
    await this.rpc.configure(this.serverUrl, this.secret, this.innerAuthority, this.caPathForMode());
    this.configured = true;
  }

  /**
   * cpolar 隧道模式（内网地址非空）用系统默认 CA 验证（cpolar 是正规证书）；
   * Tailscale 直连模式用导入的 DSH 自签名 CA。
   */
  private caPathForMode(): string {
    return this.innerAuthority !== '' ? '' : this.caPath;
  }

  /** 连接流（remote.mux），供聊天页等使用 */
  async ensureStream(onConnected: () => void): Promise<void> {
    // Origin 与 cookie 的 authority 一致（隧道场景 DSH 校验 Origin 与转发后 Host 的一致性）
    const origin = 'http://' + this.rpc.authority;
    await this.stream.connect(this.rpc.wsUrl('/api/remote.mux'), this.rpc.getCookie(), onConnected, this.rpc.caPath, origin);
  }
}
