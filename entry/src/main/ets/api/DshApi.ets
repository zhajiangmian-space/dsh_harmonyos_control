/**
 * DSH 业务 API 封装（基于 DSH NEXT 的 Typert gateway 契约）。
 * 所有方法的参数都包在 request 字段里（session/list 例外，用 _request）。
 * 注意：ArkTS 要求每个对象字面量都有显式类型，因此各请求对象分步声明。
 */
import { RpcClient } from '../net/RpcClient';
import { SessionSummary, GoalInfo, TokenUsage, ModelSelection } from '../model/Types';

export class DshApi {
  private rpc: RpcClient;

  constructor(rpc: RpcClient) {
    this.rpc = rpc;
  }

  /** 会话列表（含 projections：标题、goal、token 用量等） */
  async sessionList(): Promise<SessionSummary[]> {
    const emptyRequest: Record<string, Object> = {};
    const args: Record<string, Object> = { '_request': emptyRequest };
    const value = await this.rpc.invoke('session/list', args) as Record<string, Object>;
    const items = value['items'] as Record<string, Object>[] | undefined;
    const result: SessionSummary[] = [];
    if (items) {
      for (const it of items) {
        const s = new SessionSummary();
        s.sessionId = String(it['sessionId'] ?? '');
        s.updatedAt = Number(it['updatedAt'] ?? 0);
        s.running = Boolean(it['running']);
        s.blank = Boolean(it['blank']);
        s.agentAvailable = Boolean(it['agentAvailable']);
        if (it['parentSessionId'] !== undefined && it['parentSessionId'] !== null) {
          s.parentSessionId = String(it['parentSessionId']);
        }
        if (it['origin'] !== undefined && it['origin'] !== null) {
          s.origin = String(it['origin']);
        }
        if (it['cwd'] !== undefined && it['cwd'] !== null) {
          s.cwd = String(it['cwd']);
        }
        const projections = it['projections'] as Record<string, Object> | undefined;
        if (projections) {
          const values = projections['values'] as Record<string, Object> | undefined;
          if (values) {
            if (values['title'] !== undefined && values['title'] !== null) {
              s.title = String(values['title']);
            }
            if (values['goal'] !== undefined && values['goal'] !== null) {
              const g = values['goal'] as Record<string, Object>;
              const goalInfo: GoalInfo = new GoalInfo();
              goalInfo.id = String(g['id'] ?? '');
              goalInfo.revision = Number(g['revision'] ?? 0);
              goalInfo.objective = String(g['objective'] ?? '');
              goalInfo.status = String(g['status'] ?? '');
              s.goal = goalInfo;
            } else {
              s.goal = null;
            }
            const usage = values['tokenUsage'] as Record<string, Object> | undefined;
            if (usage) {
              const tokenUsage: TokenUsage = new TokenUsage();
              tokenUsage.uncachedInputTokens = Number(usage['uncachedInputTokens'] ?? 0);
              tokenUsage.outputTokens = Number(usage['outputTokens'] ?? 0);
              tokenUsage.cacheReadTokens = Number(usage['cacheReadTokens'] ?? 0);
              tokenUsage.cacheWriteTokens = Number(usage['cacheWriteTokens'] ?? 0);
              s.tokenUsage = tokenUsage;
            } else {
              s.tokenUsage = null;
            }
            // 当前模型（next 优先，其次 lastUsed；两者可能为 null）
            const sel = values['modelSelection'] as Record<string, Object> | null | undefined;
            let cur: Record<string, Object> | null = null;
            if (sel !== undefined && sel !== null) {
              const next = sel['next'] as Record<string, Object> | null | undefined;
              const lastUsed = sel['lastUsed'] as Record<string, Object> | null | undefined;
              if (next !== undefined && next !== null) {
                cur = next;
              } else if (lastUsed !== undefined && lastUsed !== null) {
                cur = lastUsed;
              }
            }
            if (cur !== null) {
              const ms: ModelSelection = new ModelSelection();
              ms.provider = String(cur['provider'] ?? '');
              ms.model = String(cur['model'] ?? '');
              ms.reasoningEffort = String(cur['reasoningEffort'] ?? '');
              s.modelSelection = ms;
            } else {
              s.modelSelection = null;
            }
          }
        }
        result.push(s);
      }
    }
    return result;
  }

  /** 创建会话 */
  async sessionCreate(workspaceId?: string, cwd?: string, sessionId?: string, agentPreset?: string): Promise<string> {
    const request: Record<string, Object> = {};
    if (workspaceId) {
      request['workspaceId'] = workspaceId;
    }
    if (cwd) {
      request['cwd'] = cwd;
    }
    if (sessionId) {
      request['sessionId'] = sessionId;
    }
    if (agentPreset) {
      request['agentPreset'] = agentPreset;
    }
    const args: Record<string, Object> = { 'request': request };
    const value = await this.rpc.invoke('session/create', args) as Record<string, Object>;
    return String(value['sessionId'] ?? '');
  }

