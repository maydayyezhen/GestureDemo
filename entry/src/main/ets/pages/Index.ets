import common from '@ohos.app.ability.common'
import http from '@ohos.net.http'
import webSocket from '@ohos.net.webSocket'
import camera from '@ohos.multimedia.camera'
import image from '@ohos.multimedia.image'
import util from '@ohos.util'
import { abilityAccessCtrl } from '@kit.AbilityKit'

const BACKEND_HOST: string = '192.168.43.6'
const BACKEND_PORT: number = 8000
const TARGET_FPS: number = 12
const FRAME_WIDTH: number = 640
const FRAME_HEIGHT: number = 480
const JPEG_QUALITY: number = 80
const MAX_LOGS: number = 12
const FRAME_INTERVAL_MS: number = Math.floor(1000 / TARGET_FPS)
const WS_CLOSE_CODE: number = 1000
const WS_CLOSE_REASON: string = 'client stop'
const STATE_IDLE: string = 'idle'
const STATE_CHECKING: string = 'checking'
const STATE_CAMERA: string = 'camera'
const STATE_CONNECTING: string = 'connecting'
const STATE_STREAMING: string = 'streaming'
const CANCELLED_MESSAGE: string = '__cancelled__'

const HTTP_BASE_URL: string = `http://${BACKEND_HOST}:${BACKEND_PORT}`
const WS_URL: string = `ws://${BACKEND_HOST}:${BACKEND_PORT}/ws/gesture`

interface HealthResponse {
  ok?: boolean
}

interface GesturePoint {
  x: number
  y: number
  z?: number
}

interface GestureResultPayload {
  type: string
  status?: string
  label?: string
  confidence?: number
  validFrames?: number
  windowSize?: number
  hasValidHand?: boolean
  landmarks?: GesturePoint[] | null
  message?: string
}


interface LogItem {
  id: number
  text: string
}

function formatError(error: Object | string | undefined): string {
  if (error === undefined) {
    return 'unknown error'
  }
  if (typeof error === 'string') {
    return error
  }

  const data = error as Record<string, Object>
  const message = typeof data['message'] === 'string' ? data['message'] as string : ''
  const code = typeof data['code'] === 'number' ? `${data['code']}` : ''

  if (code.length > 0 && message.length > 0) {
    return `${code}: ${message}`
  }
  if (message.length > 0) {
    return message
  }

  const serialized = JSON.stringify(error)
  return serialized.length > 0 ? serialized : 'unknown error'
}

function buildStartPayload(width: number, height: number): string {
  return JSON.stringify({
    type: 'start',
    format: 'jpeg',
    width,
    height,
    fps: TARGET_FPS
  })
}

@Entry
@Component
struct Index {
  @State private healthState: string = '未检查'
  @State private connectionState: string = '未连接'
  @State private cameraState: string = '未启动'
  @State private serviceMessage: string = '先改顶部 IP 和端口，再点开始识别。'
  @State private previewReady: boolean = false
  @State private previewAspectRatio: number = FRAME_HEIGHT / FRAME_WIDTH
  @State private isBusy: boolean = false
  @State private isRecognizing: boolean = false
  @State private lastStatus: string = '-'
  @State private lastLabel: string = '-'
  @State private lastConfidence: string = '-'
  @State private validFrames: number = 0
  @State private windowSize: number = 0
  @State private hasValidHand: boolean = false
  @State private sentFrames: number = 0
  @State private droppedFrames: number = 0
  @State private captureErrors: number = 0
  @State private logs: LogItem[] = []
  @State private landmarks: GesturePoint[] = []
  @State private landmarksVersion: number = 0
  @State private previewAreaWidth: number = 0
  @State private previewAreaHeight: number = 0

