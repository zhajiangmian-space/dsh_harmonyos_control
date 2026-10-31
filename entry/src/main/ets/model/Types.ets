/**
 * DSH NEXT 远程控制 App 的数据模型
 */

/** 目标信息（会话的长期目标） */
export class GoalInfo {
  id: string = '';
  revision: number = 0;
  objective: string = '';
  status: string = '';
}

/** token 用量 */
export class TokenUsage {
  uncachedInputTokens: number = 0;
  outputTokens: number = 0;
  cacheReadTokens: number = 0;
  cacheWriteTokens: number = 0;
}

/** 模型选择 */
export class ModelSelection {
  provider: string = '';
  model: string = '';
  reasoningEffort: string = '';
}

/** 会话列表项（session/list 的返回） */
export class SessionSummary {
  sessionId: string = '';
  updatedAt: number = 0;
  running: boolean = false;
  blank: boolean = false;
  agentAvailable: boolean = false;
  parentSessionId: string = '';
  origin: string = '';
  cwd: string = '';
  title: string = '';
  goal: GoalInfo | null = null;
  tokenUsage: TokenUsage | null = null;
  modelSelection: ModelSelection | null = null;
}

/** 工作区（项目）信息，来自 workspace/follow 的 baseline */
export class WorkspaceInfo {
  workspaceId: string = '';
  path: string = '';
  title: string = '';
  sessionIds: string[] = [];
}

/** 工作区快照（workspace/follow 第一帧） */
export class WorkspaceSnapshot {
  items: WorkspaceInfo[] = [];
  archivedSessionIds: string[] = [];
  pinnedSessionIds: string[] = [];
}
