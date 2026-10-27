/**
 * ZToast（shadcn/ui Sonner 的鸿蒙转译，批次28）。
 *
 * 语义对齐 shadcn Sonner：底部居中的浮层提示（--card 底 + 1px --border），
 * 自动消失。App 级全局：ZToast.show(text) 写入 AppStorage，页面根部挂一个
 * ZToastHost 即可全 App 收到（无需逐页接线）。
 */
import { ZcodeColors } from '../theme/ZcodeColors';
import { DesignTokens } from '../theme/DesignTokens';
import { Motion } from '../theme/Motion';

/** AppStorage 键（字面量：@StorageLink 需要编译期常量）。 */
const TOAST_MESSAGE_KEY: string = 'zcode_toast_message';

/** 全局轻提示入口：任意页面/服务层可直接调用 show()。 */
export class ZToast {
  private static timerId: number = -1;

  /** 弹出一条提示（2.6s 后自动消失，重复调用会续期）。 */
  static show(message: string): void {
    AppStorage.setOrCreate<string>(TOAST_MESSAGE_KEY, message);
    if (ZToast.timerId !== -1) {
      clearTimeout(ZToast.timerId);
    }
    ZToast.timerId = setTimeout(() => {
      ZToast.timerId = -1;
      AppStorage.setOrCreate<string>(TOAST_MESSAGE_KEY, '');
    }, 2600);
  }

  /** 清空当前提示。 */
  static hide(): void {
    if (ZToast.timerId !== -1) {
      clearTimeout(ZToast.timerId);
      ZToast.timerId = -1;
    }
    AppStorage.setOrCreate<string>(TOAST_MESSAGE_KEY, '');
  }
}

/** 全局提示宿主：挂在页面根（Index.ets）即可。 */
@Component
export struct ZToastHost {
  @StorageLink('zcode_toast_message') message: string = '';

  build() {
    Column() {
      if (this.message.length > 0) {
        Text(this.message)
          .fontSize(DesignTokens.FONT_SUB)
          .fontColor(ZcodeColors.textPrimary())
          .padding({
            left: DesignTokens.SPACE_MD,
            right: DesignTokens.SPACE_MD,
            top: DesignTokens.SPACE_SM,
            bottom: DesignTokens.SPACE_SM,
          })
          .backgroundColor(ZcodeColors.CARD)
          .borderRadius(DesignTokens.RADIUS_MD)
          .border({ width: 1, color: ZcodeColors.BORDER })
          .shadow({ radius: 16, color: '#66000000', offsetY: 4 })
          .animation({ duration: Motion.DUR_MICRO, curve: Curve.EaseOut })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ bottom: 96 })
  }
}
