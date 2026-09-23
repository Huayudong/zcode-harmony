import router from '@ohos.router';
import {
  PairingSession,
  PinnedHttpClient,
  PinnedHttpError,
  PinnedHttpTarget,
  ProfileStore,
  caFilePathIn,
  ensureCaFileWritten,
  fetchServerInfo,
  probeWsHandshake,
  pullSessionsSnapshot,
  SessionsPullError
} from 'connection';
import type { WorkspaceTarget } from 'protocol';
import { LightBloomButton, ZcodeColors, StatusDot, StatusTone } from 'uikit';

type CheckStatus = 'pending' | 'running' | 'pass' | 'fail';

interface CheckStep {
  title: string;
  status: CheckStatus;
  message: string;
}

const STEP_INDEX_HTTPS: number = 0;
const STEP_INDEX_WSS: number = 1;
const STEP_INDEX_SESSION: number = 2;

/**
 * 连接自检页（ONB-5）：HTTPS+token → WSS 握手 → 会话列表拉取，逐项点亮。
 * ①②为真实探测；③为真实 v4 会话订阅（批次6：L3/L4 接入，拉取 sessions-index snapshot）。
 */
@Entry
@Component
struct PairingSelfCheck {
  @State steps: CheckStep[] = [
    { title: 'HTTPS 连通性与凭证', status: 'pending', message: '等待开始' } as CheckStep,
    { title: '安全通道（WSS 握手）', status: 'pending', message: '等待开始' } as CheckStep,
    { title: '会话列表拉取', status: 'pending', message: '等待开始' } as CheckStep,
  ];
  @State serverName: string = '';
  @State busy: boolean = false;
  private session: PairingSession | null = null;

  aboutToAppear(): void {
    const params = router.getParams() as PairingSession | null;
    if (params !== null && params.host.length > 0) {
      this.session = params;
      this.serverName = params.serverName.length > 0 ? params.serverName : `${params.host}:${params.port}`;
      this.runAllChecks();
    } else {
      // 无会话参数（直接打开本页）：提示回配对页。
      this.steps[STEP_INDEX_HTTPS] = {
        title: 'HTTPS 连通性与凭证', status: 'fail', message: '缺少配对参数，请从配对页进入'
      } as CheckStep;
    }
  }

  private setStep(index: number, status: CheckStatus, message: string): void {
    const updated: CheckStep = {
      title: this.steps[index].title,
      status: status,
      message: message,
    };
    this.steps[index] = updated;
  }

  private adviceFor(error: PinnedHttpError): string {
    switch (error.kind) {
      case 'ConnectFailed':
        return '连不上电脑：检查手机与电脑是否同一网络；电脑端 ZCode 是否在运行';
      case 'HandshakeFailed':
        return '安全校验未通过：请重新配对（可能有人拦截网络）';
      case 'Timeout':
        return '网络超时：检查 Wi-Fi 与防火墙是否放行端口';
      case 'HttpStatus':
        if (error.statusCode === 401) {
          return '设备凭证无效：请重新配对';
        }
        return `服务返回错误（HTTP ${error.statusCode ?? 0}）`;
      default:
        return error.message;
    }
  }

