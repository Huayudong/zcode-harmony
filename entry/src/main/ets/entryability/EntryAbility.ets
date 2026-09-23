import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import router from '@ohos.router';
import { isPairLink, PairRouteParams } from 'connection';
import { BusinessError } from '@ohos.base';

const DOMAIN: number = 0x0000;
const TAG: string = 'EntryAbility';
const PAIRING_PAGE: string = 'pages/pairing/PairingCodeInput';

export default class EntryAbility extends UIAbility {
  private pendingPairLink: string = '';

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onCreate, uri=%{public}s', want.uri ?? '');
    // 冷启动深链：onNewWant 不会再触发，先暂存、页面栈就绪后路由。
    if (isPairLink(want.uri ?? '')) {
      this.pendingPairLink = want.uri ?? '';
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
