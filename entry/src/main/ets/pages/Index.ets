/**
 * 会话列表主页（Agents Anywhere 风格）
 */
import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppGlobals } from '../common/AppGlobals';
import { SessionSummary, WorkspaceInfo } from '../model/Types';
import { StreamFrame, StreamListener } from '../net/StreamClient';

interface SessionItem {
  sessionId: string;
  title: string;
  timeText: string;
  running: boolean;
  subagent: boolean;
  archived: boolean;
}

interface ProjectGroup {
  key: string;
  name: string;
  sessions: SessionItem[];
}

@Entry
@Component
struct Index {
  @State groups: ProjectGroup[] = [];
  @State loading: boolean = false;
  @State configured: boolean = false;
  @State totalSessions: number = 0;
  @State errorText: string = '';
  @State workspaces: WorkspaceInfo[] = [];
  @State archivedIds: string[] = [];
  private context: common.Context = getContext(this);
  private wsStreamId: string = '';

  async aboutToAppear(): Promise<void> {
    const g = AppGlobals.get();
    await g.load(this.context);
    this.configured = g.configured;
    if (g.configured) {
      await this.loadWorkspaceData();
      await this.refresh();
    }
  }

  async onPageShow(): Promise<void> {
    const g = AppGlobals.get();
    this.configured = g.configured;
    if (g.configured && this.groups.length === 0 && !this.loading) {
      await this.loadWorkspaceData();
      await this.refresh();
    }
  }

