import router from '@ohos.router';
import {
  AssetTokenStore,
  PairLinkData,
  PairRouteParams,
  PairingSession,
  PinnedHttpClient,
  PinnedHttpError,
  PinnedHttpTarget,
  ProfileStore,
  claimPairing,
  computeSpkiSha256Hex,
  isBase64Der,
  isPairLink,
  parsePairLink,
  pemFromDerBase64
} from 'connection';
import { LightBloomButton, ZcodeColors } from 'uikit';

/** 深链解析结果的展示摘要。 */
interface ParsedSummary {
  name: string;
  host: string;
  port: number;
  fingerprint: string;
  certValid: boolean;
}

/**
 * 手动添加页（ONB-4）：粘贴 zcode://pair 链接自动填充，或手填 名称/地址/配对码。
 * 「开始连接」执行：证书固定校验 → claim → token 入 Asset → 档案落盘 → 跳自检页。
 */
@Entry
@Component
struct PairingCodeInput {
  @State linkText: string = '';
  @State deviceName: string = '我的鸿蒙手机';
  @State manualName: string = '';
  @State manualAddress: string = '';
  @State manualToken: string = '';
  @State summary: ParsedSummary | null = null;
  @State formError: string = '';
  @State busy: boolean = false;
  @State busyText: string = '';

  aboutToAppear(): void {
    const params = router.getParams() as PairRouteParams | null;
    if (params !== null && params.link.length > 0) {
      this.linkText = params.link;
      this.applyLink(params.link);
    }
  }

  /** 粘贴内容变化时即时解析（合法深链才覆盖摘要）。 */
  private applyLink(raw: string): void {
    this.formError = '';
    if (!isPairLink(raw)) {
      this.summary = null;
      return;
    }
    const parsed = parsePairLink(raw);
    if (parsed === null) {
      this.summary = null;
      this.formError = '链接不完整：缺少 host/port/配对码';
      return;
    }
    this.applyParsed(parsed);
  }

  private applyParsed(parsed: PairLinkData): void {
    if (parsed.name.length > 0) {
      this.manualName = parsed.name;
    }
    this.manualAddress = `${parsed.host}:${parsed.port}`;
    this.manualToken = parsed.pairCode;
    this.summary = {
      name: parsed.name,
      host: parsed.host,
      port: parsed.port,
      fingerprint: parsed.fingerprint,
      certValid: parsed.certBase64.length > 0,
    };
  }

  private onLinkChange(value: string): void {
    this.linkText = value;
    this.applyLink(value);
  }

  /** 手填字段解析（地址 host:port）。 */
  private parseManual(): PairLinkData | null {
    const address = this.manualAddress.trim();
    const colon = address.lastIndexOf(':');
    if (colon <= 0 || colon === address.length - 1) {
      this.formError = '地址格式应为 host:port（如 192.168.1.10:8788）';
      return null;
    }
    const port = Number.parseInt(address.substring(colon + 1), 10);
    if (Number.isNaN(port) || port <= 0 || port > 65535) {
      this.formError = '端口不合法';
      return null;
    }
    const host = address.substring(0, colon);
    const token = this.manualToken.trim();
    if (host.length === 0 || token.length === 0) {
      this.formError = '请填写地址与配对码';
      return null;
    }
    return {
      host: host,
      port: port,
      pairCode: token,
      name: this.manualName.trim(),
      fingerprint: '',
      certBase64: '',
    };
  }

  /** 失败语义 → 可执行建议（spec §4）。 */
  private adviceFor(error: PinnedHttpError): string {
    switch (error.kind) {
      case 'PemInvalid':
        return '证书数据异常：请重新出码再试';
      case 'HandshakeFailed':
        return '安全校验未通过：请重新出码再试（可能有人拦截网络）';
      case 'ConnectFailed':
        return '连不上电脑：检查手机与电脑是否同一网络；电脑端 ZCode 是否在运行';
      case 'Timeout':
        return '网络超时：检查 Wi-Fi 与防火墙是否放行端口';
      case 'HttpStatus':
        if (error.statusCode === 401) {
          return '配对码无效或已过期：请重新出码';
        }
        if (error.statusCode === 429) {
          return '尝试太频繁：请一分钟后再试';
        }
        if (error.statusCode === 409) {
          return '设备数量已达上限：请在桌面端移除一台设备';
        }
        return error.message.length > 0 ? error.message : `连接被拒绝（HTTP ${error.statusCode ?? 0}）`;
      default:
        return error.message;
    }
  }

