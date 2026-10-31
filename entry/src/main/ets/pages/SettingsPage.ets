/**
 * 设置页：服务器地址 + 认证密钥 + CA 证书
 */
import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { AppGlobals } from '../common/AppGlobals';

@Entry
@Component
struct SettingsPage {
  @State serverUrl: string = '';
  @State innerAuthority: string = '';
  @State secret: string = '';
  @State caPath: string = '';
  @State testing: boolean = false;
  @State testResult: string = '';
  @State showSecret: boolean = false;
  private context: common.Context = getContext(this);

  async aboutToAppear(): Promise<void> {
    const g = AppGlobals.get();
    this.serverUrl = g.serverUrl;
    this.innerAuthority = g.innerAuthority;
    this.secret = g.secret;
    this.caPath = g.caPath;
  }

  /** 选择 CA 证书文件并复制到 App 沙箱 */
  async pickCa(): Promise<void> {
    try {
      const documentPicker = new picker.DocumentViewPicker(this.context);
      const uris = await documentPicker.select({ maxSelectNumber: 1 });
      if (uris.length === 0) {
        return;
      }
      const srcUri = uris[0];
      const srcFile = fs.openSync(srcUri, fs.OpenMode.READ_ONLY);
      const dstPath = this.context.filesDir + '/dsh-ca.crt';
      const dstFile = fs.openSync(dstPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.copyFileSync(srcFile.fd, dstFile.fd);
      fs.closeSync(srcFile);
      fs.closeSync(dstFile);
      this.caPath = dstPath;
      promptAction.showToast({ message: '证书已导入' });
    } catch (e) {
      promptAction.showToast({ message: '导入失败：' + (e as Error).message });
    }
  }

  async saveAndTest(): Promise<void> {
    if (this.serverUrl.trim() === '') {
      promptAction.showToast({ message: '请填写服务器地址' });
      return;
    }
    if (this.secret.trim() === '') {
      promptAction.showToast({ message: '请填写认证密钥' });
      return;
    }
    this.testing = true;
    this.testResult = '';
    const g = AppGlobals.get();
    try {
      await g.save(this.context, this.serverUrl, this.innerAuthority, this.secret, this.caPath);
      const msg = await g.api.testConnection();
      this.testResult = msg;
      promptAction.showToast({ message: msg });
    } catch (e) {
      const msg = (e as Error).message ?? String(e);
      this.testResult = '失败：' + msg;
      promptAction.showToast({ message: this.testResult });
    } finally {
      this.testing = false;
    }
  }

  build() {
    Column({ space: 16 }) {
      Row() {
        Button('返回')
          .fontSize(15)
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .onClick(() => {
            router.back();
          })
        Text('设置')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Row().width(60)
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 12 })

      Scroll() {
        Column({ space: 20 }) {
          // 服务器地址
          Column({ space: 8 }) {
            Text('电脑的 Tailscale 地址（如 https://100.64.0.10:57580）')
              .fontSize(13)
              .fontColor('#666666')
              .width('100%')
            TextInput({ text: this.serverUrl, placeholder: 'https://100.x.y.z:57580' })
              .fontSize(14)
              .width('100%')
              .onChange((v: string) => {
                this.serverUrl = v;
              })
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')

          // 认证密钥
          Column({ space: 8 }) {
            Text('认证密钥（电脑上 .credentials.yaml 里的 browser-session secret）')
              .fontSize(13)
              .fontColor('#666666')
              .width('100%')
            Row({ space: 8 }) {
              TextInput({
                text: this.secret,
                placeholder: '粘贴 43 位密钥',
              })
                .fontSize(14)
                .layoutWeight(1)
                .type(this.showSecret ? InputType.Normal : InputType.Password)
                .onChange((v: string) => {
                  this.secret = v;
                })
              Button(this.showSecret ? '隐藏' : '显示')
                .fontSize(13)
                .buttonStyle(ButtonStyleMode.TEXTUAL)
                .onClick(() => {
                  this.showSecret = !this.showSecret;
                })
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')

          // 内网地址（cpolar 隧道模式必填，直连模式留空）
          Column({ space: 8 }) {
            Text('内网地址（cpolar 模式填 127.0.0.1:57575；Tailscale 直连留空）')
              .fontSize(13)
              .fontColor('#666666')
              .width('100%')
            TextInput({ text: this.innerAuthority, placeholder: '127.0.0.1:57575（直连留空）' })
              .fontSize(14)
              .width('100%')
              .onChange((v: string) => {
                this.innerAuthority = v;
              })
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')

          // CA 证书
          Column({ space: 8 }) {
            Text('CA 证书（Tailscale 直连模式必填；cpolar 模式不用填，已导入请点清除）')
              .fontSize(13)
              .fontColor('#666666')
              .width('100%')
            Row({ space: 8 }) {
              Text(this.caPath !== '' ? '已导入' : '未导入')
                .fontSize(14)
                .fontColor(this.caPath !== '' ? '#00a650' : '#999999')
                .layoutWeight(1)
              Button('选择')
                .fontSize(13)
                .buttonStyle(ButtonStyleMode.TEXTUAL)
                .onClick(() => {
                  this.pickCa();
                })
              if (this.caPath !== '') {
                Button('清除')
                  .fontSize(13)
                  .buttonStyle(ButtonStyleMode.TEXTUAL)
                  .fontColor('#e0342a')
                  .onClick(() => {
                    this.caPath = '';
                    promptAction.showToast({ message: '证书已清除' });
                  })
              }
            }
            .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')

          Button(this.testing ? '测试中…' : '保存并测试连接')
            .width('100%')
            .height(44)
            .enabled(!this.testing)
            .onClick(() => {
              this.saveAndTest();
            })

          if (this.testResult !== '') {
            Text(this.testResult)
              .fontSize(14)
              .fontColor(this.testResult.startsWith('连接成功') ? '#00a650' : '#e0342a')
              .width('100%')
          }

          Text('地址在电脑 Tailscale 客户端里看（100 开头的那串 IP），端口默认 57580。证书在 DSH 桌面版的局域网设置里点「导出局域网 CA 证书」获得，通过微信/QQ 等发到手机后再导入。')
            .fontSize(12)
            .fontColor('#999999')
            .width('100%')
            .lineHeight(18)
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 20 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#ffffff')
  }
}
