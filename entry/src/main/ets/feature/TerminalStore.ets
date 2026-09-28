/**
 * 远程终端状态（对应 Android `feature/terminal/RemoteTerminalController.kt` +
 * `RemoteTerminalPool.kt` + `RemoteTerminalOutputBuffer.kt`）。
 *
 * 线协议（服务端 `infra/terminal_stream_hub.py` + `api/connector_terminal.py`）：
 *  服务端 → 客户端：`{"type":"replay","data":<base64>,"seq":N}`
 *  `{"type":"output","data":<base64>,"seq":N}`
 *  `{"type":"exit","exitCode":N|null,"reason":"exit"}`
 *  `{"type":"error","code":N,"message":"..."}`
 *  `{"type":"pong"}`
 *  客户端 → 服务端：`{"type":"input","data":<base64>}`
 *  `{"type":"resize","cols":N,"rows":N}`
 *  `{"type":"ping"}`
 * 即：**所有帧都是 JSON 文本，PTY 字节用 base64 承载**。
 *
 * 与 Android 的差异：Android 用前台服务保活 + Termux 的 View 层；
 * 鸿蒙端把仿真器与连接放在单例里，页面只做渲染与输入，退到后台时连接保持
 * （系统可能回收，重进页面会按 `fromSeq` 续传）。
 */

import { AppServices } from './AppServices';
import { readAccessToken, readServerUrl } from '../store/AuthSessionStore';
import { RemoteTerminal } from '../model/Types';
import { RealtimeSocket, SocketHandlers, reconnectDelayMillis } from '../api/RealtimeApi';
import { TerminalEmulator, TerminalOutput } from '../vt/TerminalEmulator';
import { defaultColorScheme } from '../vt/TerminalStyle';
import { base64Decode, base64Encode } from '../utils/Codec';
import { utf8Bytes } from '../utils/Sha256';
import { emptyRaw, optNumber, optString, Raw, str } from '../api/Parse';

export enum TerminalConnectionState {
  IDLE = 'idle',
  CREATING = 'creating',
  CONNECTING = 'connecting',
  STREAMING = 'streaming',
  EXITED = 'exited',
  ERROR = 'error'
}

export class TerminalStore {
  private static instance?: TerminalStore;

  deviceId: string = '';
  root: string = '.';
  cwd: string = '.';
  terminal?: RemoteTerminal;
  state: TerminalConnectionState = TerminalConnectionState.IDLE;
  statusText: string = '';
  error: string = '';
  cols: number = 80;
  rows: number = 24;
  exitCode?: number;

  emulator: TerminalEmulator;
  /** 屏幕内容变化的序号，页面用它触发重绘（ArkUI 对 class 内部字段不感知）。 */
  revision: number = 0;

  private socket?: RealtimeSocket;
  private listeners: Array<() => void> = [];
  private reconnectAttempt: number = 0;
  private reconnectTimer: number = -1;
  private shouldStream: boolean = false;
  lastSeq: number = 0;
  private pingTimer: number = -1;
  private title: string = '';
  private hasTitle: boolean = false;
  /**
   * 「代」计数：`open()` 里有 `await createTerminal(...)`，期间用户可能已经返回并调用
   * `close()`。不复查就会在 close 之后把 terminal/socket 又写回去（终端"复活"：
   * 远端永不 DELETE + 已销毁页面上建 WS）。close() 自增，await 前后比对即可。
   */
  private generation: number = 0;

  private constructor() {
    const self = this;
    const output: TerminalOutput = {
      write: (data: string) => {
        self.sendInput(data);
      },
      titleChanged: (title: string) => {
        self.title = title;
        self.hasTitle = true;
        self.bump();
      },
      clipboardCopy: (text: string) => {
        // OSC 52：交由页面处理（需要 pasteboard 权限）
        self.clipboardPayload = text;
        self.bump();
      },
      bell: () => {
        self.bump();
      },
      invalidate: () => {
        self.bump();
      }
    };
    // ⚠️ 这里只是**占位**默认（深色）：真正的配色由页面在 `aboutToAppear` 调
    // `applyAppearance(isDarkAppearance())` 定下来，并在外观切换时重设。
    // 修前这里硬编码 `true` 且**再没有任何地方改过** ⇒ 浅色主题下终端永远是黑底（上游
    // 是主题相关的，锚文 `SessionAgentFilesScreen.kt:745-750` 的 `applyTerminalColors`）。
    this.emulator = new TerminalEmulator(80, 24, output, true);
  }

