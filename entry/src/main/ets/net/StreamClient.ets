/**
 * DSH NEXT remote.mux WebSocket 流客户端。
 * 连接：wss(s)://<host>/api/remote.mux（带认证 cookie）
 * 帧协议：
 *   上行：{type:'open',streamId,endpoint,payload} / {type:'item',streamId,value} / {type:'end',streamId} / {type:'cancel',streamId}
 *   下行：{type:'item',streamId,value?} / {type:'end',streamId} / {type:'error',streamId,error:{code,message,details}}
 * 一个物理连接上多路复用多个逻辑流（按 streamId 分发）。
 * 断线自动重连，重连后自动重开所有活动流。
 */
import { webSocket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';

export interface StreamFrame {
  type: string;
  streamId: string;
  endpoint?: string;
  payload?: object;
  value?: object;
  error?: ErrorInfo;
}

export interface ErrorInfo {
  code: string;
  message: string;
  details: object;
}

export interface StreamListener {
  onFrame: (frame: StreamFrame) => void;
  onError: (message: string) => void;
}

interface OpenStream {
  endpoint: string;
  payload: object;
  listener: StreamListener;
}

export class StreamClient {
  private ws: webSocket.WebSocket | null = null;
  private wsUrl: string = '';
  private cookie: string = '';
  private caPath: string = '';
  private origin: string = '';
  private streams: Map<string, OpenStream> = new Map();
  private reconnectTimer: number = -1;
  private wantReconnect: boolean = false;
  private connectedCallback: (() => void) | null = null;
  /** 连接错误提示回调（供页面显示错误） */
  errorCallback: ((message: string) => void) | null = null;

  private reportError(message: string): void {
    hilog.error(0x0000, 'DshRemote', 'StreamClient: %{public}s', message);
    if (this.errorCallback !== null) {
      this.errorCallback(message);
    }
  }

  /** 连接（自动重连：2 秒间隔，重连后自动重开所有活动流）。重复调用不会重复建连。
   * @param origin 握手 Origin 头。隧道场景必须与内网目标一致（DSH 校验 Origin 与转发后 Host 的一致性），
   *               否则 DSH 返回 403。缺省不设置（让系统自动生成）。
   */
  async connect(wsUrl: string, cookie: string, onConnected: () => void, caPath: string = '', origin: string = ''): Promise<void> {
    this.wsUrl = wsUrl;
    this.cookie = cookie;
    this.caPath = caPath;
    this.origin = origin;
    this.wantReconnect = true;
    this.connectedCallback = onConnected;
    if (this.ws !== null || this.reconnectTimer >= 0) {
      // 已有连接或正在重连，直接回调
      onConnected();
      return;
    }
    await this.openSocket();
  }

  private async openSocket(): Promise<void> {
    if (!this.wantReconnect) {
      return;
    }
    const ws = webSocket.createWebSocket();
    this.ws = ws;
    ws.on('open', () => {
      // 重开所有活动流（首连或重连）
      this.streams.forEach((s: OpenStream, streamId: string) => {
        const frame: Record<string, Object> = {
          'type': 'open',
          'streamId': streamId,
          'endpoint': s.endpoint,
          'payload': s.payload,
        };
        this.sendFrame(frame);
      });
      if (this.connectedCallback) {
        this.connectedCallback();
      }
    });
    ws.on('message', (err: BusinessError, value: string | ArrayBuffer) => {
      if (err) {
        this.reportError('收到消息错误: ' + (err.message ?? 'unknown'));
        return;
      }
      let text = '';
      if (typeof value === 'string') {
        text = value;
      } else {
        text = util.TextDecoder.create('utf-8').decodeWithStream(new Uint8Array(value));
      }
      hilog.info(0x0000, 'DshRemote', 'ws frame %{public}d bytes', text.length);
      try {
        const frame = JSON.parse(text) as Record<string, Object>;
        const streamId = String(frame['streamId'] ?? '');
        const entry = this.streams.get(streamId);
        if (entry) {
          const typed: StreamFrame = {
            type: String(frame['type'] ?? ''),
            streamId: streamId,
          };
          if (frame['endpoint'] !== undefined) {
            typed.endpoint = String(frame['endpoint']);
          }
          if (frame['payload'] !== undefined) {
            typed.payload = frame['payload'] as object;
          }
          if (frame['value'] !== undefined) {
            typed.value = frame['value'] as object;
          }
          if (frame['error'] !== undefined) {
            const e = frame['error'] as Record<string, Object>;
            const emptyDetails: Record<string, Object> = {};
            const detailsObj = e['details'] ?? emptyDetails;
            typed.error = {
              code: String(e['code'] ?? ''),
              message: String(e['message'] ?? ''),
              details: detailsObj as object,
            };
          }
          entry.listener.onFrame(typed);
        }
      } catch (_) {
        // 丢弃畸形帧
      }
    });
    ws.on('close', () => {
      if (this.ws === ws) {
        this.ws = null;
      }
      this.scheduleReconnect();
    });
    ws.on('error', (err: BusinessError) => {
      if (this.ws === ws) {
        this.ws = null;
      }
      this.reportError('WebSocket 错误: ' + (err !== undefined && err.message !== undefined ? err.message : 'unknown'));
      this.scheduleReconnect();
    });
    try {
      const header: Record<string, string> = { 'Cookie': this.cookie };
      if (this.origin !== '') {
        header['Origin'] = this.origin;
      }
      const options: webSocket.WebSocketRequestOptions = {
        header: header,
      };
      if (this.caPath !== '') {
        options.caPath = this.caPath;
      } else {
        // 鸿蒙 WebSocket 库的系统证书库缺 Let's Encrypt 根证书（cpolar 场景），跳过验证
        options.skipServerCertVerification = true;
      }
      await ws.connect(this.wsUrl, options);
      hilog.info(0x0000, 'DshRemote', 'StreamClient: ws connect called ok, url=%{public}s', this.wsUrl);
    } catch (e) {
      this.ws = null;
      this.reportError('连接流失败: ' + (e as Error).message);
      this.scheduleReconnect();
    }
  }

  private scheduleReconnect(): void {
    if (!this.wantReconnect || this.reconnectTimer >= 0) {
      return;
    }
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1;
      this.openSocket();
    }, 2000);
  }

  /** 打开一个逻辑流，返回 streamId（重连后自动重开） */
  openStream(endpoint: string, payload: object, listener: StreamListener): string {
    const streamId = util.generateRandomUUID();
    const entry: OpenStream = {
      endpoint: endpoint,
      payload: payload,
      listener: listener,
    };
    this.streams.set(streamId, entry);
    const frame: Record<string, Object> = {
      'type': 'open',
      'streamId': streamId,
      'endpoint': endpoint,
      'payload': payload,
    };
    this.sendFrame(frame);
    return streamId;
  }

  closeStream(streamId: string): void {
    this.streams.delete(streamId);
    const frame: Record<string, Object> = {
      'type': 'cancel',
      'streamId': streamId,
    };
    this.sendFrame(frame);
  }

  private sendFrame(frame: Record<string, Object>): void {
    if (this.ws !== null) {
      try {
        this.ws.send(JSON.stringify(frame));
      } catch (_) {
        // 连接断时忽略，重连后由 open 回调重新 open
      }
    }
  }

  close(): void {
    this.wantReconnect = false;
    if (this.reconnectTimer >= 0) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
    this.streams.clear();
    if (this.ws !== null) {
      try {
        this.ws.close();
      } catch (_) {
      }
      this.ws = null;
    }
  }
}
