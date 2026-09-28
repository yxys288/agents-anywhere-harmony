# NOTICE — 上游归属与许可声明

本仓库（**Agents Anywhere 鸿蒙原生客户端**）是基于下述上游开源项目所做的**鸿蒙端适配**。

## 上游项目

| 项 | 内容 |
| --- | --- |
| 项目名 | **Agents Anywhere** |
| 项目地址 | https://github.com/anywhere-labs/Agents-Anywhere |
| 维护方 | anywhere-labs（上游组织，https://github.com/anywhere-labs ） |
| 项目官网 | https://www.agents-anywhere.com |
| Web 入口 | https://web.agents-anywhere.com |
| 上游许可 | **MIT** |
| 上游版权标识 | Copyright (c) 2026 Agents Anywhere Contributors |

上游许可与版权标识的核验依据：上游仓库 README 的「开源许可」章节明确标注为 MIT；
上游仓库内的 dsh-bridge/LICENSE 载明「MIT License / Copyright (c) 2026 Agents Anywhere Contributors」。
核验日期：2026-09-28。

## 本仓库与上游的关系

- 本仓库是上游 **Android 原生客户端**（Kotlin + Jetpack Compose，约 4.2 万行）的 **ArkTS / ArkUI 鸿蒙端适配**，
  面向 HarmonyOS 7 / API 26，采用 Stage 模型。协议、交互与信息架构以上游 Android 端为基准改写。
- 本仓库**不是上游官方发布**；它与上游的 Android / iOS / 桌面 / Web 客户端是**并存的客户端**，不是替代关系。
- 本仓库**不包含**上游源码，也未修改上游任何仓库；它是对上游协议与交互的独立鸿蒙实现。
- 上游项目名、品牌与相关素材的权利归上游所有；本仓库对其的使用仅用于**指明来源与适配对象**。

## 第三方组件

| 组件 | 许可 | 用途 |
| --- | --- | --- |
| Lucide 图标（lucide-static） | ISC | 界面图标来源（按图标名取用，见 entry/src/main/ets/ui/Icon.ets） |
| Caveat 字体 | SIL Open Font License 1.1 | 手写体展示（entry/src/main/resources/rawfile/fonts/caveat_wght.ttf） |

## 上游 MIT 许可全文

为满足 MIT 许可「保留版权声明与许可声明」的要求，兹将上游许可全文附于下方：

    MIT License

    Copyright (c) 2026 Agents Anywhere Contributors

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