  /**
   * 按当前外观重设 VT 配色 —— 对应上游 `applyTerminalColors(controller, darkMode)`
   * （锚文 `SessionAgentFilesScreen.kt:745-750`，在 `AndroidView.update` 里每次重组都重设）。
   *
   * 只换色表、**不重建 emulator**：行里存的是样式索引，渲染期才用色表解出具体颜色
   * （`TerminalStyle.resolveColor`），所以换掉色表再重绘即可，回看区与光标位置都不受影响
   * （重建会把 scrollback 一起丢掉）。
   */
  applyAppearance(dark: boolean): void {
    this.emulator.colorScheme = defaultColorScheme(dark);
    this.bump();
  }

  clipboardPayload: string = '';

  static get(): TerminalStore {
    if (TerminalStore.instance === undefined) {
      TerminalStore.instance = new TerminalStore();
    }
    return TerminalStore.instance;
  }

  onChange(listener: () => void): void {
    this.listeners.push(listener);
  }

  offChange(listener: () => void): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  private bump(): void {
    this.revision += 1;
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i]();
    }
  }

  get terminalTitle(): string {
    return this.hasTitle ? this.title : (this.terminal !== undefined ? this.terminal.label : '终端');
  }

  // -------------------------------------------------------------------------
  // 生命周期
  // -------------------------------------------------------------------------

  /** 新建（或复用）一个终端并开始串流。 */
  async open(deviceId: string, root: string, cols: number, rows: number, cwd: string = '.'): Promise<void> {
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    if (serverUrl.length === 0 || token.length === 0) {
      this.state = TerminalConnectionState.ERROR;
      this.error = '未登录。';
      this.bump();
      return;
    }
    if (this.terminal !== undefined && this.deviceId === deviceId && this.root === root) {
      // 复用已有终端：只重连串流
      this.resize(cols, rows);
      this.startStream();
      return;
    }
    this.close();
    // 新建终端 = 一块新屏幕：必须把**本地**仿真器也清干净。
    // close() 只销毁远端实例，仿真器里的上一轮画面会原样留着，新 shell 的提示符就
    // 追加在旧内容后面 —— 真机现象就是「每重开一次终端，多一行 PS C:\Users\...>」。
    // 同时清掉回看历史：新屏幕没有历史可回看。
    this.emulator.buffer.clearAll(0);
    const generation = this.generation;
    this.deviceId = deviceId;
    this.root = root;
    this.cwd = cwd;
    this.cols = cols;
    this.rows = rows;
    this.state = TerminalConnectionState.CREATING;
    this.error = '';
    this.bump();
    try {
      const terminal = await AppServices.get().terminal.createTerminal(
        serverUrl, token, deviceId, root, cols, rows, `hm-${Date.now()}`, cwd, 'Agents Anywhere');
      if (generation !== this.generation) {
        // 创建期间页面已关闭：把刚建的远端终端直接删掉，别让它变成孤儿。
        AppServices.get().terminal.closeTerminal(serverUrl, token, deviceId, terminal.terminalId)
          .catch((error: Object) => {
          });
        return;
      }
      this.terminal = terminal;
      this.cwd = terminal.cwd.length > 0 ? terminal.cwd : cwd;
      this.lastSeq = terminal.scrollbackSeq;
      this.emulator.resize(terminal.cols, terminal.rows);
      this.state = TerminalConnectionState.CONNECTING;
      this.statusText = `${terminal.label} · ${terminal.cols}x${terminal.rows}`;
      this.bump();
      this.startStream();
    } catch (error) {
      if (generation !== this.generation) {
        return;
      }
      this.state = TerminalConnectionState.ERROR;
      this.error = error instanceof Error ? (error as Error).message : String(error);
      this.bump();
    }
  }

  /** 关闭终端（DELETE + 断开 WS）。 */
  close(): void {
    this.generation += 1;
    this.shouldStream = false;
    if (this.reconnectTimer >= 0) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
    this.stopPing();
    const socket = this.socket;
    this.socket = undefined;
    if (socket !== undefined) {
      socket.close();
    }
    const terminal = this.terminal;
    this.terminal = undefined;
    this.state = TerminalConnectionState.IDLE;
    if (terminal !== undefined) {
      const serverUrl = readServerUrl();
      const token = readAccessToken();
      if (serverUrl.length > 0 && token.length > 0) {
        AppServices.get().terminal.closeTerminal(serverUrl, token, this.deviceId, terminal.terminalId)
          .catch((error: Object) => {
          });
      }
    }
    this.bump();
  }

  private stopPing(): void {
    if (this.pingTimer >= 0) {
      clearInterval(this.pingTimer);
      this.pingTimer = -1;
    }
  }

  private startStream(): void {
    this.shouldStream = true;
    this.connectStream();
  }

  private async connectStream(): Promise<void> {
    if (!this.shouldStream) {
      return;
    }
    const terminal = this.terminal;
    const serverUrl = readServerUrl();
    const token = readAccessToken();
    if (terminal === undefined || serverUrl.length === 0) {
      return;
    }
    this.state = TerminalConnectionState.CONNECTING;
    this.bump();
    const services = AppServices.get();
    const url = services.terminal.streamUrl(
      serverUrl, token, this.deviceId, terminal.terminalId, this.lastSeq);
    // ⚠️ 建新 socket 前必须关掉旧的：`open()` 的「复用」分支会直接 `startStream()`，
    // 不关就会有两条 WS 同时把 output 追加进同一个 emulator（画面重复错乱），
    // 而且旧引用被覆盖后再也没人能关掉它。
    const previous = this.socket;
    this.socket = undefined;
    if (previous !== undefined) {
      previous.close();
    }
    const handlers: SocketHandlers = {
      onOpen: () => {
        this.state = TerminalConnectionState.STREAMING;
        this.reconnectAttempt = 0;
        this.startPing();
        this.bump();
      },
      onText: (text: string) => {
        this.handleFrame(text);
      },
      onBinary: (data: ArrayBuffer) => {
        // 协议约定全部为 JSON 文本帧；真收到二进制就按原始 PTY 字节处理
        this.emulator.append(new Uint8Array(data));
      },
      onClosed: () => {
        if (!this.shouldStream) {
          return;
        }
        this.state = TerminalConnectionState.CONNECTING;
        this.bump();
        this.scheduleReconnect();
      },
      onError: (message: string) => {
        if (!this.shouldStream) {
          return;
        }
        this.state = TerminalConnectionState.CONNECTING;
        this.bump();
        this.scheduleReconnect();
      }
    };
    this.socket = services.realtime.openWebSocket(url, handlers);
  }

  private startPing(): void {
    if (this.pingTimer >= 0) {
      clearInterval(this.pingTimer);
    }
    this.pingTimer = setInterval(() => {
      const socket = this.socket;
      if (socket !== undefined) {
        socket.sendText(JSON.stringify({ 'type': 'ping' } as Record<string, Object>));
      }
    }, 20000);
  }

  private scheduleReconnect(): void {
    if (!this.shouldStream) {
      return;
    }
    const delay = reconnectDelayMillis(this.reconnectAttempt, Math.random());
    this.reconnectAttempt = this.reconnectAttempt < 30 ? this.reconnectAttempt + 1 : 30;
    if (this.reconnectTimer >= 0) {
      clearTimeout(this.reconnectTimer);
    }
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1;
      this.connectStream();
    }, delay);
  }

  private handleFrame(text: string): void {
    let raw: Raw;
    try {
      raw = JSON.parse(text) as Raw;
    } catch (error) {
      return;
    }
    const type = str(raw, 'type', '');
    if (type === 'replay' || type === 'output') {
      const data = optString(raw, 'data');
      const seq = optNumber(raw, 'seq');
      if (seq !== undefined) {
        this.lastSeq = seq;
      }
      if (data !== undefined) {
        try {
          this.emulator.append(base64Decode(data));
        } catch (error) {
          // 数据帧损坏：跳过
        }
      }
      if (type === 'replay') {
        this.state = TerminalConnectionState.STREAMING;
        this.statusText = `已回放至 seq ${this.lastSeq}`;
      }
      this.bump();
      return;
    }
    if (type === 'exit') {
      const exitCode = optNumber(raw, 'exitCode');
      this.exitCode = exitCode;
      this.state = TerminalConnectionState.EXITED;
      this.shouldStream = false;
      // 进程退出后 WS 上不会再有数据，但 ping 定时器不关就会每 20s 常驻发一次。
      this.stopPing();
      if (this.reconnectTimer >= 0) {
        clearTimeout(this.reconnectTimer);
        this.reconnectTimer = -1;
      }
      this.statusText = exitCode !== undefined ? `进程已退出（exit ${exitCode}）` : '进程已退出';
      this.bump();
      return;
    }
    if (type === 'error') {
      this.error = str(raw, 'message', '终端通道错误');
      this.bump();
      return;
    }
    if (type === 'pong') {
      return;
    }
  }

  // -------------------------------------------------------------------------
  // 输入
  // -------------------------------------------------------------------------

  /** 把键盘/IME 文本写回 PTY。 */
  sendInput(data: string): void {
    const socket = this.socket;
    if (socket === undefined || data.length === 0) {
      return;
    }
    const encoded = base64Encode(utf8Bytes(data));
    socket.sendText(JSON.stringify({ 'type': 'input', 'data': encoded } as Record<string, Object>));
  }

  /** 发送预先算好的转义序列（方向键、Ctrl+C 等）。 */
  sendSequence(sequence: string): void {
    if (sequence.length === 0) {
      return;
    }
    this.sendInput(sequence);
  }

  /** 终端尺寸变化（页面布局变化时调用）。 */
  resize(cols: number, rows: number): void {
    if (cols === this.cols && rows === this.rows) {
      return;
    }
    this.cols = cols;
    this.rows = rows;
    this.emulator.resize(cols, rows);
    const socket = this.socket;
    if (socket !== undefined) {
      socket.sendText(JSON.stringify({ 'type': 'resize', 'cols': cols, 'rows': rows } as Record<string, Object>));
    }
    this.bump();
  }

  /**
   * 清空终端（上游锚文：`SessionAgentFilesScreen.kt:608` 的 `TerminalClearButton`
   * → `onClear` → `TerminalScreen.kt:108` 的 `terminalController.restart(selectedDevice)`
   * → `RemoteTerminalController.kt:272` 的 `restart(device)` = `close()` + `ensureStarted(device)`）。
   *
   * ⚠️ 上游是**关闭并重建**：`close()` 先 `clearLocalScreen()` 再 DELETE 远端终端，
   * 随后重新 create 一个新的（新 terminalId、新 shell）。旧实现只清本地仿真器缓冲
   * （`emulator.buffer.clearAll`），远端 shell 的历史与状态原封不动 ——
   * 用户清了屏还能滚回去，功能不等价。
   */
  async restart(): Promise<void> {
    // 先取值：`close()` 会保留这几个字段，但取一份快照更不容易在后续改动里被踩坏。
    const deviceId = this.deviceId;
    const root = this.root;
    const cwd = this.cwd;
    const cols = this.cols;
    const rows = this.rows;
    this.close();
    // 对应上游 `close()` 里的 `clearLocalScreen()`：本地回看缓冲先清掉，
    // 免得新终端建好之前旧画面还挂在 Canvas 上。
    this.emulator.buffer.clearAll(0);
    this.bump();
    if (deviceId.length === 0) {
      return;
    }
    await this.open(deviceId, root, cols, rows, cwd);
  }
}

export { emptyRaw };