  private async runAllChecks(): Promise<void> {
    if (this.busy || this.session === null) {
      return;
    }
    this.busy = true;
    const session = this.session;
    const client = new PinnedHttpClient(getContext(this).filesDir);
    const target: PinnedHttpTarget = {
      host: session.host,
      port: session.port,
      caPem: session.caPem,
    };

    // ① HTTPS + 设备 token（同时取 v4 订阅所需的 workspace target）。
    let workspacePath: string = '';
    let workspaceIdentity: string = '';
    this.setStep(STEP_INDEX_HTTPS, 'running', '连接中…');
    try {
      const info = await fetchServerInfo(client, target, session.token, session.certFingerprint);
      workspacePath = info.workspacePath;
      workspaceIdentity = info.workspaceIdentity;
      this.setStep(STEP_INDEX_HTTPS, 'pass', `已连接（serverId ${info.serverId.substring(0, 8)}…）`);
    } catch (error) {
      const pinned = error instanceof PinnedHttpError ? error : new PinnedHttpError('ConnectFailed', String(error));
      this.setStep(STEP_INDEX_HTTPS, 'fail', this.adviceFor(pinned));
    }

    // ② WSS 握手（证书文件已由 ① 的客户端写入沙箱；此处幂等确保存在）。
    this.setStep(STEP_INDEX_WSS, 'running', '握手中…');
    let wssOk: boolean = false;
    try {
      if (session.caPem.length > 0) {
        await ensureCaFileWritten(getContext(this).filesDir, session.caPem);
      }
      await probeWsHandshake(target, '/ws', caFilePathIn(getContext(this).filesDir));
      wssOk = true;
      this.setStep(STEP_INDEX_WSS, 'pass', '安全通道就绪');
    } catch (error) {
      const pinned = error instanceof PinnedHttpError ? error : new PinnedHttpError('ConnectFailed', String(error));
      this.setStep(STEP_INDEX_WSS, 'fail', this.adviceFor(pinned));
    }

    // ③ 会话拉取：真实 v4 订阅（握手 hello 版本锁 → subscribeSessionsIndex → 首个 snapshot）。
    if (!wssOk || workspacePath.length === 0) {
      this.setStep(STEP_INDEX_SESSION, 'fail',
        wssOk ? 'server-info 未下发工作区，无法订阅会话列表' : 'WSS 未就绪，跳过会话拉取');
      this.busy = false;
      return;
    }
    this.setStep(STEP_INDEX_SESSION, 'running', '订阅会话列表…');
    try {
      const workspace: WorkspaceTarget = { workspacePath: workspacePath };
      if (workspaceIdentity.length > 0) {
        workspace.workspaceIdentity = workspaceIdentity;
      }
      const result = await pullSessionsSnapshot(target, session.token,
        caFilePathIn(getContext(this).filesDir), workspace);
      this.setStep(STEP_INDEX_SESSION, 'pass', `会话列表就绪（${result.count} 个会话）`);
    } catch (error) {
      const pull = error instanceof SessionsPullError ? error : null;
      this.setStep(STEP_INDEX_SESSION, 'fail',
        pull !== null ? `会话拉取失败：${pull.detail}` : `会话拉取失败：${String(error)}`);
    }
    this.busy = false;
  }

  private toneOf(status: CheckStatus): StatusTone {
    if (status === 'pass') {
      return StatusTone.Success;
    }
    if (status === 'fail') {
      return StatusTone.Failed;
    }
    if (status === 'running') {
      return StatusTone.Running;
    }
    return StatusTone.Offline;
  }

  build() {
    Column() {
      Text('连接自检')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor(ZcodeColors.textPrimary())
        .margin({ top: 48, bottom: 4 })

      Text(`目标：${this.serverName}`)
        .fontSize(12)
        .fontColor(ZcodeColors.textTertiary())
        .margin({ bottom: 28 })

      Column({ space: 12 }) {
        ForEach(this.steps, (step: CheckStep, index: number) => {
          Row({ space: 12 }) {
            StatusDot({ tone: this.toneOf(step.status), dotSize: 12 })
            Column({ space: 2 }) {
              Text(step.title)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(ZcodeColors.textPrimary())
              Text(step.message)
                .fontSize(12)
                .fontColor(step.status === 'fail' ? ZcodeColors.DESTRUCTIVE : ZcodeColors.textTertiary())
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')
          .padding(16)
          .borderRadius(14)
          .backgroundColor(ZcodeColors.card())
          .alignItems(VerticalAlign.Center)
        }, (step: CheckStep, index: number) => `${index}-${step.status}-${step.message}`)
      }
      .padding({ left: 20, right: 20 })

      Blank()

      Column() {
        LightBloomButton({
          label: this.busy ? '检测中…' : '重新检测',
          destructive: false,
          isEnabled: !this.busy && this.session !== null,
          onAction: () => {
            this.runAllChecks();
          }
        })

        Text('返回')
          .fontSize(13)
          .fontColor(ZcodeColors.textSecondary())
          .margin({ top: 18 })
          .onClick(() => {
            router.back({ url: 'pages/Index' });
          })
      }
      .margin({ bottom: 32 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ZcodeColors.background())
    .alignItems(HorizontalAlign.Center)
  }
}