  private previewController: XComponentController = new XComponentController()
  private decoder: util.TextDecoder = util.TextDecoder.create('utf-8', { ignoreBOM: true })
  private previewSurfaceId: string = ''
  private cameraManager: camera.CameraManager | null = null
  private cameraInput: camera.CameraInput | null = null
  private previewOutput: camera.PreviewOutput | null = null
  private captureSession: camera.Session | null = null
  private gestureSocket: webSocket.WebSocket | null = null
  private captureTimerId: number = -1
  private captureInProgress: boolean = false
  private isSendingFrame: boolean = false
  private pendingFrame: ArrayBuffer | null = null
  private activeRunId: number = 0
  private logSeed: number = 0
  private activeFrameWidth: number = FRAME_WIDTH
  private activeFrameHeight: number = FRAME_HEIGHT

  build() {
    Scroll() {
      Column({ space: 16 }) {
        this.headerCard()
        this.previewCard()
        this.controlsCard()
        this.statusCard()
        this.metricsCard()
        this.logsCard()
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 20, bottom: 28 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F4F7FB')
    .scrollBar(BarState.Off)
  }

  aboutToDisappear(): void {
    void this.stopRecognition(true)
  }

  private getAbilityContext(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext
  }

  private pushLog(message: string): void {
    const stamp = new Date().toLocaleTimeString()
    const log: LogItem = {
      id: ++this.logSeed,
      text: `${stamp}  ${message}`
    }
    this.logs = [log, ...this.logs].slice(0, MAX_LOGS)
  }

  private assertActive(runId: number): void {
    if (runId !== this.activeRunId) {
      throw new Error(CANCELLED_MESSAGE)
    }
  }

  private async ensureCameraPermission(): Promise<boolean> {
    try {
      const atManager = abilityAccessCtrl.createAtManager()
      const result = await atManager.requestPermissionsFromUser(this.getAbilityContext(), ['ohos.permission.CAMERA'])
      if (!result.authResults || result.authResults.length === 0) {
        return false
      }
      return result.authResults[0] === 0
    } catch (error) {
      this.pushLog(`权限申请失败: ${formatError(error)}`)
      return false
    }
  }

  private async checkServiceHealth(showSuccessLog: boolean = true): Promise<boolean> {
    this.healthState = '检查中'
    const request = http.createHttp()

    try {
      const response = await request.request(`${HTTP_BASE_URL}/health`, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 5000,
        readTimeout: 5000,
        usingCache: false
      })

      let payload: HealthResponse = {}
      if (typeof response.result === 'string') {
        payload = JSON.parse(response.result) as HealthResponse
      } else {
        payload = response.result as HealthResponse
      }

      const ok = response.responseCode === 200 && payload.ok === true
      this.healthState = ok ? '在线' : `异常 (${response.responseCode})`
      if (ok && showSuccessLog) {
        this.pushLog('健康检查通过')
      }
      if (!ok) {
        this.pushLog(`健康检查失败，HTTP ${response.responseCode}`)
      }
      return ok
    } catch (error) {
      const message = formatError(error)
      this.healthState = '不可达'
      this.pushLog(`健康检查异常: ${message}`)
      return false
    } finally {
      request.destroy()
    }
  }

  private selectCameraDevice(devices: camera.CameraDevice[]): camera.CameraDevice {
    const front = devices.find((item: camera.CameraDevice) =>
      item.cameraPosition === camera.CameraPosition.CAMERA_POSITION_FRONT
    )
    if (front) {
      return front
    }

    const back = devices.find((item: camera.CameraDevice) =>
      item.cameraPosition === camera.CameraPosition.CAMERA_POSITION_BACK
    )
    if (back) {
      return back
    }

    if (devices.length < 1) {
      throw new Error('没有可用相机设备')
    }
    return devices[0]
  }

  private selectPreviewProfile(profiles: camera.Profile[]): camera.Profile {
    if (profiles.length < 1) {
      throw new Error('当前相机没有可用预览档位')
    }

    let bestProfile = profiles[0]
    let bestScore = Number.MAX_VALUE

    for (let index = 0; index < profiles.length; index += 1) {
      const item = profiles[index]
      const widthGap = Math.abs(item.size.width - FRAME_WIDTH)
      const heightGap = Math.abs(item.size.height - FRAME_HEIGHT)
      const ratioGap = Math.abs((item.size.width / item.size.height) - (FRAME_WIDTH / FRAME_HEIGHT))
      const score = widthGap + heightGap + ratioGap * 1000

      if (score < bestScore) {
        bestScore = score
        bestProfile = item
      }
    }

    return bestProfile
  }

  private async startCameraPreview(runId: number): Promise<void> {
    if (this.captureSession !== null) {
      return
    }
    if (this.previewSurfaceId.length === 0) {
      throw new Error('预览组件尚未准备好，请稍后再试')
    }

    this.connectionState = '准备相机'
    this.cameraState = '启动中'

    let manager: camera.CameraManager | null = null
    let input: camera.CameraInput | null = null
    let previewProfileSize: string = ''

    let output: camera.PreviewOutput | null = null
    let session: camera.Session | null = null

    try {
      manager = camera.getCameraManager(this.getAbilityContext())
      const device = this.selectCameraDevice(manager.getSupportedCameras())
      const capability = manager.getSupportedOutputCapability(device, camera.SceneMode.NORMAL_VIDEO)
      const previewProfile = this.selectPreviewProfile(capability.previewProfiles)
      previewProfileSize = `${previewProfile.size.width}x${previewProfile.size.height}`
      this.activeFrameWidth = previewProfile.size.width
      this.activeFrameHeight = previewProfile.size.height
      this.previewAspectRatio = previewProfile.size.height / previewProfile.size.width
      input = manager.createCameraInput(device)

      await input.open()
      this.assertActive(runId)

      output = manager.createPreviewOutput(previewProfile, this.previewSurfaceId)
      session = manager.createSession<camera.Session>(camera.SceneMode.NORMAL_VIDEO)
      session.beginConfig()

      if (!session.canAddInput(input)) {
        throw new Error('相机输入无法加入会话')
      }
      session.addInput(input)

      if (!session.canAddOutput(output)) {
        throw new Error('预览输出无法加入会话')
      }
      session.addOutput(output)
      await session.commitConfig()
      this.assertActive(runId)

      await session.start()
      this.assertActive(runId)

      this.cameraManager = manager
      this.cameraInput = input
      this.previewOutput = output
      this.captureSession = session
      this.cameraState = `运行中 ${previewProfileSize}`
      this.pushLog(`相机预览已启动 (${previewProfileSize})`)
    } catch (error) {
      if (session !== null) {
        try {
          await session.release()
        } catch (_releaseError) {
        }
      }
      if (output !== null) {
        try {
          await output.release()
        } catch (_releaseError) {
        }
      }
      if (input !== null) {
        try {
          await input.close()
        } catch (_closeError) {
        }
      }
      this.cameraState = '启动失败'
      throw new Error(formatError(error))
    }
  }

  private async connectGestureSocket(runId: number): Promise<void> {
    this.connectionState = '连接服务中'

    const socket = webSocket.createWebSocket()
    socket.on('message', (_error, data) => {
      if (this.gestureSocket !== socket) {
        return
      }
      this.handleSocketMessage(data)
    })
    socket.on('close', (_error, detail) => {
      if (this.gestureSocket !== socket) {
        return
      }
      this.pushLog(`WebSocket 已关闭 (${detail.code}: ${detail.reason})`)
      void this.stopRecognition(true, `连接已关闭: ${detail.reason}`)
    })
    socket.on('error', (error) => {
      if (this.gestureSocket !== socket) {
        return
      }
      const message = formatError(error)
      this.pushLog(`WebSocket 错误: ${message}`)
      void this.stopRecognition(true, `连接异常: ${message}`)
    })

    try {
      await socket.connect(WS_URL)
      this.assertActive(runId)
      this.gestureSocket = socket
      this.connectionState = '发送 start 中'
      await socket.send(buildStartPayload(this.activeFrameWidth, this.activeFrameHeight))
      this.assertActive(runId)
    } catch (error) {
      try {
        socket.off('message')
        socket.off('close')
        socket.off('error')
      } catch (_offError) {
      }
      try {
        await socket.close({ code: WS_CLOSE_CODE, reason: WS_CLOSE_REASON })
      } catch (_closeError) {
      }
      throw new Error(formatError(error))
    }

    this.pushLog('WebSocket 已连接并发送 start')
  }

  private handleSocketMessage(data: string | ArrayBuffer): void {
    let raw = ''

    try {
      raw = typeof data === 'string' ? data : this.decoder.decodeToString(new Uint8Array(data))
      const payload = JSON.parse(raw) as GestureResultPayload

      if (payload.type === 'result') {
        this.lastStatus = payload.status ?? '-'
        this.lastLabel = payload.label ?? '-'
        this.lastConfidence = payload.confidence === undefined ? '-' : `${(payload.confidence * 100).toFixed(1)}%`
        this.validFrames = payload.validFrames ?? 0
        this.windowSize = payload.windowSize ?? 0
        this.hasValidHand = payload.hasValidHand ?? false
        const source = payload.landmarks ?? []
        this.landmarks = source.map((item: GesturePoint): GesturePoint => {
          return {
            x: item.x,
            y: item.y,
            z: item.z
          }
        })
        this.landmarksVersion += 1
        this.landmarksVersion += 1
        this.serviceMessage = this.describeResult(payload)
        return
      }

      if (payload.type === 'error') {
        const message = payload.message ?? '服务端返回错误'
        this.pushLog(`服务端错误: ${message}`)
        this.serviceMessage = message
        return
      }

      this.pushLog(`收到未识别消息: ${raw}`)
    } catch (error) {
      this.pushLog(`解析消息失败: ${formatError(error)}`)
    }
  }

  private describeResult(payload: GestureResultPayload): string {
    switch (payload.status) {
      case 'warming_up':
        return `模型预热中，当前有效帧 ${payload.validFrames ?? 0} / ${payload.windowSize ?? 30}`
      case 'no_hand':
        return '未检测到手，请把手放进取景区域'
      case 'predicted':
        return `识别结果 ${payload.label ?? '-'}，置信度 ${payload.confidence === undefined ? '-' : `${(payload.confidence * 100).toFixed(1)}%`}`
      default:
        return '等待服务端结果'
    }
  }

  private startFrameLoop(): void {
    this.stopFrameLoop()
    this.captureTimerId = setInterval(() => {
      void this.captureCurrentFrame()
    }, FRAME_INTERVAL_MS)
  }

  private stopFrameLoop(): void {
    if (this.captureTimerId >= 0) {
      clearInterval(this.captureTimerId)
      this.captureTimerId = -1
    }
  }

  private async captureCurrentFrame(): Promise<void> {
    if (!this.isRecognizing || this.gestureSocket === null || this.previewSurfaceId.length === 0) {
      return
    }
    if (this.captureInProgress) {
      return
    }

    this.captureInProgress = true
    let sourceMap: image.PixelMap | null = null
    let packer: image.ImagePacker | null = null

    try {
      sourceMap = await image.createPixelMapFromSurface(this.previewSurfaceId)
      const info = sourceMap.getImageInfoSync()
      this.activeFrameWidth = info.size.width
      this.activeFrameHeight = info.size.height

      packer = image.createImagePacker()
      const jpegBytes = await packer.packToData(sourceMap, {
        format: 'image/jpeg',
        quality: JPEG_QUALITY,
        bufferSize: info.size.width * info.size.height * 4
      })

      this.enqueueFrame(jpegBytes)
    } catch (error) {
      this.captureErrors += 1
      this.pushLog(`抓帧失败: ${formatError(error)}`)
    } finally {
      if (packer !== null) {
        try {
          await packer.release()
        } catch (_releaseError) {
        }
      }
      if (sourceMap !== null) {
        try {
          await sourceMap.release()
        } catch (_releaseError) {
        }
      }
      this.captureInProgress = false
    }
  }

  private enqueueFrame(frame: ArrayBuffer): void {
    if (this.pendingFrame !== null) {
      this.droppedFrames += 1
    }
    this.pendingFrame = frame
    void this.flushPendingFrame()
  }

  private async flushPendingFrame(): Promise<void> {
    if (this.isSendingFrame || this.pendingFrame === null || this.gestureSocket === null || !this.isRecognizing) {
      return
    }

    const frame = this.pendingFrame
    const socket = this.gestureSocket
    this.pendingFrame = null
    this.isSendingFrame = true

    try {
      await socket.send(frame)
      this.sentFrames += 1
      this.connectionState = '持续发送中'
    } catch (error) {
      this.pushLog(`发送帧失败: ${formatError(error)}`)
      void this.stopRecognition(true, '发送帧失败，已停止')
    } finally {
      this.isSendingFrame = false
      if (this.pendingFrame !== null) {
        void this.flushPendingFrame()
      }
    }
  }

  private resetRuntimeMetrics(): void {
    this.lastStatus = '-'
    this.lastLabel = '-'
    this.lastConfidence = '-'
    this.validFrames = 0
    this.windowSize = 0
    this.hasValidHand = false
    this.sentFrames = 0
    this.droppedFrames = 0
    this.captureErrors = 0
  }

  private async startRecognition(): Promise<void> {
    if (this.isBusy || this.isRecognizing) {
      return
    }

    this.isBusy = true
    const runId = ++this.activeRunId
    this.resetRuntimeMetrics()
    this.connectionState = '启动中'
    this.serviceMessage = '正在准备服务连接和相机预览...'
    this.pushLog(`开始识别，目标 ${TARGET_FPS} FPS / ${FRAME_WIDTH}x${FRAME_HEIGHT}`)

    try {
      const healthOk = await this.checkServiceHealth()
      this.assertActive(runId)
      if (!healthOk) {
        throw new Error('后端服务不可用，请确认 Python 服务和局域网地址')
      }

      const permissionOk = await this.ensureCameraPermission()
      this.assertActive(runId)
      if (!permissionOk) {
        throw new Error('未获得相机权限')
      }

      await this.startCameraPreview(runId)
      this.assertActive(runId)

      await this.connectGestureSocket(runId)
      this.assertActive(runId)

      this.isRecognizing = true
      this.connectionState = '识别中'
      this.serviceMessage = '识别已启动，正在持续采集并发送最新帧'
      this.startFrameLoop()
    } catch (error) {
      const message = formatError(error)
      if (message !== CANCELLED_MESSAGE) {
        this.pushLog(`启动失败: ${message}`)
        this.serviceMessage = message
      }
      await this.stopRecognition(true, message === CANCELLED_MESSAGE ? '已取消' : this.serviceMessage)
    } finally {
      this.isBusy = false
    }
  }

  private async stopRecognition(silent: boolean = false, message: string = '识别已停止'): Promise<void> {
    this.activeRunId += 1
    this.stopFrameLoop()
    this.pendingFrame = null
    this.captureInProgress = false
    this.isSendingFrame = false
    this.landmarks = []
    this.landmarksVersion += 1

    const socket = this.gestureSocket
    this.gestureSocket = null
    if (socket !== null) {
      try {
        socket.off('message')
        socket.off('close')
        socket.off('error')
      } catch (_offError) {
      }
      try {
        await socket.close({ code: WS_CLOSE_CODE, reason: WS_CLOSE_REASON })
      } catch (_closeError) {
      }
    }

    const session = this.captureSession
    this.captureSession = null
    if (session !== null) {
      try {
        await session.stop()
      } catch (_stopError) {
      }
      try {
        await session.release()
      } catch (_releaseError) {
      }
    }

    const output = this.previewOutput
    this.previewOutput = null
    if (output !== null) {
      try {
        await output.release()
      } catch (_releaseError) {
      }
    }

    const input = this.cameraInput
    this.cameraInput = null
    if (input !== null) {
      try {
        await input.close()
      } catch (_closeError) {
      }
    }

    this.cameraManager = null
    this.isRecognizing = false
    this.connectionState = '未连接'
    this.cameraState = this.previewReady ? '未启动' : '等待预览面'
    this.serviceMessage = message

    if (!silent) {
      this.pushLog(message)
    }
  }

  private async manualHealthCheck(): Promise<void> {
    if (this.isBusy) {
      return
    }
    this.isBusy = true
    try {
      const ok = await this.checkServiceHealth()
      this.serviceMessage = ok ? '后端服务在线，可以开始识别' : '后端服务不可达'
    } finally {
      this.isBusy = false
    }
  }

  private handlePreviewLoaded(): void {
    try {
      this.previewSurfaceId = this.previewController.getXComponentSurfaceId()
      this.previewReady = this.previewSurfaceId.length > 0
      this.cameraState = this.previewReady ? '等待启动' : '预览面不可用'
      if (this.previewReady) {
        this.pushLog(`预览面已就绪: ${this.previewSurfaceId}`)
      }
    } catch (error) {
      this.previewReady = false
      this.cameraState = '预览面初始化失败'
      this.pushLog(`预览面初始化失败: ${formatError(error)}`)
    }
  }

  @Builder
  private headerCard() {
    Column({ space: 12 }) {
      Text('Gesture Service Console')
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')

      Text('这页已经不是蓝图，当前会直接做健康检查、拉起相机预览、建立 WebSocket，并按 10 FPS 发送最新 JPEG 帧。')
        .fontSize(13)
        .lineHeight(20)
        .fontColor('#D7E5F7')

      Row({ space: 10 }) {
        this.configPill('Host', BACKEND_HOST)
        this.configPill('Port', `${BACKEND_PORT}`)
      }
      .width('100%')

      Row({ space: 10 }) {
        this.configPill('HTTP', HTTP_BASE_URL)
        this.configPill('WS', WS_URL)
      }
      .width('100%')

      Row({ space: 10 }) {
        this.configPill('FPS', `${TARGET_FPS}`)
        this.configPill('Frame', `${FRAME_WIDTH} x ${FRAME_HEIGHT}`)
      }
      .width('100%')
    }
    .width('100%')
    .padding(18)
    .backgroundColor('#11233D')
    .borderRadius(28)
  }

  @Builder
  private configPill(label: string, value: string) {
    Column({ space: 4 }) {
      Text(label)
        .fontSize(11)
        .fontColor('#9CB3D5')

      Text(value)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .backgroundColor('#1D355A')
    .borderRadius(16)
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private previewCard() {
    Column({ space: 12 }) {
      Row() {
        Text('相机预览')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#17324D')

        Blank()

        Text(this.previewReady ? 'Surface 就绪' : '等待 Surface')
          .fontSize(12)
          .fontColor(this.previewReady ? '#047857' : '#B45309')
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .backgroundColor(this.previewReady ? '#DCFCE7' : '#FEF3C7')
          .borderRadius(14)
      }
      .width('100%')

      Stack({ alignContent: Alignment.Center }) {
        XComponent({
          id: 'gesture-preview',
          type: XComponentType.SURFACE,
          controller: this.previewController
        })
          .width('100%')
          .aspectRatio(this.previewAspectRatio)
          .backgroundColor('#09111C')
          .borderRadius(24)
          .onLoad(() => {
            this.handlePreviewLoaded()
          })

        // // 点位覆盖层
        // Stack() {
        //   ForEach(this.landmarks, (point: GesturePoint, index: number) => {
        //     Row()
        //       .width(10)
        //       .height(10)
        //       .borderRadius(5)
        //       .backgroundColor('#00FF66')
        //       .position({
        //         x: point.x * this.previewAreaWidth - 5,
        //         y: point.y * this.previewAreaHeight - 5
        //       })
        //   }, (_point: GesturePoint, index: number) => `${index}-${this.landmarksVersion}`)
        // }
        // .width('100%')
        // .aspectRatio(this.previewAspectRatio)
        // .hitTestBehavior(HitTestMode.None)

        if (!this.previewReady) {
          Column({ space: 8 }) {
            Text('预览面初始化中')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')

            Text('XComponent Surface 准备好后，开始识别会自动拉起相机')
              .fontSize(12)
              .fontColor('#CBD5E1')
          }
        }
      }
      .width('100%')
      .onAreaChange((_oldValue, newValue) => {
        this.previewAreaWidth = Number(newValue.width)
        this.previewAreaHeight = Number(newValue.height)
      })

      Text(this.serviceMessage)
        .width('100%')
        .fontSize(13)
        .lineHeight(20)
        .fontColor('#526579')
    }
    .width('100%')
    .padding(18)
    .backgroundColor('#FFFFFF')
    .borderRadius(28)
  }

  @Builder
  private controlsCard() {
    Column({ space: 12 }) {
      Text('控制')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor('#17324D')

      Button(this.isBusy ? '处理中...' : '开始识别')
        .width('100%')
        .height(46)
        .enabled(!this.isBusy && !this.isRecognizing)
        .backgroundColor('#0F766E')
        .fontColor('#FFFFFF')
        .fontSize(16)
        .borderRadius(18)
        .onClick(() => {
          void this.startRecognition()
        })

      Button('检查服务')
        .width('100%')
        .height(44)
        .enabled(!this.isBusy)
        .backgroundColor('#E8EEF8')
        .fontColor('#20446A')
        .fontSize(15)
        .borderRadius(18)
        .onClick(() => {
          void this.manualHealthCheck()
        })

      Button('停止识别')
        .width('100%')
        .height(44)
        .enabled(this.isRecognizing || this.isBusy)
        .backgroundColor('#FFF1EC')
        .fontColor('#C2410C')
        .fontSize(15)
        .borderRadius(18)
        .onClick(() => {
          void this.stopRecognition()
        })
    }
    .width('100%')
    .padding(18)
    .backgroundColor('#FFFFFF')
    .borderRadius(28)
  }

  @Builder
  private statusCard() {
    Column({ space: 12 }) {
      Text('运行状态')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor('#17324D')

      this.statusRow('健康检查', this.healthState)
      this.statusRow('连接状态', this.connectionState)
      this.statusRow('相机状态', this.cameraState)
      this.statusRow('服务状态', this.lastStatus)
      this.statusRow('识别标签', this.lastLabel)
      this.statusRow('置信度', this.lastConfidence)
      this.statusRow('有效手势', this.hasValidHand ? '是' : '否')
    }
    .width('100%')
    .padding(18)
    .backgroundColor('#FFFFFF')
    .borderRadius(28)
  }

  @Builder
  private statusRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontColor('#6A7F95')

      Blank()

      Text(value)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor('#17324D')
    }
    .width('100%')
  }

  @Builder
  private metricsCard() {
    Column({ space: 12 }) {
      Text('发送指标')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor('#17324D')

      Row({ space: 10 }) {
        this.metricBlock('已发送帧', `${this.sentFrames}`)
        this.metricBlock('覆盖丢帧', `${this.droppedFrames}`)
      }
      .width('100%')

      Row({ space: 10 }) {
        this.metricBlock('抓帧错误', `${this.captureErrors}`)
        this.metricBlock('有效帧窗口', `${this.validFrames}/${this.windowSize}`)
      }
      .width('100%')
    }
    .width('100%')
    .padding(18)
    .backgroundColor('#FFFFFF')
    .borderRadius(28)
  }

  @Builder
  private metricBlock(label: string, value: string) {
    Column({ space: 6 }) {
      Text(label)
        .fontSize(12)
        .fontColor('#7087A0')

      Text(value)
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor('#17324D')
    }
    .layoutWeight(1)
    .padding({ left: 14, right: 14, top: 14, bottom: 14 })
    .backgroundColor('#F6F9FC')
    .borderRadius(20)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private logsCard() {
    Column({ space: 12 }) {
      Text('最近日志')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor('#17324D')

      if (this.logs.length === 0) {
        Text('还没有日志，点击“开始识别”后会在这里显示联调过程。')
          .fontSize(13)
          .lineHeight(20)
          .fontColor('#6A7F95')
      } else {
        ForEach(this.logs, (item: LogItem) => {
          Text(item.text)
            .width('100%')
            .fontSize(12)
            .lineHeight(18)
            .fontColor('#D7E3F4')
            .padding({ left: 12, right: 12, top: 10, bottom: 10 })
            .backgroundColor('#17304B')
            .borderRadius(16)
        }, (item: LogItem) => item.id.toString())
      }
    }
    .width('100%')
    .padding(18)
    .backgroundColor('#FFFFFF')
    .borderRadius(28)
  }
}
