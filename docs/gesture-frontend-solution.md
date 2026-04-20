# 手势识别前端解决方案（ArkUI / ETS）

## 1. 目标

基于 `gesture_service_api_doc.md`，当前前端首版目标不是一次性做完整识别产品，而是先把联调闭环跑通：

1. 启动时通过 `GET /health` 检查服务可用性。
2. 通过 `ws://<host>:8000/ws/gesture` 建立 WebSocket 长连接。
3. 连接成功后先发送 `start` 初始化 JSON。
4. 以 `10 FPS` 左右持续发送 `320x240` 的 JPEG 二进制帧。
5. 接收服务端 `result` / `error` 文本消息并实时反馈到界面。
6. 在前端自行完成“命中目标手势”“连续命中”“低置信度过滤”等业务判断。

## 2. 协议落点

### 2.1 HTTP 健康检查

- 地址：`GET /health`
- 用途：应用进入识别页前快速确认服务是否在线
- 预期响应：

```json
{
  "ok": true
}
```

### 2.2 WebSocket 会话

- 地址：`/ws/gesture`
- 第一个文本消息必须是：

```json
{
  "type": "start",
  "format": "jpeg",
  "width": 320,
  "height": 240,
  "fps": 10
}
```

- 后续消息为 JPEG 原始二进制帧：
  - 不包 JSON
  - 不做 base64
  - 一条消息对应一帧

### 2.3 服务端回包

识别结果：

```json
{
  "type": "result",
  "status": "predicted",
  "label": "hello",
  "confidence": 0.91,
  "validFrames": 30,
  "windowSize": 30,
  "hasValidHand": true
}
```

错误结果：

```json
{
  "type": "error",
  "message": "请先发送 start 消息"
}
```

## 3. 推荐页面方案

建议首页直接做成“联调控制台”，而不是只放一个按钮。首版页面包含 6 个区域：

1. 服务配置区
   - HTTP 地址
   - WebSocket 地址
   - 分辨率、FPS
   - 目标手势标签
2. 服务状态区
   - `health` 检测结果
   - WebSocket 连接状态
   - 最近一次错误
3. 预览区
   - 摄像头实时画面
   - 提示框：未检测到手 / 识别预热中 / 已识别
4. 结果区
   - `status`
   - `label`
   - `confidence`
   - `validFrames/windowSize`
5. 联调日志区
   - 连接建立
   - start 发送
   - 帧发送计数
   - 服务端回包
6. 业务判定区
   - 目标手势
   - 连续命中次数
   - 当前是否判定成功

## 4. 前端状态机

建议把识别流程拆成明确的前端状态，避免页面和协议逻辑耦在一起：

```text
idle
  -> checkingHealth
  -> ready
  -> connecting
  -> sendingStart
  -> streaming
  -> paused
  -> error
```

状态含义：

- `idle`：页面初始态，尚未检查服务。
- `checkingHealth`：正在请求 `/health`。
- `ready`：服务可用，可以开始识别。
- `connecting`：正在建立 WebSocket。
- `sendingStart`：WebSocket 已连上，正在发送 `start`。
- `streaming`：正在发送 JPEG 帧并接收识别结果。
- `paused`：用户主动暂停采集。
- `error`：健康检查失败、连接失败或服务端返回错误。

## 5. 模块拆分建议

建议按“页面 / 状态 / 服务 / 设备适配 / 业务判定”分层：

### 5.1 页面层

- `pages/Index.ets`
  - 只负责界面展示和交互事件绑定
  - 不直接写 WebSocket、HTTP、JPEG 编码细节

### 5.2 状态层

- `viewmodels/GestureDemoViewModel.ets`
  - 保存页面状态
  - 控制“开始识别 / 暂停 / 重连 / 清空日志”
  - 汇总服务层和设备层结果给 UI

### 5.3 服务层

- `services/gesture/HealthCheckApi.ets`
  - 调用 `/health`
- `services/gesture/GestureSocketClient.ets`
  - 建立 WebSocket
  - 发送 `start`
  - 发送二进制帧
  - 解析 `result/error`
