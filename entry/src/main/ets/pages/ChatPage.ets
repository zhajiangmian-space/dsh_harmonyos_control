/**
 * 聊天页：查看会话消息、发消息、实时接收。
 */
import { router, promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { AppGlobals } from '../common/AppGlobals';
import { StreamClient, StreamFrame, StreamListener } from '../net/StreamClient';

interface ChatMsg {
  key: string;
  role: string; // user | assistant | system
  text: string;
  images: string[];
  finished: boolean;
  status: string; // ok | sending | failed
}

/** 可选模型（DSH 的 deepseek-account provider） */
interface ModelOption {
  provider: string;
  model: string;
  label: string;
}

const MODEL_OPTIONS: ModelOption[] = [
  { provider: 'deepseek-account', model: 'deepseek-flash', label: 'DeepSeek Flash（默认，快）' },
  { provider: 'deepseek-account', model: 'deepseek-v4-flash', label: 'DeepSeek V4 Flash' },
  { provider: 'deepseek-account', model: 'deepseek-v4.1-flash', label: 'DeepSeek V4.1 Flash' },
  { provider: 'deepseek-account', model: 'deepseek-v4-flash-vision-exp', label: 'V4 Flash Vision（支持图片）' },
  { provider: 'deepseek-account', model: 'deepseek-v4-pro', label: 'DeepSeek V4 Pro（强，不支持图片）' },
];

/** 模型显示名 */
function modelLabel(provider: string, model: string): string {
  for (const opt of MODEL_OPTIONS) {
    if (opt.model === model) {
      return opt.label;
    }
  }
  return model;
}

/** 去掉 Markdown 的加粗/代码标记，保持纯文本干净 */
function stripMarkdown(text: string): string {
  return text
    .replace(/\*\*/g, '')
    .replace(/`{1,3}/g, '');
}

/** base64 图片转 PixelMap（用于显示） */
function base64ToPixelMap(base64: string): image.PixelMap | null {
  try {
    const bytes = new util.Base64Helper().decodeSync(base64);
    const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
    const source = image.createImageSource(buffer);
    if (source === null || source === undefined) {
      return null;
    }
    return source.createPixelMapSync();
  } catch (e) {
    return null;
  }
}

/** 从事件 data 提取图片（base64 列表） */
function extractImages(data: Record<string, Object>): string[] {
  const message = data['message'];
  let content: Object | undefined = data['content'];
  if (message !== undefined && typeof message === 'object') {
    content = (message as Record<string, Object>)['content'];
  }
  const result: string[] = [];
  if (Array.isArray(content)) {
    for (const c of content as object[]) {
      const cr = c as Record<string, Object>;
      if (String(cr['type'] ?? '') === 'image' && typeof cr['data'] === 'string') {
        result.push(cr['data'] as string);
      }
    }
  }
  return result;
}

/** DSH 注入的运行时上下文（时间/时区等），不属于聊天内容，需要过滤 */
function isRuntimeContext(text: string): boolean {
  if (text.includes('Time sampled while preparing turn')) {
    return true;
  }
  if (text.includes('Browser time zone for this request')) {
    return true;
  }
  if (text.includes('Elapsed since the preceding')) {
    return true;
  }
  return false;
}

/** 从事件 data 提取文本：user 用 data.content，assistant 用 data.message.content。
 * 思考内容不展示（与电脑端一致），工具调用显示成简洁的一行。 */
function extractText(data: Record<string, Object>): string {
  const message = data['message'];
  let content: Object | undefined = data['content'];
  if (message !== undefined && typeof message === 'object') {
    content = (message as Record<string, Object>)['content'];
  }
  if (typeof content === 'string') {
    const text = stripMarkdown(content).trim();
    return isRuntimeContext(text) ? '' : text;
  }
  if (Array.isArray(content)) {
    const parts: string[] = [];
    for (const c of content as object[]) {
      const cr = c as Record<string, Object>;
      const ctype = String(cr['type'] ?? '');
      if (ctype === 'text' && typeof cr['text'] === 'string') {
        const piece = stripMarkdown(cr['text'] as string).trim();
        if (piece !== '' && !isRuntimeContext(piece)) {
          parts.push(piece);
        }
      } else if (ctype === 'tool-call') {
        const name = String(cr['name'] ?? '');
        parts.push('\n🔧 ' + name + '\n');
      }
      // image 由 extractImages 单独处理，不拼文本；reasoning 跳过
    }
    return parts.join('').trim();
  }
  return '';
}

/** 从事件 data 拿消息 id */
function messageIdOf(data: Record<string, Object>): string {
  const message = data['message'];
  if (message !== undefined && typeof message === 'object') {
    const mr = message as Record<string, Object>;
    if (typeof mr['id'] === 'string') {
      return mr['id'] as string;
    }
  }
  if (typeof data['id'] === 'string') {
    return data['id'] as string;
  }
  if (typeof data['messageId'] === 'string') {
    return data['messageId'] as string;
  }
  return '';
}

function makeMsg(key: string, role: string, text: string, finished: boolean, images: string[] = [], status: string = 'ok'): ChatMsg {
  const msg: ChatMsg = {
    key: key,
    role: role,
    text: text,
    images: images,
    finished: finished,
    status: status,
  };
  return msg;
}

/** 把一个事件应用到消息数组，返回新数组（不可变） */
function applyToArray(msgs: ChatMsg[], event: Record<string, Object>): ChatMsg[] {
  const type = String(event['type'] ?? '');
  const data = (event['data'] ?? {}) as Record<string, Object>;
  const seq = Number(event['seq'] ?? 0);
  if (type === 'user/message') {
    const text = extractText(data);
    const images = extractImages(data);
    if (text === '' && images.length === 0) {
      return msgs;
    }
    const id = messageIdOf(data);
    const key = 'u-' + (id !== '' ? id : String(seq));
    // 图片消息：本地已有相同首图签名的消息，忽略后端回传（避免重复显示）
    if (images.length > 0) {
      const sig = images[0].substring(0, 80);
      const dup = msgs.findIndex((m: ChatMsg) =>
        m.key.startsWith('u-local-') && m.images.length > 0 && m.images[0].substring(0, 80) === sig);
      if (dup >= 0) {
        return msgs;
      }
    }
    // 文本消息：移除同文本的本地即时消息（发送时本地先显示，避免重复）
    const filtered = msgs.filter((m: ChatMsg) =>
      !(m.key.startsWith('u-local-') && text !== '' && m.text === text));
    if (filtered.findIndex((m: ChatMsg) => m.key === key) >= 0) {
      return filtered;
    }
    return filtered.concat([makeMsg(key, 'user', text, true, images)]);
  }
  if (type === 'assistant/message') {
    const text = extractText(data);
    const images = extractImages(data);
    const msgId = messageIdOf(data);
    if (msgId !== '') {
      const key = 'a-' + msgId;
      const idx = msgs.findIndex((m: ChatMsg) => m.key === key);
      if (idx >= 0) {
        const copy = msgs.slice();
        const updated: ChatMsg = {
          key: key,
          role: 'assistant',
          text: text !== '' ? text : copy[idx].text,
          images: images.length > 0 ? images : copy[idx].images,
          finished: true,
          status: 'ok',
        };
        copy[idx] = updated;
        return copy;
      }
      if (text === '' && images.length === 0) {
        return msgs;
      }
      return msgs.concat([makeMsg(key, 'assistant', text, true, images)]);
    }
    if (text === '' && images.length === 0) {
      return msgs;
    }
    return msgs.concat([makeMsg('a-' + String(seq), 'assistant', text, true, images)]);
  }
  if (type === 'system/message' || type === 'developer/message') {
    const text = extractText(data);
    if (text === '') {
      return msgs;
    }
    return msgs.concat([makeMsg('s-' + String(seq), 'system', text, true)]);
  }
  if (type === 'turn/end') {
    return msgs.map((m: ChatMsg) => m.finished ? m : makeMsg(m.key, m.role, m.text, true, m.images, m.status));
  }
  return msgs;
}

@Entry
@Component
struct ChatPage {
  @State messages: ChatMsg[] = [];
  @State streamingMsg: ChatMsg | null = null;
  @State inputText: string = '';
  @State sending: boolean = false;
  @State streaming: boolean = false;
  @State title: string = '会话';
  @State showFullscreen: boolean = false;
  @State fullscreenImages: string[] = [];
  @State fullscreenIndex: number = 0;
  @State pendingImages: string[] = [];
  @State currentModel: string = '';
  @State currentProvider: string = 'deepseek-account';
  @State cursorSeq: number = 0;
  @State firstLoadedSeq: number = -1;
  @State hasMoreHistory: boolean = false;
  @State loadingHistory: boolean = false;
  private sessionId: string = '';
  private streamId: string = '';
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, Object>;
    if (params) {
      if (params['sessionId'] !== undefined) {
        this.sessionId = String(params['sessionId']);
      }
      if (params['title'] !== undefined) {
        this.title = String(params['title']);
      }
    }
    this.startFollow();
    this.loadCurrentModel();
  }

  /** 读取当前会话的模型 */
  async loadCurrentModel(): Promise<void> {
    const g = AppGlobals.get();
    if (!g.configured) {
      return;
    }
    try {
      const list = await g.api.sessionList();
      for (const s of list) {
        if (s.sessionId === this.sessionId) {
          const sel = s.modelSelection;
          if (sel !== null) {
            this.currentModel = sel.model;
            this.currentProvider = sel.provider;
          }
          break;
        }
      }
    } catch (e) {
      // 拿不到不影响聊天
    }
  }

  /** 弹出模型选择 */
  showModelPicker(): void {
    const items: promptAction.Button[] = [];
    for (let i = 0; i < MODEL_OPTIONS.length; i++) {
      const opt = MODEL_OPTIONS[i];
      const prefix = opt.model === this.currentModel ? '✓ ' : '';
      items.push({ text: prefix + opt.label, color: '#1d1d1f' });
    }
    promptAction.showDialog({
      title: '选择模型',
      buttons: items,
    }).then((result: promptAction.ShowDialogSuccessResponse) => {
      this.applyModel(result.index);
    }).catch(() => {
    });
  }

  /** 模型名简称（顶栏显示用） */
  shortenModel(model: string): string {
    if (model === 'deepseek-flash') {
      return 'Flash';
    }
    if (model === 'deepseek-v4-flash') {
      return 'V4 Flash';
    }
    if (model === 'deepseek-v4.1-flash') {
      return 'V4.1 Flash';
    }
    if (model === 'deepseek-v4-flash-vision-exp') {
      return 'V4 Vision';
    }
    if (model === 'deepseek-v4-pro') {
      return 'V4 Pro';
    }
    return model;
  }

  /** 应用选中的模型 */
  async applyModel(index: number): Promise<void> {
    if (index < 0 || index >= MODEL_OPTIONS.length) {
      return;
    }
    const opt = MODEL_OPTIONS[index];
    const g = AppGlobals.get();
    try {
      await g.api.selectModel(this.sessionId, opt.provider, opt.model, 'high');
      this.currentModel = opt.model;
      this.currentProvider = opt.provider;
      promptAction.showToast({ message: '已切换到 ' + opt.label });
      // 模型变化后重新读取确认
      await this.loadCurrentModel();
    } catch (e) {
      promptAction.showToast({ message: '切换失败：' + (e as Error).message });
    }
  }

  async startFollow(): Promise<void> {
    const g = AppGlobals.get();
    if (!g.configured) {
      promptAction.showToast({ message: '请先完成设置' });
      return;
    }
    try {
      await g.ensureStream(() => {
      });
      const listener: StreamListener = {
        onFrame: (frame: StreamFrame) => {
          this.handleFrame(frame);
        },
        onError: (message: string) => {
          promptAction.showToast({ message: message });
        },
      };
      const address: Record<string, Object> = {
        'kind': 'session',
        'sessionId': this.sessionId,
      };
      const request: Record<string, Object> = {
        'address': address,
        'assistantStream': true,
        // 限制历史消息条数，控制快照大小
        'maxMessages': 5,
      };
      const args: Record<string, Object> = { 'request': request };
      const payload: Record<string, Object> = { 'args': args };
      this.streamId = g.stream.openStream('session/follow', payload, listener);
    } catch (e) {
      promptAction.showToast({ message: '连接失败：' + (e as Error).message });
    }
  }

  handleFrame(frame: StreamFrame): void {
    if (frame.type === 'item' && frame.value !== undefined) {
      const v = frame.value as Record<string, Object>;
      const itemType = String(v['type'] ?? '');
      if (itemType === 'snapshot') {
        this.handleSnapshot(v);
        return;
      }
      if (itemType === 'assistant-stream') {
        this.streaming = true;
        this.handleAssistantStream(v);
        return;
      }
      if (itemType === 'event') {
        const event = v['event'] as Record<string, Object> | undefined;
        if (event) {
          const etype = String(event['type'] ?? '');
          if (etype === 'turn/end' || etype === 'assistant/message') {
            this.streaming = false;
          }
          if (etype === 'assistant/message' || etype === 'turn/end') {
            // 完整消息或回合结束：清掉流式缓冲
            this.streamingMsg = null;
          }
          this.messages = applyToArray(this.messages, event);
          this.scrollBottom();
        }
        return;
      }
      return;
    }
    if (frame.type === 'end') {
      this.streaming = false;
    } else if (frame.type === 'error' && frame.error) {
      promptAction.showToast({ message: '流错误：' + frame.error.message });
    }
  }

  /** 处理 assistant-stream 帧（打字机效果） */
  handleAssistantStream(v: Record<string, Object>): void {
    const f = v['frame'] as Record<string, Object>;
    const ftype = String(f['type'] ?? '');
    if (ftype === 'start') {
      this.streamingMsg = null;
      return;
    }
    if (ftype === 'chunk') {
      const c = f['chunk'] as Record<string, Object>;
      const ctype = String(c['type'] ?? '');
      if (ctype === 'text-delta' && typeof c['text'] === 'string') {
        const delta = c['text'] as string;
        const cur = this.streamingMsg;
        if (cur === null) {
          const msg: ChatMsg = {
            key: 'streaming',
            role: 'assistant',
            text: delta,
            finished: false,
            images: [],
            status: 'ok',
          };
          this.streamingMsg = msg;
        } else {
          const updated: ChatMsg = {
            key: cur.key,
            role: cur.role,
            text: cur.text + delta,
            finished: false,
            images: cur.images,
            status: 'ok',
          };
          this.streamingMsg = updated;
        }
        this.scrollBottom();
      }
    }
  }

  handleSnapshot(v: Record<string, Object>): void {
    const records = v['records'] as object[] | undefined;
    if (!records) {
      return;
    }
    let msgs: ChatMsg[] = [];
    let firstSeq = -1;
    for (const rec of records) {
      const r = rec as Record<string, Object>;
      const event = r['event'] as Record<string, Object> | undefined;
      if (!event) {
        continue;
      }
      const seq = Number(event['seq'] ?? 0);
      if (firstSeq < 0 || seq < firstSeq) {
        firstSeq = seq;
      }
      msgs = applyToArray(msgs, event);
    }
    // 记录游标，供加载更多历史使用
    const cursor = v['cursor'] as Record<string, Object> | undefined;
    if (cursor !== undefined && cursor !== null) {
      this.cursorSeq = Number(cursor['seq'] ?? 0);
    }
    this.firstLoadedSeq = firstSeq;
    this.hasMoreHistory = v['hasMore'] === true;
    this.messages = msgs;
    this.scrollBottom();
  }

  /** 加载更早的历史消息（向前翻页） */
  async loadMoreHistory(): Promise<void> {
    if (this.loadingHistory || this.cursorSeq <= 0 || this.firstLoadedSeq <= 0) {
      return;
    }
    const g = AppGlobals.get();
    this.loadingHistory = true;
    try {
      const value = await g.api.sessionPage(this.sessionId, this.cursorSeq, this.firstLoadedSeq, 20) as Record<string, Object>;
      const records = value['records'] as object[] | undefined;
      if (!records || records.length === 0) {
        this.hasMoreHistory = false;
        return;
      }
      // 把更早的事件合并到现有消息前面
      let msgs: ChatMsg[] = [];
      let firstSeq = this.firstLoadedSeq;
      for (const rec of records) {
        const r = rec as Record<string, Object>;
        const event = r['event'] as Record<string, Object> | undefined;
        if (!event) {
          continue;
        }
        const seq = Number(event['seq'] ?? 0);
        if (seq < firstSeq) {
          firstSeq = seq;
        }
        msgs = applyToArray(msgs, event);
      }
      // 现有消息（排除与历史重复的）
      for (const m of this.messages) {
        if (msgs.findIndex((h: ChatMsg) => h.key === m.key) < 0) {
          msgs.push(m);
        }
      }
      this.messages = msgs;
      this.firstLoadedSeq = firstSeq;
      this.hasMoreHistory = records.length >= 20;
      promptAction.showToast({ message: '已加载更早消息' });
    } catch (e) {
      promptAction.showToast({ message: '加载历史失败：' + (e as Error).message });
    } finally {
      this.loadingHistory = false;
    }
  }

  scrollBottom(): void {
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 80);
  }

  async send(): Promise<void> {
    const text = this.inputText.trim();
    if (text === '' || this.sending) {
      return;
    }
    const g = AppGlobals.get();
    this.sending = true;
    this.inputText = '';
    // 本地立即显示用户气泡（不等后端回传）
    const localKey = 'u-local-' + Date.now().toString();
    this.messages = this.messages.concat([makeMsg(localKey, 'user', text, true)]);
    this.scrollBottom();
    try {
      await g.api.sessionPrompt(this.sessionId, text);
    } catch (e) {
      promptAction.showToast({ message: '发送失败：' + (e as Error).message });
      this.inputText = text;
    } finally {
      this.sending = false;
    }
  }

  /** 选择图片（多选）：只放入待发送区，等用户点发送再一起发 */
  async pickImages(): Promise<void> {
    if (this.sending) {
      return;
    }
    try {
      const picker = new photoAccessHelper.PhotoViewPicker();
      const result = await picker.select({
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 9,
      });
      if (result.photoUris.length === 0) {
        return;
      }
      const picked: string[] = [];
      for (const uri of result.photoUris) {
        const packed = await this.compressImage(uri);
        if (packed.length > 0) {
          picked.push(packed);
        }
      }
      if (picked.length === 0) {
        promptAction.showToast({ message: '读取图片失败' });
        return;
      }
      this.pendingImages = this.pendingImages.concat(picked);
      this.scrollBottom();
    } catch (e) {
      promptAction.showToast({ message: '选择图片失败：' + (e as Error).message });
    }
  }

  /** 移除待发送图片 */
  removePendingImage(index: number): void {
    const next: string[] = [];
    for (let i = 0; i < this.pendingImages.length; i++) {
      if (i !== index) {
        next.push(this.pendingImages[i]);
      }
    }
    this.pendingImages = next;
  }

  /** 发送：文字和待发图片一起（一条消息）；失败保留消息供重发 */
  async sendMessage(): Promise<void> {
    const text = this.inputText.trim();
    if ((text === '' && this.pendingImages.length === 0) || this.sending) {
      return;
    }
    const images = this.pendingImages.slice();
    this.sending = true;
    this.inputText = '';
    this.pendingImages = [];
    // 本地立即显示（发送中状态）
    const localKey = 'u-local-' + Date.now().toString();
    this.messages = this.messages.concat([makeMsg(localKey, 'user', text, true, images, 'sending')]);
    this.scrollBottom();
    const ok = await this.deliver(localKey, text, images);
    this.sending = false;
    if (!ok) {
      // 失败：消息保留为失败态，可重发或删除
      promptAction.showToast({ message: '发送失败，可点消息上的「重发」' });
    }
  }

  /** 实际投递；成功返回 true */
  async deliver(localKey: string, text: string, images: string[]): Promise<boolean> {
    const g = AppGlobals.get();
    try {
      if (images.length > 0) {
        const types: string[] = [];
        for (let i = 0; i < images.length; i++) {
          types.push('image/jpeg');
        }
        await g.api.sessionPromptMixed(this.sessionId, text, images, types);
      } else {
        await g.api.sessionPrompt(this.sessionId, text);
      }
      this.setStatus(localKey, 'ok');
      return true;
    } catch (e) {
      const msg = (e as Error).message ?? String(e);
      if (msg.includes('does not support image input')) {
        promptAction.showToast({ message: '当前模型不支持图片，切换模型后可重发' });
      } else if (msg.includes('per-side pixel limit')) {
        promptAction.showToast({ message: '图片尺寸过大，请减少张数或换小图' });
      } else {
        promptAction.showToast({ message: '发送失败：' + msg });
      }
      this.setStatus(localKey, 'failed');
      return false;
    }
  }

  /** 更新某条消息的状态 */
  setStatus(key: string, status: string): void {
    const next: ChatMsg[] = [];
    for (const m of this.messages) {
      if (m.key === key) {
        next.push(makeMsg(m.key, m.role, m.text, m.finished, m.images, status));
      } else {
        next.push(m);
      }
    }
    this.messages = next;
  }

  /** 重发失败的消息 */
  async resendMessage(m: ChatMsg): Promise<void> {
    if (this.sending) {
      return;
    }
    this.sending = true;
    this.setStatus(m.key, 'sending');
    const ok = await this.deliver(m.key, m.text, m.images);
    this.sending = false;
    if (ok) {
      promptAction.showToast({ message: '已重发' });
    }
  }

  /** 删除失败的消息 */
  removeMessage(m: ChatMsg): void {
    const next: ChatMsg[] = [];
    for (const item of this.messages) {
      if (item.key !== m.key) {
        next.push(item);
      }
    }
    this.messages = next;
    promptAction.showToast({ message: '已删除' });
  }

  /** 读取图片、按最长边 1800 缩放并压缩成 JPEG base64 */
  async compressImage(uri: string): Promise<string> {
    let file: fs.File | null = null;
    try {
      file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const source = image.createImageSource(file.fd);
      const info = await source.getImageInfo();
      let width = info.size.width;
      let height = info.size.height;
      const maxSide = 1200;
      const longSide = Math.max(width, height);
      if (longSide > maxSide) {
        const scale = maxSide / longSide;
        width = Math.max(1, Math.floor(width * scale));
        height = Math.max(1, Math.floor(height * scale));
      }
      const size: image.Size = { width: width, height: height };
      const opts: image.InitializationOptions = {
        size: size,
      };
      const pixelMap = await source.createPixelMap(opts);
      const packer = image.createImagePacker();
      const packOpts: image.PackingOption = {
        format: 'image/jpeg',
        quality: 88,
      };
      const buf = await packer.packToData(pixelMap, packOpts);
      pixelMap.release();
      return new util.Base64Helper().encodeToStringSync(new Uint8Array(buf));
    } catch (e) {
      return '';
    } finally {
      if (file !== null) {
        fs.closeSync(file);
      }
    }
  }

  /** 打开全屏预览 */
  openFullscreen(images: string[], index: number): void {
    this.fullscreenImages = images;
    this.fullscreenIndex = index;
    this.showFullscreen = true;
  }

  /** 根据 URI 猜测图片类型 */
  guessMediaType(uri: string): string {
    const lower = uri.toLowerCase();
    if (lower.endsWith('.png')) {
      return 'image/png';
    }
    if (lower.endsWith('.webp')) {
      return 'image/webp';
    }
    if (lower.endsWith('.gif')) {
      return 'image/gif';
    }
    return 'image/jpeg';
  }

  /** 复制消息文本到剪贴板 */
  copyMessage(text: string): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      const board = pasteboard.getSystemPasteboard();
      board.setData(data);
      promptAction.showToast({ message: '已复制' });
    } catch (e) {
      promptAction.showToast({ message: '复制失败' });
    }
  }

  aboutToDisappear(): void {
    const g = AppGlobals.get();
    if (this.streamId !== '') {
      g.stream.closeStream(this.streamId);
      this.streamId = '';
    }
    g.stream.close();
  }

  build() {
    Column() {
      // 顶栏
      Row({ space: 8 }) {
        Button('‹')
          .fontSize(26)
          .width(40)
          .height(40)
          .fontColor('#1d1d1f')
          .backgroundColor('#00000000')
          .onClick(() => {
            router.back();
          })
        Text(this.title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#1d1d1f')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ left: 16, right: 16, top: 7, bottom: 7 })
          .backgroundColor('#f0efec')
          .borderRadius(19)
        // 模型选择按钮（显示当前模型简称）
        Text(this.currentModel !== '' ? this.shortenModel(this.currentModel) : '模型')
          .fontSize(12)
          .fontColor('#8e8e93')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 92 })
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .backgroundColor('#f0efec')
          .borderRadius(12)
          .onClick(() => {
            this.showModelPicker();
          })
        if (this.streaming) {
          Row({ space: 4 }) {
            Circle({ width: 8, height: 8 })
              .fill('#00a650')
            Text('运行中')
              .fontSize(12)
              .fontColor('#00a650')
          }
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 8 })

      // 消息列表
      List({ space: 14, scroller: this.scroller }) {
        // 顶部：加载更多历史
        if (this.hasMoreHistory || this.firstLoadedSeq > 0) {
          ListItem() {
            Row() {
              Blank()
              Text(this.loadingHistory ? '加载中…' : '加载更早的消息')
                .fontSize(12)
                .fontColor('#8e8e93')
                .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                .backgroundColor('#f0efec')
                .borderRadius(14)
                .onClick(() => {
                  this.loadMoreHistory();
                })
              Blank()
            }
            .width('100%')
            .padding({ top: 4, bottom: 4 })
          }
        }
        ForEach(this.messages, (m: ChatMsg) => {
          ListItem() {
            Row() {
              if (m.role === 'user') {
                Blank()
              }
              Column({ space: 6 }) {
                // 图片：多张横向排列，点开全屏滑动浏览
                if (m.images.length > 0) {
                  Scroll() {
                    Row({ space: 6 }) {
                      ForEach(m.images, (b64: string, idx: number) => {
                        Image(base64ToPixelMap(b64))
                          .width(120)
                          .height(120)
                          .objectFit(ImageFit.Cover)
                          .borderRadius(12)
                          .onClick(() => {
                            this.openFullscreen(m.images, idx);
                          })
                      }, (b64: string, idx: number) => m.key + '-' + idx.toString())
                    }
                  }
                  .scrollable(ScrollDirection.Horizontal)
                  .scrollBar(BarState.Off)
                  .constraintSize({ maxWidth: '100%' })
                }
                if (m.text !== '') {
                  Text(m.text)
                    .fontSize(16)
                    .lineHeight(25)
                    .fontColor('#1d1d1f')
                    .padding(m.role === 'user'
                      ? { left: 14, right: 14, top: 9, bottom: 9 }
                      : { left: 0, right: 0, top: 2, bottom: 2 })
                    .backgroundColor(m.role === 'user' ? '#f0efec' : '#00000000')
                    .borderRadius(16)
                    .constraintSize({ maxWidth: m.role === 'user' ? '84%' : '100%' })
                }
                if (!m.finished) {
                  Text('▍')
                    .fontSize(14)
                    .fontColor('#b0b0b0')
                }
                // 发送失败：显示重发/删除
                if (m.status === 'failed') {
                  Row({ space: 12 }) {
                    Text('重发')
                      .fontSize(12)
                      .fontColor('#e0342a')
                      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                      .backgroundColor('#fdecea')
                      .borderRadius(10)
                      .onClick(() => {
                        this.resendMessage(m);
                      })
                    Text('删除')
                      .fontSize(12)
                      .fontColor('#8e8e93')
                      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                      .backgroundColor('#f0efec')
                      .borderRadius(10)
                      .onClick(() => {
                        this.removeMessage(m);
                      })
                  }
                } else if (m.status === 'sending') {
                  Text('发送中…')
                    .fontSize(11)
                    .fontColor('#b0b0b0')
                }
              }
              .alignItems(m.role === 'user' ? HorizontalAlign.End : HorizontalAlign.Start)
              if (m.role !== 'user') {
                Blank()
              }
            }
            .width('100%')
          }
        }, (m: ChatMsg) => m.key)

        // 流式消息（打字机效果）
        if (this.streamingMsg !== null) {
          ListItem() {
            Row() {
              Column({ space: 2 }) {
                Text(this.streamingMsg !== null ? this.streamingMsg.text : '')
                  .fontSize(16)
                  .lineHeight(25)
                  .fontColor('#1d1d1f')
                  .padding({ left: 0, right: 0, top: 2, bottom: 2 })
                  .constraintSize({ maxWidth: '100%' })
                Text('▍')
                  .fontSize(14)
                  .fontColor('#b0b0b0')
              }
              Blank()
            }
            .width('100%')
          }
        }
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 16 })
      .scrollBar(BarState.Off)

      // 待发送图片区（悬浮在输入框上方）
      if (this.pendingImages.length > 0) {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.pendingImages, (b64: string, idx: number) => {
              Stack({ alignContent: Alignment.TopEnd }) {
                Image(base64ToPixelMap(b64))
                  .width(64)
                  .height(64)
                  .objectFit(ImageFit.Cover)
                  .borderRadius(10)
                Text('✕')
                  .fontSize(11)
                  .fontColor('#ffffff')
                  .width(18)
                  .height(18)
                  .textAlign(TextAlign.Center)
                  .backgroundColor('#99000000')
                  .borderRadius(9)
                  .onClick(() => {
                    this.removePendingImage(idx);
                  })
              }
            }, (b64: string, idx: number) => 'pending-' + idx.toString() + '-' + b64.length.toString())
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .padding({ left: 14, right: 14, top: 8, bottom: 2 })
      }

      // 输入栏
      Row({ space: 10 }) {
        Button('＋')
          .fontSize(20)
          .width(42)
          .height(42)
          .borderRadius(21)
          .fontColor('#8e8e93')
          .backgroundColor('#ebe9e4')
          .onClick(() => {
            this.pickImages();
          })
        TextArea({ text: this.inputText, placeholder: '给 DSH 发消息…' })
          .fontSize(15)
          .height(44)
          .layoutWeight(1)
          .backgroundColor('#ffffff')
          .borderRadius(22)
          .padding({ left: 16, right: 16 })
          .onChange((v: string) => {
            this.inputText = v;
          })
        Button(this.sending ? '…' : '↑')
          .fontSize(20)
          .width(44)
          .height(44)
          .borderRadius(22)
          .backgroundColor(this.sending ? '#c7c7c7' : '#1d1d1f')
          .fontColor('#ffffff')
          .enabled(!this.sending)
          .onClick(() => {
            this.sendMessage();
          })
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 8, bottom: 14 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#faf9f6')
    .bindContentCover($$this.showFullscreen, this.FullscreenView(), {
      modalTransition: ModalTransition.DEFAULT,
    })
  }

  /** 全屏图片浏览（左右滑动切换） */
  @Builder
  FullscreenView() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Swiper() {
        ForEach(this.fullscreenImages, (b64: string, idx: number) => {
          Image(base64ToPixelMap(b64))
            .objectFit(ImageFit.Contain)
            .width('100%')
            .height('100%')
        }, (b64: string, idx: number) => 'fs-' + idx.toString() + '-' + b64.length.toString())
      }
      .index(this.fullscreenIndex)
      .indicator(false)
      .loop(false)
      .width('100%')
      .height('100%')
      .onChange((index: number) => {
        this.fullscreenIndex = index;
      })

      // 关闭按钮
      Button('✕')
        .fontSize(18)
        .fontColor('#ffffff')
        .width(40)
        .height(40)
        .borderRadius(20)
        .backgroundColor('#33ffffff')
        .margin({ top: 48, right: 16 })
        .onClick(() => {
          this.showFullscreen = false;
        })

      // 页码
      if (this.fullscreenImages.length > 1) {
        Text(String(this.fullscreenIndex + 1) + ' / ' + String(this.fullscreenImages.length))
          .fontSize(13)
          .fontColor('#cccccc')
          .margin({ top: 58, right: 68 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
  }
}
