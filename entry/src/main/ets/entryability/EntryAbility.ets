import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import router from '@ohos.router';
import { isPairLink, PairRouteParams } from 'connection';
import { PerfMarks } from 'utils';
import { BusinessError } from '@ohos.base';

const DOMAIN: number = 0x0000;
const TAG: string = 'EntryAbility';
const PAIRING_PAGE: string = 'pages/pairing/PairingCodeInput';

/** 通知点击直达会话页的路由参数（与 SessionList 侧同构）。 */
interface SessionRouteParams {
  sessionId: string;
  title: string;
}

export default class EntryAbility extends UIAbility {
  private pendingPairLink: string = '';
  private pendingSessionId: string = '';

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    PerfMarks.mark('cold_start');
    hilog.info(DOMAIN, TAG, 'onCreate, uri=%{public}s', want.uri ?? '');
    // 冷启动深链：onNewWant 不会再触发，先暂存、页面栈就绪后路由。
    if (isPairLink(want.uri ?? '')) {
      this.pendingPairLink = want.uri ?? '';
    }
    this.extractSessionId(want);
  }

  /** 通知点击直达（A8）：want.parameters.sessionId → 会话页路由参数。 */
  private extractSessionId(want: Want): void {
    const params = want.parameters;
    if (params !== undefined) {
      const sessionId = params.sessionId;
      if (typeof sessionId === 'string' && sessionId.length > 0) {
        this.pendingSessionId = sessionId;
      }
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageCreate');
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent succeeded');
      if (this.pendingPairLink.length > 0) {
        const link = this.pendingPairLink;
        this.pendingPairLink = '';
        this.openPairingPage(link);
      }
      if (this.pendingSessionId.length > 0) {
        const sessionId = this.pendingSessionId;
        this.pendingSessionId = '';
        const options: router.RouterOptions = { url: 'pages/workbench/SessionDetail', params: { sessionId: sessionId, title: '' } as SessionRouteParams };
        router.pushUrl(options).catch((error: BusinessError) => {
          hilog.error(DOMAIN, TAG, 'openSessionPage failed: %{public}s', String(error));
        });
      }
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageDestroy');
  }

  /**
   * 深链入口（ONB-2 深链分支，a3-pairing spec §1.3）：
   * zcode://pair 冷启动/热启动都路由到手动导入页并预填。
   * 冷启动时 onWindowStageCreate 先行、onNewWant 在页面栈就绪后触发，路由均安全。
   */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onNewWant, uri=%{public}s', want.uri ?? '');
    const uri = want.uri ?? '';
    if (isPairLink(uri)) {
      this.openPairingPage(uri);
    }
    this.extractSessionId(want);
    if (this.pendingSessionId.length > 0) {
      const sessionId = this.pendingSessionId;
      this.pendingSessionId = '';
      const options: router.RouterOptions = { url: 'pages/workbench/SessionDetail', params: { sessionId: sessionId, title: '' } as SessionRouteParams };
      router.pushUrl(options).catch((error: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'openSessionPage failed: %{public}s', String(error));
      });
    }
  }

  private openPairingPage(link: string): void {
    const params: PairRouteParams = { link: link };
    const options: router.RouterOptions = { url: PAIRING_PAGE, params: params };
    router.pushUrl(options).catch((error: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'openPairingPage failed: %{public}s', String(error));
    });
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'onBackground');
  }
}