- `services/gesture/GestureProtocol.ets`
  - 定义协议类型
  - 统一序列化和反序列化

### 5.4 设备适配层

- `services/camera/CameraFrameSource.ets`
  - 负责相机预览和取帧
- `services/camera/JpegEncoder.ets`
  - 将采集结果编码为 JPEG bytes
- `services/camera/FrameScheduler.ets`
  - 控制帧率，确保按 `80~100ms` 发送一帧

### 5.5 业务判定层

- `domain/GestureJudge.ets`
  - 根据 `status / label / confidence` 判定是否命中目标手势
  - 支持连续命中 N 次成功
  - 支持最小置信度阈值

## 6. 推荐目录结构

```text
entry/src/main/ets/
  pages/
    Index.ets
  viewmodels/
    GestureDemoViewModel.ets
  services/
    gesture/
      GestureProtocol.ets
      GestureSocketClient.ets
      HealthCheckApi.ets
    camera/
      CameraFrameSource.ets
      FrameScheduler.ets
      JpegEncoder.ets
  domain/
    GestureJudge.ets
  models/
    GestureTypes.ets
```

## 7. 协议类型建议

```ts
export interface GestureStartMessage {
  type: 'start'
  format: 'jpeg'
  width: number
  height: number
  fps: number
}

export interface GestureResultMessage {
  type: 'result'
  status: 'warming_up' | 'predicted' | 'no_hand'
  label: string
  confidence: number
  validFrames: number
  windowSize: number
  hasValidHand: boolean
}

export interface GestureErrorMessage {
  type: 'error'
  message: string
}
```

## 8. 前端业务判定建议

服务端只负责返回识别结果，前端自己做业务收口。建议首版规则：

1. `status !== 'predicted'` 直接不算命中。
2. `label !== expectedLabel` 直接不算命中。
3. `confidence < 0.8` 先视为弱命中，不触发成功。
4. 连续命中 `3` 次再判定为成功。
5. `status === 'no_hand'` 时提示“请把手放进取景框”。
6. `status === 'warming_up'` 时显示“模型预热中，请保持动作稳定”。

示例：

```ts
const isHit =
  result.status === 'predicted' &&
  result.label === expectedLabel &&
  result.confidence >= 0.8
```

## 9. 开发顺序建议

建议按下面顺序推进，联调风险最低：

1. 完成纯 UI 页面和状态展示，不接真实服务。
2. 接 `/health`，打通服务可用性探测。
3. 接 WebSocket 文本消息，只做连接和 `start`。
4. 使用本地 mock JPEG 或固定图片验证二进制发帧链路。
5. 再接真实相机采集和 JPEG 编码。
6. 最后接入业务判定、成功提示、自动重连。

## 10. 联调风险与注意点

### 10.1 `127.0.0.1` 只适用于同机环境

文档中的默认地址是：

```text
http://127.0.0.1:8000
ws://127.0.0.1:8000/ws/gesture
```

如果 HarmonyOS 应用跑在真机上，`127.0.0.1` 指向的是手机自己，不是你电脑上的 Python 服务。真机联调时要把地址改成电脑的局域网 IP，比如：

```text
http://192.168.x.x:8000
ws://192.168.x.x:8000/ws/gesture
```

### 10.2 不要在 UI 层直接控帧

发帧定时器应该交给独立的 `FrameScheduler` 管理，避免页面重建时重复启动多个定时任务。

### 10.3 相机采集和 WebSocket 发送要解耦

不要“采一帧就立即同步发送”。建议做轻量缓冲，只保留最近一帧，避免网络抖动时采集链路被拖慢。

### 10.4 首版先固定参数

首版直接固定：

- `width = 320`
- `height = 240`
- `fps = 10`

先把链路稳定住，再开放用户配置。

## 11. 这版方案在当前工程中的建议落地

当前工程还只是默认模板页，因此建议分两步：

1. 先把首页改造成“方案展示 + 联调蓝图页”。
2. 第二轮再按上面的目录拆真实的 `viewmodel / service / camera` 代码。

这样可以先统一认知，再继续往“真机采集 + WebSocket 实现”推进。
