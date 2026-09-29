import router from '@ohos.router';
import { ZcodeColors } from 'uikit';

/**
 * 组网指引页（CONN-4，P0 只做指引不做集成）：
 * 局域网直连条件 + Tailscale / FRP 两条跨网路径的图文步骤 + 常见问题。
 */
@Entry
@Component
struct NetworkGuide {
  @State expanded: string = 'lan';

  @Builder
  Section(title: string, key: string, contentLines: string[]) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(this.expanded === key ? '▾' : '▸')
          .fontSize(12)
          .fontColor(ZcodeColors.textSecondary())
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(ZcodeColors.textPrimary())
      }
      .width('100%')
      .onClick(() => {
        this.expanded = this.expanded === key ? '' : key;
      })

      if (this.expanded === key) {
        Column({ space: 6 }) {
          ForEach(contentLines, (line: string) => {
            Text(line)
              .fontSize(13)
              .fontColor(ZcodeColors.textSecondary())
              .width('100%')
          }, (line: string) => line)
        }
        .width('100%')
        .padding({ left: 4, top: 2, bottom: 4 })
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .padding(14)
    .borderRadius(14)
    .backgroundColor(ZcodeColors.card())
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        Text('‹')
          .fontSize(22)
          .fontColor(ZcodeColors.textSecondary())
          .onClick(() => {
            router.back();
          })
        Text('组网指引')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(ZcodeColors.textPrimary())
        Blank()
      }
      .width('100%')
      .padding({ left: 16, right: 20, top: 14, bottom: 8 })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column({ space: 10 }) {
          this.Section('局域网直连（推荐首选）', 'lan', [
            '① 手机与电脑连同一个 Wi-Fi（路由器未开「AP 隔离」）。',
            '② 电脑端 ZCode 开启「移动端配对」，保持服务运行。',
            '③ 电脑防火墙放行 ZCode 监听端口（默认弹窗允许即可）。',
            '④ 回到配对页扫码或粘贴链接即可。不满足时看下面两条路径。',
          ])

          this.Section('Tailscale 组网（跨网络推荐）', 'tailscale', [
            '适用：手机在外、电脑在家/公司，且可安装第三方组网工具。',
            '① 电脑与手机都安装 Tailscale 并登录同一账号（免费档够用）。',
            '② 电脑端确认 ZCode 服务运行中；记录 Tailscale 分配的 100.x 地址。',
            '③ 手机浏览器访问 http://<电脑的100.x地址>:<端口> 确认可达。',
            '④ 电脑端生成配对链接时，把链接里的 host 改为 100.x 地址后再扫码/粘贴。',
            '优点：端到端加密，无需公网暴露端口（安全）。',
          ])

          this.Section('FRP / 反向代理（有公网服务器时）', 'frp', [
            '适用：自有一台公网 VPS。',
            '① VPS 运行 frps（示例端口 7000）；电脑运行 frpc 把本地端口映射到 VPS 端口。',
            '② 强烈建议同时启用 TLS（电脑端配置证书）并在 VPS 防火墙仅放行所需端口。',
            '③ 手机端配对链接里的 host 填 VPS 域名、port 填映射端口。',
            '注意：不要把无鉴权端口直接暴露公网（配对后 token 鉴权仍建议叠加 TLS）。',
          ])

          this.Section('常见问题', 'faq', [
            '· 扫码后自检第①步失败：多为不同网段/防火墙拦截，先按上面路径组网。',
            '· 自检第②步失败（WSS）：证书指纹不一致或被中间设备替换，重新配对。',
            '· 连接时断时续：手机省电策略杀后台，把 ZCode 加入受保护应用/自启动。',
            '· 公司网络不可用：企业网络常拦截自签证书，用 Tailscale 绕开。',
          ])

          Text('以上为配置指引，App 不代改系统/路由器设置（CONN-4 P0 范围）。')
            .fontSize(10)
            .fontColor(ZcodeColors.textTertiary())
            .width('100%')
            .textAlign(TextAlign.Center)
        }
        .padding({ left: 16, right: 16, bottom: 24 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ZcodeColors.background())
  }
}
