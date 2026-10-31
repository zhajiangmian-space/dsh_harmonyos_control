# DSH 遥控（DshRemoteHOS）

鸿蒙 NEXT 原生应用（ArkTS），用手机在外网远程控制电脑上的 DSH NEXT：发消息对话、查看会话记录、看 AI 实时回复、发图片（含多图）。

## 功能

- 会话列表：按项目/工作区分组，显示运行状态，支持归档/取消归档（归档沉底变灰）
- 聊天：实时流式回复（打字机效果）、历史消息分页加载、失败重发/删除
- 图片：一次最多 9 张，发送前自动压缩，缩略图横排，点开全屏左右滑动浏览
- 模型：手机上查看并切换当前会话模型
- 网络：cpolar 内网穿透 + 电脑端本地反代（剥离 Origin 头），手机无需装任何其他 App

## 快速开始

1. 电脑端准备：安装 cpolar（免费账号），执行 `电脑端一键启动.bat`（自动启动反代 + 隧道）
2. 手机端：安装本 App（签名包），设置里填服务器地址（cpolar 公网地址）、内网地址 `127.0.0.1:57575`、认证密钥
3. 详见《部署指南.md》

## 开发环境

- DevEco Studio 5.0 及以上（HarmonyOS NEXT，API 12+，本项目 targetSdkVersion 26）
- 华为开发者账号（自动签名）
- Node.js 与 hvigor（DevEco 自带）

编译命令（在项目根目录）：

```
hvigorw --mode module -p product=default assembleHap
```

## 工程结构

```
entry/src/main/ets/
├── entryability/EntryAbility.ets   应用入口
├── pages/Index.ets                 会话列表主页（项目分组 + 归档）
├── pages/ChatPage.ets              聊天页（follow 流 + 发消息 + 图片 + 模型切换）
├── pages/SettingsPage.ets          设置页（服务器地址 + 内网地址 + 密钥 + CA 证书）
├── net/AuthCookie.ets              DSH 认证 cookie 生成（HMAC-SHA256）
├── net/RpcClient.ets               RPC 客户端（POST /api/<endpoint>）
├── net/StreamClient.ets            remote.mux WebSocket 流客户端（自动重连）
├── api/DshApi.ets                  业务 API（会话/消息/图片/模型/归档）
├── model/Types.ets                 数据模型
├── store/Settings.ets              设置持久化
└── common/AppGlobals.ets           全局单例
```

配套文件：

- `dsh-ws-proxy.js`：电脑端本地反代，剥离 Origin 头（解决鸿蒙 WebSocket 强制 Origin 导致 DSH 403 的问题）
- `电脑端一键启动.bat`：启动反代 + cpolar 隧道
- `部署指南.md`：完整部署说明

## 协议说明（逆向自 DSH NEXT）

- 认证：`dsh-auth-<b64url(sha256(authority))>=v1.<payload>.<hmac>`
- RPC：`POST /api/<endpoint>`，body `{type:'client-request',rpcId,method,payload:{args}}`
- 流：WebSocket `/api/remote.mux`，帧 open/item/end/error/cancel
- 事件：`{type:'event',event:{type,seq,time,data}}`，消息在 data.message.content
- 模型切换：`session/selectModel`（扁平参数：sessionId + provider + model）

## 已知限制

- 图片需模型支持视觉输入（如 deepseek-v4-flash-vision-exp），否则报错
- cpolar 免费版地址约 24 小时变一次，变了需要在 App 设置里更新
- 鸿蒙 WebSocket 无法自定义 Origin 头，必须配合本地反代使用

## License

MIT