  private async startConnect(): Promise<void> {
    if (this.busy) {
      return;
    }
    let link: PairLinkData | null = null;
    if (this.linkText.trim().length > 0 && isPairLink(this.linkText)) {
      link = parsePairLink(this.linkText);
      if (link === null) {
        this.formError = '链接不完整：缺少 host/port/配对码';
        return;
      }
    } else {
      link = this.parseManual();
      if (link === null) {
        return;
      }
    }
    this.busy = true;
    this.formError = '';
    try {
      // 1. 证书带外校验（spec §1.1）：fp 与证书 SPKI 必须一致，不一致不发起任何网络请求。
      let caPem = '';
      if (link.certBase64.length > 0) {
        if (!isBase64Der(link.certBase64)) {
          throw new PinnedHttpError('PemInvalid', '二维码中的证书数据损坏');
        }
        caPem = pemFromDerBase64(link.certBase64);
        this.busyText = '校验证书指纹…';
        const spki = await computeSpkiSha256Hex(caPem);
        if (link.fingerprint.length > 0 && spki !== link.fingerprint) {
          throw new PinnedHttpError('HandshakeFailed', '证书指纹与二维码不一致，可能有人拦截网络');
        }
        link.fingerprint = spki;
      }
      const target: PinnedHttpTarget = {
        host: link.host,
        port: link.port,
        caPem: caPem,
      };
      const client = new PinnedHttpClient(getContext(this).filesDir);
      // 2. claim（一次性配对码换设备 token）。
      this.busyText = '正在配对…';
      const claimed = await claimPairing(client, target, link.pairCode, this.deviceName.trim());
      if (claimed.certFingerprint.length > 0 && link.fingerprint.length > 0
        && claimed.certFingerprint !== link.fingerprint) {
        throw new PinnedHttpError('HandshakeFailed', '服务端证书指纹与配对时不一致');
      }
      // 3. token 入 Asset → 档案落盘（顺序即事件顺序，spec §2）。
      this.busyText = '保存设备凭证…';
      const tokenStore = new AssetTokenStore();
      await tokenStore.save(claimed.serverId, claimed.accessToken);
      const store = await ProfileStore.open(getContext(this));
      const profileId = `p_${claimed.serverId}`;
      await store.saveProfile({
        id: profileId,
        name: claimed.serverName.length > 0 ? claimed.serverName : this.manualName.trim(),
        host: link.host,
        port: link.port,
        certFingerprint: link.fingerprint,
      });
      // 4. 跳自检页（token/证书仅经内存传递）。
      const session: PairingSession = {
        host: link.host,
        port: link.port,
        serverName: claimed.serverName,
        serverId: claimed.serverId,
        certFingerprint: link.fingerprint,
        caPem: caPem,
        token: claimed.accessToken,
      };
      router.replaceUrl({
        url: 'pages/pairing/PairingSelfCheck',
        params: session as object
      }).catch(() => {});
    } catch (error) {
      const pinned = error instanceof PinnedHttpError ? error : new PinnedHttpError('ConnectFailed', String(error));
      this.formError = this.adviceFor(pinned);
    } finally {
      this.busy = false;
      this.busyText = '';
    }
  }

