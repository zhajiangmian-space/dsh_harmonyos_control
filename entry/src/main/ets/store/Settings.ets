/**
 * App 设置存储：服务器地址、内网地址、认证 secret、CA 证书路径。
 * 用 preferences 持久化。
 * 支持两种模式：
 *   1) Tailscale/LAN 直连：内网地址填电脑地址（如 100.71.188.95:57580），需要 CA 证书
 *   2) cpolar 隧道：服务器地址填公网 URL，内网地址填 127.0.0.1:57575，不需要证书
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const PREF_NAME = 'dsh_remote_settings';

export class SettingsStore {
  private static pref: preferences.Preferences | null = null;

  private static async getPref(context: common.Context): Promise<preferences.Preferences> {
    if (SettingsStore.pref === null) {
      SettingsStore.pref = await preferences.getPreferences(context, PREF_NAME);
    }
    return SettingsStore.pref;
  }

  static async getServerUrl(context: common.Context): Promise<string> {
    const pref = await SettingsStore.getPref(context);
    return (await pref.get('server_url', '')) as string;
  }

  static async getInnerAuthority(context: common.Context): Promise<string> {
    const pref = await SettingsStore.getPref(context);
    return (await pref.get('inner_authority', '')) as string;
  }

  static async getSecret(context: common.Context): Promise<string> {
    const pref = await SettingsStore.getPref(context);
    return (await pref.get('secret', '')) as string;
  }

  static async getCaPath(context: common.Context): Promise<string> {
    const pref = await SettingsStore.getPref(context);
    return (await pref.get('ca_path', '')) as string;
  }

  static async save(context: common.Context, serverUrl: string, innerAuthority: string, secret: string, caPath: string): Promise<void> {
    const pref = await SettingsStore.getPref(context);
    await pref.put('server_url', serverUrl.trim().replace(/\/+$/, ''));
    await pref.put('inner_authority', innerAuthority.trim());
    await pref.put('secret', secret.trim());
    await pref.put('ca_path', caPath.trim());
    await pref.flush();
  }
}
