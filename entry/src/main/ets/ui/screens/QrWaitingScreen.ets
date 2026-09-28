/**
 * 扫码登录的「等待网页确认」屏（对应 Android `ui/screens/auth/QrAuthScreens.kt` 的 `QrWaitingScreen`）。
 *
 * 两件事：
 * 1. 渲染上游那一屏（BackPill + 168dp 顶留白 + 监控图标 + 四态标题 + 副文）；
 * 2. 驱动轮询/兑换（`authController.completeQrLogin`），状态变化只写进 `@State`，
 *  不让 build 直接读 controller（否则 `@State` 不会登记渲染依赖，见坑 134）。
 *
 * 本文件同时导出 `AaBackPill` —— 登录流程四屏共用的胶囊返回件（上游 `Components.kt:64-85`）。
 * 放在这里是为了让依赖方向保持单向：`LoginScreen → QrWaitingScreen`（反向会让两个屏互相 import）。
 */

import { authController } from '../../feature/AppServices';
import { FontSize, Radius, borderColor, canvas, errorText, ink, raisedSurface } from '../Design';
import { AuthFont, AuthLineHeight, AuthMetrics, AuthText, qrWaitingTitle } from './AuthFlow';
import { AaIcon, ICONS } from '../Icon';

/**
 * 胶囊返回（上游 `BackPill`）：高 36dp、Pill 圆角、raisedSurface 底、1.2dp 描边、
 * 图标 16dp + 文字 13sp、水平 padding 12dp、两者间距 7dp。
 */
@Component
export struct AaBackPill {
  @Prop label: string = AuthText.BACK;
  onBack?: () => void;

  build() {
    Row({ space: AuthMetrics.BACK_PILL_GAP }) {
      // 上游是 Lucide.ArrowLeft 矢量图标；本工程没有字体图标资源，用文本符号近似
      // （与 AaTopBar 的 '‹' 同款做法，见 Components.ets 的说明）。
      AaIcon({ d: ICONS['chevron-left'], iconSize: AuthMetrics.BACK_PILL_ICON, color: ink() })
      Text(this.label)
        .fontSize(FontSize.SMALL)
        .fontWeight(FontWeight.Medium)
        .fontColor(ink())
    }
    .height(AuthMetrics.BACK_PILL_H)
    .padding({ left: AuthMetrics.BACK_PILL_PADDING_H, right: AuthMetrics.BACK_PILL_PADDING_H })
    .borderRadius(Radius.PILL)
    .backgroundColor(raisedSurface())
    .borderWidth(AuthMetrics.BACK_PILL_BORDER)
    .borderColor(borderColor())
    .onClick(() => {
      if (this.onBack !== undefined) {
        this.onBack();
      }
    })
  }
}

@Component
export struct QrWaitingScreen {
  /** 二维码负载（`parseMobileLoginQr` 的结果）。 */
  @Prop userId: string = '';
  @Prop loginToken: string = '';
  /** 二维码里带的服务地址：与当前不一致时先切换（上游在扫码请求前就切好了）。 */
  @Prop serverUrl: string = '';
  /** 上报给服务端的设备名。 */
  @Prop deviceName: string = 'HarmonyOS 设备';
  /** 返回 QrLogin（上游 `QrAuthScreens.kt:206`）。 */
  onBack?: () => void;
  /** 登录成功；本工程由根页面按 `AuthStage.SIGNED_IN` 切页，这里只是给独立挂载留的钩子。 */
  onSucceeded?: () => void;

  @State status: string = '';
  @State exchanging: boolean = false;
  @State error: string = '';
  /** 轮询只发起一次：`@Prop` 变化会重渲染但不会重跑 `aboutToAppear`。 */
  private started: boolean = false;
  /** 页面是否还活着：异步链路回来后要复查，避免给已销毁的页面写状态。 */
  private alive: boolean = false;

  aboutToAppear(): void {
    this.alive = true;
    this.begin();
  }

  aboutToDisappear(): void {
    this.alive = false;
  }

  private async begin(): Promise<void> {
    if (this.started) {
      return;
    }
    this.started = true;
    if (this.loginToken.length === 0) {
      this.error = AuthText.QR_SCAN_FIRST;
      return;
    }
    // 二维码里带的地址与当前不一致时先切过去（与网页端展示的实例一致）
    if (this.serverUrl.length > 0 && authController.current.serverUrl !== this.serverUrl) {
      const connected = await authController.connectServer(this.serverUrl);
      if (!this.alive) {
        return;
      }
      if (!connected) {
        this.error = authController.current.error;
        return;
      }
    }
    const ok = await authController.completeQrLogin(this.userId, this.loginToken, this.deviceName,
      (status: string) => {
        if (!this.alive) {
          return;
        }
        // 上游把「已批准、正在兑换 token」这一小段单独显示成「正在完成登录...」
        if (status === 'approved') {
          this.exchanging = true;
        }
        this.status = status;
      });
    if (!this.alive) {
      return;
    }
    this.exchanging = false;
    if (!ok) {
      this.error = authController.current.error.length > 0 ? authController.current.error : AuthText.QR_START_FAILED;
      return;
    }
    if (this.onSucceeded !== undefined) {
      this.onSucceeded();
    }
  }

  build() {
    Column({ space: AuthMetrics.WAITING_GAP }) {
      AaBackPill({
        label: AuthText.BACK,
        onBack: () => {
          if (this.onBack !== undefined) {
            this.onBack();
          }
        }
      })

      Column({ space: AuthMetrics.WAITING_TEXT_GAP }) {
        // 上游 `QrAuthScreens.kt:437` 的 `Lucide.Monitor`（槽位 64×52dp 照抄，矢量图标居中）。
        Column() {
          AaIcon({ d: ICONS[AuthText.ICON_MONITOR], iconSize: AuthMetrics.WAITING_ICON_H - 4, color: ink() })
        }
          .width(AuthMetrics.WAITING_ICON_W)
          .height(AuthMetrics.WAITING_ICON_H)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        Text(qrWaitingTitle(this.exchanging, this.status))
          .fontSize(AuthFont.WAITING_TITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor(ink())
          .lineHeight(AuthLineHeight.WAITING_TITLE)
          .textAlign(TextAlign.Center)
        if (this.error.length > 0) {
          // 上游这一屏的错误就是普通居中副文（不是 AuthErrorNotice）
          Text(this.error)
            .fontSize(AuthFont.QR_HINT)
            .fontColor(errorText())
            .lineHeight(AuthLineHeight.QR_HINT)
            .textAlign(TextAlign.Center)
        }
      }
      .width('100%')
      .padding({ top: AuthMetrics.WAITING_TOP })
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .padding({
      left: AuthMetrics.PAGE_H,
      right: AuthMetrics.PAGE_H,
      top: AuthMetrics.SHELL_TOP,
      bottom: AuthMetrics.PAGE_BOTTOM
    })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(canvas())
  }
}