  /** 发送一条文本消息 */
  async sessionPrompt(sessionId: string, text: string): Promise<void> {
    const requestId = sessionId + '-' + Date.now().toString();
    const contentItem: Record<string, Object> = { 'type': 'text', 'text': text };
    const content: Record<string, Object>[] = [contentItem];
    const request: Record<string, Object> = {
      'requestId': requestId,
      'sessionId': sessionId,
      'mode': 'queue',
      'content': content,
    };
    const args: Record<string, Object> = { 'request': request };
    await this.rpc.invoke('session/prompt', args);
  }

  /** 发送一张图片（base64） */
  async sessionPromptImage(sessionId: string, base64: string, mediaType: string, name: string): Promise<void> {
    await this.sessionPromptImages(sessionId, [base64], [mediaType]);
  }

  /** 一次性发送多张图片（同一条消息） */
  async sessionPromptImages(sessionId: string, bases: string[], mediaTypes: string[]): Promise<void> {
    await this.sessionPromptMixed(sessionId, '', bases, mediaTypes);
  }

  /** 切换会话模型 */
  async selectModel(sessionId: string, provider: string, model: string, reasoningEffort: string): Promise<void> {
    const request: Record<string, Object> = {
      'sessionId': sessionId,
      'provider': provider,
      'model': model,
    };
    if (reasoningEffort !== '') {
      request['reasoningEffort'] = reasoningEffort;
    }
    const args: Record<string, Object> = { 'request': request };
    await this.rpc.invoke('session/selectModel', args);
  }

  /** 一次性发送文字 + 多张图片（同一条消息） */
  async sessionPromptMixed(sessionId: string, text: string, bases: string[], mediaTypes: string[]): Promise<void> {
    const requestId = sessionId + '-' + Date.now().toString();
    const content: Record<string, Object>[] = [];
    if (text !== '') {
      const textItem: Record<string, Object> = { 'type': 'text', 'text': text };
      content.push(textItem);
    }
    for (let i = 0; i < bases.length; i++) {
      const mediaType = i < mediaTypes.length ? mediaTypes[i] : 'image/jpeg';
      const imageItem: Record<string, Object> = {
        'type': 'image',
        'mediaType': mediaType,
        'data': bases[i],
        'name': 'image',
      };
      content.push(imageItem);
    }
    const request: Record<string, Object> = {
      'requestId': requestId,
      'sessionId': sessionId,
      'mode': 'queue',
      'content': content,
    };
    const args: Record<string, Object> = { 'request': request };
    await this.rpc.invoke('session/prompt', args);
  }

  /** 取消当前进行中的回合 */
  async sessionCancel(sessionId: string): Promise<void> {
    const request: Record<string, Object> = { 'sessionId': sessionId };
    const args: Record<string, Object> = { 'request': request };
    await this.rpc.invoke('session/cancel', args);
  }

  /** 重命名会话 */
  async sessionRename(sessionId: string, title: string): Promise<void> {
    const request: Record<string, Object> = { 'sessionId': sessionId, 'title': title };
    const args: Record<string, Object> = { 'request': request };
    await this.rpc.invoke('session/rename', args);
  }

  /** 归档（隐藏）会话 */
  async sessionArchive(sessionId: string): Promise<void> {
    const request: Record<string, Object> = { 'sessionId': sessionId };
    const args: Record<string, Object> = { 'request': request };
    await this.rpc.invoke('workspace/archiveSession', args);
  }

  /** 取消归档（恢复到列表） */
  async sessionUnarchive(sessionId: string): Promise<void> {
    const request: Record<string, Object> = { 'sessionId': sessionId };
    const args: Record<string, Object> = { 'request': request };
    await this.rpc.invoke('workspace/unarchiveSession', args);
  }

  /**
   * 读一页会话历史。
   * address: {kind:'session', sessionId}
   * throughSeq 从 follow 流的 opening 帧获取。
   */
  async sessionPage(sessionId: string, throughSeq: number, beforeSeq?: number, maxMessages?: number): Promise<object> {
    const address: Record<string, Object> = { 'kind': 'session', 'sessionId': sessionId };
    const request: Record<string, Object> = {
      'address': address,
      'throughSeq': throughSeq,
    };
    if (beforeSeq !== undefined) {
      request['beforeSeq'] = beforeSeq;
    }
    if (maxMessages !== undefined) {
      request['maxMessages'] = maxMessages;
    }
    const args: Record<string, Object> = { 'request': request };
    return await this.rpc.invoke('session/page', args);
  }

  /** 后台任务列表 */
  async jobList(): Promise<object[]> {
    const emptyRequest: Record<string, Object> = {};
    const args: Record<string, Object> = { 'request': emptyRequest };
    const value = await this.rpc.invoke('job/list', args) as Record<string, Object>;
    return (value['items'] ?? []) as object[];
  }

  /** 测试连接 */
  async testConnection(): Promise<string> {
    return await this.rpc.testConnection();
  }
}
