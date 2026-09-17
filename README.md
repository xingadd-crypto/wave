# flutter_wave

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

---

## 已知问题（待测试修复）

### Windows 语音通话「接收语音失败退出」（2026-09-02 记录，未修复）

- **现象**：Windows 端呼出/应答的语音通话在建立后约 100ms 内即退出，界面提示「接收语音失败」。对方（Rust CLI）能收到本机的语音，但本机「接收」路径失败。
- **证据（`C:\Users\Administrator\wave_conn_log.txt` + `wave_audio.log`）**：
  - 原生 WASAPI 插件 `wave_audio` 完全正常：mic 捕获持续出包（`capture: pkt #N`）、扬声器渲染持续写帧（`render: iter #N`），HRESULT 全部 OK。
  - Dart 侧 `Media session started` → 立即 `Media: readMsg error` → `Call ended`，`play()` 为 0 次，即**从未收到任何 `CallAudio` 帧**。
- **定位**：媒体会话的 `_readMsg(rx)`（`readExact(4)`）瞬间抛错，属已排队的本地流错误，非远端刚断。已从 Rust CLI（`G:\wave`，v0.3.0 工作树）源码确认：CLI 与 Flutter 共用同一条 bi-stream、相同 u32 LE 长度前缀分帧、且 CLI 用 ALSA（Windows 上采集会失败但不主动关流）。
- **待办**：已部署带异常详情日志的构建（`app.so` 1:23:59）；需用户重新完整退出并启动 `G:\wave\wave_deploy\flutter_wave.exe` 复现一次，读取 `readExact` 的具体异常消息/堆栈，判定是 Wave 本地流状态问题还是 CLI 主动关流，再决定改 Dart 或同步改 Rust CLI。

---

## 版本历史

### 1.0.1+2（2026-09-01）

- **新增** P2P 好友在线状态：不再依赖 Moon 服务器在线列表，改为通过点对点探测（`PresenceProbe`/`PresenceReply`）实时判断好友是否在线，仅已互为好友时回复"在线"，陌生人一律"离线"。
- **新增** P2P 语音通话（呼出/来电/接听/拒接/挂断/忙线 + 通话中界面与计时）：通话信令与媒体均走同一条持久化 bi-stream，语音采用 G.711 μ-law（8kHz 单声道）编解码。
- **新增** 通话入口：聊天界面上方新增拨打按钮；来电时自动弹出通话界面，可接听或拒接，响铃 30 秒无应答自动超时。
- **协议扩展** `MessageBody` 新增变体：`CallInvite/CallAccept/CallReject/CallBusy/CallHangup/CallAudio/PresenceProbe/PresenceReply`（索引 13–20），与 Rust CLI v0.2.0 对齐。
- **重构** 移除对 Moon `listOnlineUsers` 的在线状态依赖，`discover_screen` 仍保留 Moon 用于用户发现。

### 1.0.0+1（2026-08-31）

- **新增** 聊天界面好友在线/离线状态显示（绿色圆点=在线，灰色=离线），打开聊天时自动刷新，应用运行期间每 15 秒自动同步一次。
- **新增** 消息列表（Chats）中好友头像的在线状态圆点改为反映真实在线状态（替代原先的固定绿点）。
- **修正** 文本消息状态：发送时显示"发送中"，对方确认接收（ACK）后显示"已送达"，对方离线或连接失败时显示"发送失败"（此前始终停留在"已发送"单勾状态）。
- **修复** 相关逻辑：好友数据模型新增 `isOnline` 字段、好友在线状态按 Moon 服务器在线列表同步。
- **优化** 减少对 Moon 服务器的频繁连接：在线状态轮询由每 15 秒延长至每 60 秒，并新增最小 30 秒间隔限流，避免打开聊天/定时器重复查询打满服务器。
- **优化** 无需求时不连接 Moon 服务器：移除后台定时器，仅在用户打开「聊天列表」「通讯录」或进入聊天界面等真正需要显示在线状态的时刻，才按需查询一次（仍受 30 秒限流约束）。