  build() {
    Column() {
      Row() {
        Text('←')
          .fontSize(22)
          .fontColor(ZcodeColors.textSecondary())
          .onClick(() => {
            router.back();
          })
      }
      .width('100%')
      .padding({ left: 20, top: 16 })
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column() {
          Text('粘贴配对链接')
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor(ZcodeColors.textPrimary())
            .margin({ top: 12, bottom: 8 })

          TextArea({ text: this.linkText, placeholder: '粘贴 zcode://pair?… 完整链接' })
            .fontSize(13)
            .fontColor(ZcodeColors.textPrimary())
            .placeholderColor(ZcodeColors.textTertiary())
            .backgroundColor(ZcodeColors.card())
            .borderRadius(12)
            .height(84)
            .onChange((value: string) => {
              this.onLinkChange(value);
            })

          Text('在电脑端「移动端配对」页面复制链接后粘贴到这里')
            .fontSize(11)
            .fontColor(ZcodeColors.textTertiary())
            .margin({ top: 6, bottom: 20 })

          Text('或手动填写')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(ZcodeColors.textSecondary())
            .margin({ top: 4, bottom: 8 })

          Text('电脑名称（可选）')
            .fontSize(11)
            .fontColor(ZcodeColors.textTertiary())
            .margin({ top: 6, bottom: 4 })
          TextInput({ text: this.manualName })
            .fontSize(13)
            .fontColor(ZcodeColors.textPrimary())
            .backgroundColor(ZcodeColors.card())
            .borderRadius(12)
            .height(44)
            .onChange((value: string) => {
              this.manualName = value;
            })

          Text('地址（host:port）')
            .fontSize(11)
            .fontColor(ZcodeColors.textTertiary())
            .margin({ top: 10, bottom: 4 })
          TextInput({ text: this.manualAddress })
            .fontSize(13)
            .fontColor(ZcodeColors.textPrimary())
            .backgroundColor(ZcodeColors.card())
            .borderRadius(12)
            .height(44)
            .onChange((value: string) => {
              this.manualAddress = value;
            })

          Text('配对码')
            .fontSize(11)
            .fontColor(ZcodeColors.textTertiary())
            .margin({ top: 10, bottom: 4 })
          TextInput({ text: this.manualToken })
            .fontSize(13)
            .fontColor(ZcodeColors.textPrimary())
            .backgroundColor(ZcodeColors.card())
            .borderRadius(12)
            .height(44)
            .onChange((value: string) => {
              this.manualToken = value;
            })

          if (this.summary !== null) {
            Column({ space: 6 }) {
              Text(`目标：${this.summary.name.length > 0 ? this.summary.name : this.summary.host}`)
                .fontSize(12)
                .fontColor(ZcodeColors.textSecondary())
              Text(`地址：${this.summary.host}:${this.summary.port}`)
                .fontSize(12)
                .fontColor(ZcodeColors.textSecondary())
              Text(this.summary.certValid ? '证书已通过指纹校验 ✓' : '无证书固定（纯 HTTP 部署）')
                .fontSize(12)
                .fontColor(this.summary.certValid ? ZcodeColors.SUCCESS : ZcodeColors.WARNING)
            }
            .alignItems(HorizontalAlign.Start)
            .padding(12)
            .borderRadius(12)
            .backgroundColor(ZcodeColors.card())
            .margin({ top: 14 })
          }

          TextInput({ text: this.deviceName })
            .fontSize(13)
            .fontColor(ZcodeColors.textPrimary())
            .backgroundColor(ZcodeColors.card())
            .borderRadius(12)
            .height(44)
            .margin({ top: 14 })
            .onChange((value: string) => {
              this.deviceName = value;
            })

          if (this.formError.length > 0) {
            Text(this.formError)
              .fontSize(12)
              .fontColor(ZcodeColors.DESTRUCTIVE)
              .margin({ top: 12 })
          }

          Column() {
            LightBloomButton({
              label: this.busy ? this.busyText : '开始连接',
              destructive: false,
              isEnabled: !this.busy,
              onAction: () => {
                this.startConnect();
              }
            })
          }
          .margin({ top: 24 })
        }
        .constraintSize({ minHeight: '100%' })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
      .padding({ left: 24, right: 24, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ZcodeColors.background())
  }
}
