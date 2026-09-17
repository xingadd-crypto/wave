# Wave

Wave 是一款基于 **iroh** 的去中心化 P2P 即时通讯软件。消息、文件、语音全部点对点直连传输，不经过任何中心服务器——只有好友发现依赖可选的 Moon 发现服务。

跨平台支持 **Android** 与 **Windows**，同一账号可在两端同时使用（版本号互通、可互为更新）。

---

## 核心特性

### 通讯
- **文本消息**：发送中 → 已送达 → 已读，三级状态实时展示。
- **图片消息**：发送/接收带压缩与缩略图，点击全屏预览。
- **文件传输**：带进度的断点式分块传输。
  - 接收方弹出**接受 / 拒绝**对话框，可选择保存位置，绝不静默落盘。
  - 发送方可中途**取消**；取消后消息标记失败且不会自动重发。
  - 接收完成后可直接**打开文件**或**打开所在文件夹**（Windows）。
- **语音消息**：G.711 μ-law 编解码，接收时带未读红点，点按播放/暂停。
- **语音通话**：P2P 实时通话，支持呼叫/接听/拒绝/忙线/挂断，通话界面带计时。

### 好友体系
- **二维码加好友**：扫描对方二维码互换身份（一次成功则互为好友）。
- **超声波加好友**：通过声音近距离交换身份（超出屏幕/光线受限场景）。
- 好友**在线状态**实时探测（点对点 Presence 探测，仅互为好友才回复在线，陌生人一律离线），并随上线状态同步通知。
- 通讯录管理：添加、删除、查看好友详情与状态。

### 动态（Moments）
- 发布文字 + 图片动态，图片按需拉取，好友动态实时推送与离线缓存。

### 更新分发
- 好友间直接互传**更新包**（`wave_*.zip`），自动比对平台与版本号，仅接受更新包中声明的版本。
- 收到对方的更新包后先**校验平台/版本/路径安全**，再由用户确认执行解压与安装，重启后完成更新。

### 邮箱保险箱（Email Vault）
- 基于 IMAP 的邮件同步与加密归档（`enough_mail` + AES），支持 Webmail 全文搜索导入与恢复导出。

### 其他
- **消息持久化**：本地数据库（SQLite）保存历史消息/好友/文件索引，重启不丢失。
- **通知与后台保活**：前台服务 + 本地通知，接听来电与文件传输在熄屏/后台也能工作（Android）。
- **身份安全**：Ed25519 签名 + BLAKE3 哈希 + iroh 端到端加密通道，所有 P2P 报文均签名与加密。
- 接收文件自动校验哈希，损坏自动重传。

---

## 技术栈

| 层 | 技术 |
|----|------|
| 跨平台框架 | Flutter（Material 3） |
| P2P 传输 | iroh（QUIC 打洞直连，Ed25519 身份、端到端加密） |
| 状态管理 | flutter_riverpod |
| 数据库 | SQLite（persistence_service） |
| 语音通话/录音 | 自研 `wave_audio` 原生插件（WASAPI / AAudio）+ G.711 编解码 |
| 超声波 | `ggwave_native` 插件（DPSK 音频编码） |
| 邮箱 | enough_mail（IMAP） |
| 加密 | cryptography（AES）、blake3_dart、flutter_secure_storage |
| 通知 | flutter_local_notifications + flutter_foreground_task |

---

## 构建

```bash
# Windows（需 Visual Studio 17+ BuildTools，含 C++ 桌面工作负载）
flutter build windows --release

# Android（分 ABI 多包）
flutter build apk --release --split-per-abi
# 产物位于 build/app/outputs/flutter-apk/
```

> ⚠️ Windows 注意：`build/windows/x64/runner/Release` 若只生成 exe 而缺少运行库/数据，
> 删除 `build/windows/x64/CMakeCache.txt` 后重新构建即可得到完整发布包。

---

## 发布

每个版本在 GitHub Releases 发布 4 个安装包：

- `wave-<版本>-windows.zip` — Windows 完整便携包
- `wave-<版本>-arm64.apk` / `armv7.apk` / `x86_64.apk` — Android 分架构包

## 目录结构

```
lib/
  screens/     # 聊天、通讯录、动态、邮箱、设置等界面
  services/    # iroh P2P、文件传输、通话、更新、邮箱等核心逻辑
  models/      # 消息/好友/文件传输等数据模型
  providers/   # Riverpod 状态管理
  widgets/     # 气泡、波形等聊天组件
plugins/       # 自研原生插件（wave_audio、ggwave_native）
```