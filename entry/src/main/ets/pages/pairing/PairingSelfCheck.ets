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
  probeWsHandshake
} from 'connection';
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
 * ①②为真实探测；③在本批为占位（会话协议层 L3/L4 下一批接入）。
 */
@Entry
@Component
struct PairingSelfCheck {
  @State steps: CheckStep[] = [
    { title: 'HTTPS 连通性与凭证', status: 'pending', message: '等待开始' } as CheckStep,
    { title: '安全通道（WSS 握手）', status: 'pending', message: '等待开始' } as CheckStep,
    { title: '会话列表拉取', status: 'pending', message: '等待会话协议层接入' } as CheckStep,
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

    // ① HTTPS + 设备 token。
    this.setStep(STEP_INDEX_HTTPS, 'running', '连接中…');
    try {
      const info = await fetchServerInfo(client, target, session.token, session.certFingerprint);
      this.setStep(STEP_INDEX_HTTPS, 'pass', `已连接（serverId ${info.serverId.substring(0, 8)}…）`);
    } catch (error) {
      const pinned = error instanceof PinnedHttpError ? error : new PinnedHttpError('ConnectFailed', String(error));
      this.setStep(STEP_INDEX_HTTPS, 'fail', this.adviceFor(pinned));
    }

    // ② WSS 握手（证书文件已由 ① 的客户端写入沙箱；此处幂等确保存在）。
    this.setStep(STEP_INDEX_WSS, 'running', '握手中…');
    try {
      if (session.caPem.length > 0) {
        await ensureCaFileWritten(getContext(this).filesDir, session.caPem);
      }
      await probeWsHandshake(target, '/ws', caFilePathIn(getContext(this).filesDir));
      this.setStep(STEP_INDEX_WSS, 'pass', '安全通道就绪');
    } catch (error) {
      const pinned = error instanceof PinnedHttpError ? error : new PinnedHttpError('ConnectFailed', String(error));
      this.setStep(STEP_INDEX_WSS, 'fail', this.adviceFor(pinned));
    }

    // ③ 会话拉取：占位（L3/L4 下一批接入后替换为真实拉取）。
    this.setStep(STEP_INDEX_SESSION, 'pending', '等待会话协议层接入（下一批）');
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