  /** 通过 workspace/follow 流拿工作区列表和归档/置顶数据；等 baseline 到达（或超时）再返回 */
  async loadWorkspaceData(): Promise<void> {
    const g = AppGlobals.get();
    if (!g.configured) {
      return;
    }
    return new Promise<void>((resolve: () => void) => {
      let settled = false;
      const finish = (): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (this.wsStreamId !== '') {
          g.stream.closeStream(this.wsStreamId);
          this.wsStreamId = '';
        }
        resolve();
      };
      // 超时保护：5 秒内没拿到 baseline 也继续（不影响会话列表）
      setTimeout(finish, 5000);
      try {
        g.ensureStream(() => {
        }).then(() => {
          const listener: StreamListener = {
            onFrame: (frame: StreamFrame) => {
              if (frame.type === 'item' && frame.value !== undefined) {
                const v = frame.value as Record<string, Object>;
                if (String(v['type'] ?? '') === 'baseline') {
                  this.applyWorkspaceBaseline(v);
                  finish();
                }
              }
            },
            onError: () => {
              finish();
            },
          };
          const emptyArgs: Record<string, Object> = {};
          const payload: Record<string, Object> = { 'args': emptyArgs };
          this.wsStreamId = g.stream.openStream('workspace/follow', payload, listener);
        }).catch(() => {
          finish();
        });
      } catch (e) {
        finish();
      }
    });
  }

  applyWorkspaceBaseline(v: Record<string, Object>): void {
    const value = (v['value'] ?? {}) as Record<string, Object>;
    const archived = value['archivedSessionIds'] as string[] | undefined;
    this.archivedIds = archived !== undefined ? archived : [];
    const items = value['items'] as object[] | undefined;
    const list: WorkspaceInfo[] = [];
    if (items) {
      for (const it of items) {
        const r = it as Record<string, Object>;
        const w = new WorkspaceInfo();
        w.workspaceId = String(r['workspaceId'] ?? '');
        w.path = String(r['path'] ?? '');
        w.title = String(r['title'] ?? '');
        const ids = r['sessionIds'] as string[] | undefined;
        w.sessionIds = ids !== undefined ? ids : [];
        list.push(w);
      }
    }
    this.workspaces = list;
  }

  async refresh(): Promise<void> {
    const g = AppGlobals.get();
    if (!g.configured) {
      return;
    }
    this.loading = true;
    this.errorText = '';
    try {
      const list = await g.api.sessionList();
      this.groups = this.groupByProject(list);
      this.totalSessions = list.length;
    } catch (e) {
      this.errorText = (e as Error).message ?? String(e);
      promptAction.showToast({ message: '加载失败：' + this.errorText });
    } finally {
      this.loading = false;
    }
  }

  /** 归档/取消归档 */
  async toggleArchive(item: SessionItem): Promise<void> {
    const g = AppGlobals.get();
    hilog.info(0x0000, 'DshRemote', 'toggleArchive: %{public}s archived=%{public}s ids=%{public}d',
      item.sessionId, String(item.archived), this.archivedIds.length);
    try {
      if (item.archived) {
        await g.api.sessionUnarchive(item.sessionId);
        promptAction.showToast({ message: '已取消归档' });
        this.archivedIds = this.archivedIds.filter((id: string) => id !== item.sessionId);
      } else {
        await g.api.sessionArchive(item.sessionId);
        promptAction.showToast({ message: '已归档' });
        if (!this.archivedIds.includes(item.sessionId)) {
          this.archivedIds = this.archivedIds.concat([item.sessionId]);
        }
      }
      hilog.info(0x0000, 'DshRemote', 'after update archivedIds=%{public}d', this.archivedIds.length);
      // 本地立即重新分组，不必等 workspace 数据流
      await this.refresh();
      hilog.info(0x0000, 'DshRemote', 'refresh done, groups=%{public}d', this.groups.length);
    } catch (e) {
      hilog.error(0x0000, 'DshRemote', 'toggleArchive failed: %{public}s', (e as Error).message);
      promptAction.showToast({ message: '操作失败：' + (e as Error).message });
    }
  }

  /** 分组渲染 key：包含组内每个会话 id 和归档状态，任何位置/状态变化都强制刷新 UI */
  groupKey(group: ProjectGroup): string {
    const sig = group.sessions
      .map((s: SessionItem) => s.sessionId + (s.archived ? 'a' : 'n'))
      .join(',');
    return group.key + '|' + sig;
  }

  /** 会话操作菜单 */
  showSessionMenu(item: SessionItem): void {
    const buttons: promptAction.Button[] = [];
    buttons.push({ text: item.archived ? '取消归档' : '归档', color: '#1d1d1f' });
    buttons.push({ text: '取消', color: '#8e8e93' });
    promptAction.showDialog({
      title: item.title,
      buttons: buttons,
    }).then((result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index === 0) {
        this.toggleArchive(item);
      }
    }).catch(() => {
    });
  }

  /** 分组：按工作区分组；组内未归档在前、已归档沉底（都按时间倒序）。子代理会话不展示。 */
  groupByProject(list: SessionSummary[]): ProjectGroup[] {
    const sorted = list.slice();
    sorted.sort((a: SessionSummary, b: SessionSummary) => b.updatedAt - a.updatedAt);
    const archivedSet: Set<string> = new Set(this.archivedIds);
    const map: Map<string, ProjectGroup> = new Map();
    // 每个分组内再分未归档/已归档两段
    const archivedByGroup: Map<string, SessionItem[]> = new Map();
    for (const s of sorted) {
      // 子代理会话（任务内部产生）不在主列表展示，与 DSH 桌面版左侧列表保持一致
      if (s.origin === 'subagent') {
        continue;
      }
      const isArchived = archivedSet.has(s.sessionId);
      const item: SessionItem = {
        sessionId: s.sessionId,
        title: this.displayTitle(s),
        timeText: this.shortTime(s.updatedAt),
        running: s.running,
        subagent: false,
        archived: isArchived,
      };
      // 优先按工作区（项目）匹配，组名用工作区标题
      const cwd = s.cwd !== undefined ? s.cwd : '';
      const workspace = this.findWorkspace(cwd);
      let key = '__ungrouped__';
      let display = '未分组';
      if (workspace !== null) {
        key = workspace.workspaceId;
        display = workspace.title !== '' ? workspace.title : workspace.path;
      } else if (cwd !== '') {
        key = this.normalizeCwd(cwd);
        display = this.tailPath(cwd);
      }
      let group = map.get(key);
      if (group === undefined) {
        group = {
          key: key,
          name: display,
          sessions: [],
        };
        map.set(key, group);
      }
      if (isArchived) {
        let arch = archivedByGroup.get(key);
        if (arch === undefined) {
          arch = [];
          archivedByGroup.set(key, arch);
        }
        arch.push(item);
      } else {
        group.sessions.push(item);
      }
    }
    // 归档会话沉到各自分组末尾
    const result: ProjectGroup[] = [];
    map.forEach((g: ProjectGroup) => {
      const arch = archivedByGroup.get(g.key);
      if (arch !== undefined) {
        for (const a of arch) {
          g.sessions.push(a);
        }
      }
      result.push(g);
    });
    return result;
  }

  /** 按 cwd 匹配工作区 */
  findWorkspace(cwd: string): WorkspaceInfo | null {
    if (cwd === '') {
      return null;
    }
    const norm = this.normalizeCwd(cwd);
    for (const w of this.workspaces) {
      if (this.normalizeCwd(w.path) === norm) {
        return w;
      }
    }
    return null;
  }

  /** cwd 规范化：大小写、尾部反斜杠统一，避免同一项目拆成多组 */
  normalizeCwd(p: string): string {
    return p.replace(/[\\/]+$/, '').toLowerCase();
  }

  tailPath(p: string): string {
    const parts = p.split('\\');
    const last = parts.length > 0 ? parts[parts.length - 1] : p;
    return last !== '' ? last : p;
  }

  displayTitle(s: SessionSummary): string {
    if (s.title !== undefined && s.title !== '') {
      return s.title;
    }
    if (s.blank) {
      return '空白会话';
    }
    return '新会话';
  }

  /** 相对时间：刚刚 / X分钟 / X小时 / X天 / 日期 */
  shortTime(ts: number): string {
    const diffMs = Date.now() - ts;
    const min = Math.floor(diffMs / 60000);
    if (min < 1) {
      return '刚刚';
    }
    if (min < 60) {
      return min + '分钟';
    }
    const hour = Math.floor(min / 60);
    if (hour < 24) {
      return hour + '小时';
    }
    const day = Math.floor(hour / 24);
    if (day < 30) {
      return day + '天';
    }
    const d = new Date(ts);
    return String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
  }

  async createSession(): Promise<void> {
    const g = AppGlobals.get();
    if (!g.configured) {
      router.pushUrl({ url: 'pages/SettingsPage' });
      return;
    }
    try {
      const sessionId = await g.api.sessionCreate();
      const params: Record<string, string> = {
        'sessionId': sessionId,
        'title': '新会话',
      };
      const options: router.RouterOptions = {
        url: 'pages/ChatPage',
        params: params,
      };
      router.pushUrl(options);
    } catch (e) {
      promptAction.showToast({ message: '新建失败：' + (e as Error).message });
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        // 顶栏：圆形头像 + 标题 + 操作按钮
        Row({ space: 10 }) {
          // 圆形头像
          Text('🐋')
            .fontSize(22)
            .width(42)
            .height(42)
            .textAlign(TextAlign.Center)
            .backgroundColor('#e8e6e1')
            .borderRadius(21)
          Text('DSH 遥控')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1d1d1f')
            .layoutWeight(1)
          Button('刷新')
            .fontSize(13)
            .fontColor('#1d1d1f')
            .height(36)
            .padding({ left: 12, right: 12 })
            .backgroundColor('#ebe9e4')
            .borderRadius(18)
            .onClick(() => {
              this.refresh();
            })
          Button('设置')
            .fontSize(13)
            .fontColor('#1d1d1f')
            .height(36)
            .padding({ left: 12, right: 12 })
            .backgroundColor('#ebe9e4')
            .borderRadius(18)
            .onClick(() => {
              router.pushUrl({ url: 'pages/SettingsPage' });
            })
        }
        .width('100%')
        .padding({ left: 20, right: 12, top: 16, bottom: 14 })

        // 功能卡片（图标 + 标签 + 值）
        Row({ space: 12 }) {
          // 设备卡片
          Column({ space: 10 }) {
            Text('🖥️')
              .fontSize(26)
            Column({ space: 2 }) {
              Text('设备')
                .fontSize(13)
                .fontColor('#8e8e93')
              Text(this.configured ? '已连接' : '未连接')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.configured ? '#00a650' : '#e0342a')
            }
          }
          .layoutWeight(1)
          .padding({ top: 16, bottom: 16 })
          .backgroundColor('#ffffff')
          .borderRadius(16)
          .onClick(() => {
            if (!this.configured) {
              router.pushUrl({ url: 'pages/SettingsPage' });
            }
          })

          // 会话卡片
          Column({ space: 10 }) {
            Text('💬')
              .fontSize(26)
            Column({ space: 2 }) {
              Text('会话')
                .fontSize(13)
                .fontColor('#8e8e93')
              Text(String(this.totalSessions))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#1d1d1f')
            }
          }
          .layoutWeight(1)
          .padding({ top: 16, bottom: 16 })
          .backgroundColor('#ffffff')
          .borderRadius(16)
          .onClick(() => {
            this.refresh();
          })

          // 设置卡片
          Column({ space: 10 }) {
            Text('⚙️')
              .fontSize(26)
            Column({ space: 2 }) {
              Text('设置')
                .fontSize(13)
                .fontColor('#8e8e93')
              Text('配置')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#1d1d1f')
            }
          }
          .layoutWeight(1)
          .padding({ top: 16, bottom: 16 })
          .backgroundColor('#ffffff')
          .borderRadius(16)
          .onClick(() => {
            router.pushUrl({ url: 'pages/SettingsPage' });
          })
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 6 })

        // 未配置提示
        if (!this.configured) {
          Column({ space: 12 }) {
            Text('还没有配置服务器')
              .fontSize(16)
              .fontColor('#666666')
            Button('去设置')
              .onClick(() => {
                router.pushUrl({ url: 'pages/SettingsPage' });
              })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          // 项目分组列表
          Scroll() {
            Column() {
              if (this.loading && this.groups.length === 0) {
                Text('加载中…')
                  .fontSize(14)
                  .fontColor('#999999')
                  .padding(20)
              }
              ForEach(this.groups, (group: ProjectGroup) => {
                Column() {
                  // 分组头：文件夹图标 + 项目名 + 右侧数量徽标（已归档组灰色）
                  Row({ space: 8 }) {
                    Text(group.key === '__archived__' ? '📦' : '📁')
                      .fontSize(17)
                    Text(group.name)
                      .fontSize(15)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(group.key === '__archived__' ? '#b8b8b8' : '#1d1d1f')
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                    Text(String(group.sessions.length))
                      .fontSize(11)
                      .fontColor(group.key === '__archived__' ? '#c8c8c8' : '#8e8e93')
                      .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                      .backgroundColor(group.key === '__archived__' ? '#f2f1ee' : '#ebe9e4')
                      .borderRadius(9)
                  }
                  .width('100%')
                  .padding({ left: 20, right: 20, top: 16, bottom: 4 })

                  // 会话项：圆形头像 + 标题/时间 + 状态点（已归档的显示灰色）
                  ForEach(group.sessions, (item: SessionItem) => {
                    Row({ space: 12 }) {
                      Text('🐋')
                        .fontSize(16)
                        .width(38)
                        .height(38)
                        .textAlign(TextAlign.Center)
                        .backgroundColor(item.archived ? '#f2f1ee' : '#eef1f6')
                        .borderRadius(19)
                        .opacity(item.archived ? 0.6 : 1)
                      Column({ space: 3 }) {
                        Text(item.title)
                          .fontSize(15)
                          .fontColor(item.archived ? '#b8b8b8' : '#1d1d1f')
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                        Text(item.timeText)
                          .fontSize(12)
                          .fontColor(item.archived ? '#c8c8c8' : '#8e8e93')
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)
                      if (item.running) {
                        Circle({ width: 9, height: 9 })
                          .fill('#00a650')
                      }
                      if (item.subagent) {
                        Text('子代理')
                          .fontSize(10)
                          .fontColor('#7e57c2')
                          .backgroundColor('#ede7f6')
                          .borderRadius(4)
                          .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                      }
                      // 操作菜单（归档/取消归档）
                      Text('•••')
                        .fontSize(15)
                        .fontColor('#8e8e93')
                        .width(34)
                        .height(34)
                        .textAlign(TextAlign.Center)
                        .onClick(() => {
                          this.showSessionMenu(item);
                        })
                    }
                    .width('100%')
                    .padding({ left: 20, right: 10, top: 9, bottom: 9 })
                    .onClick(() => {
                      const params: Record<string, string> = {
                        'sessionId': item.sessionId,
                        'title': item.title,
                      };
                      const options: router.RouterOptions = {
                        url: 'pages/ChatPage',
                        params: params,
                      };
                      router.pushUrl(options);
                    })
                  }, (item: SessionItem) => item.sessionId + (item.archived ? ':a' : ':n'))
                }
                .width('100%')
              }, (group: ProjectGroup) => this.groupKey(group))
            }
            .width('100%')
            .padding({ bottom: 90 })
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#faf9f6')

      // 浮动新建按钮（底部居中）
      Button('＋')
        .fontSize(26)
        .fontColor('#ffffff')
        .width(58)
        .height(58)
        .borderRadius(29)
        .backgroundColor('#1d1d1f')
        .margin({ bottom: 28 })
        .onClick(() => {
          this.createSession();
        })
    }
    .width('100%')
    .height('100%')
  }
}
