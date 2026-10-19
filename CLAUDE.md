# AI选片（aiphoto）

摄影师自用的 Mac 原生选片与修图客户端，场景是亲子 / 家庭纪实拍摄（RAW+JPG 混拍）。仅本人自用：不需要服务器、账号、计费，也不上架。用户使用说明见 `README.md`。

产品定位（2026-10-19 用户决定）：核心是**选片 + 去杂物**，选中的照片交给像素蛋糕精修。**不再以替代像素蛋糕为目标**，不要主动推进人像精修类功能；新需求以用户实际使用中提出的小改进为主。

## 构建与运行

- 工程由 `project.yml` 通过 XcodeGen 生成，`AIPhoto.xcodeproj` 和 `AIPhoto/Info.plist` 不入库。改工程配置（Info.plist 键、签名、部署版本）只改 `project.yml`，然后重新生成。
- 生成并编译：
  ```bash
  xcodegen generate && xcodebuild -project AIPhoto.xcodeproj -scheme AIPhoto -configuration Debug -derivedDataPath build/DerivedData build
  ```
- 运行：`open -a build/DerivedData/Build/Products/Debug/AIPhoto.app <照片文件夹>`（可直接带文件夹路径打开）。
- 发版与自动更新（Sparkle 2）：`scripts/release.sh <版本号> [发布说明.md]` 改版本号、Release 编译、打 zip、签名并更新仓库根目录的 `appcast.xml`；加 `--publish` 才提交推送并创建 GitHub Release。App 从 `raw.githubusercontent.com/.../main/appcast.xml` 读更新清单，安装包下载自 Releases。EdDSA 私钥只在作者本机登录钥匙串（账户 `ed25519`），公钥在 `project.yml` 的 `SUPublicEDKey`；**私钥丢失后已安装的 App 无法再收到更新**。发版前须征得用户同意（公开发布）。
- Swift 5 语言模式，macOS 15+，本机临时签名、无沙盒、无 Hardened Runtime。`NSAllowsLocalNetworking` 已开，用于访问本机 http 服务。
- 没有单元测试。未经用户同意不要新增测试；验证方式见下文。

## 目录结构

- `AIPhoto/AppModel.swift`：唯一的 `@MainActor @Observable` 状态源，负责打开/分析/分组/AI 选片/调色/去杂物/导出等全部用户动作，以及选片记录的防抖保存。
- `AIPhoto/Core/`：不依赖界面的逻辑。
  - `PhotoScanner` 扫描配对 → `LocalAnalyzer` 本地分析（清晰度、人脸、闭眼、人体框、曝光、画面特征）→ `Culling` 分组与评分 → `AIRanker` + `VisionChatClient` AI 选片
  - `EditSettings` 非破坏性修图参数；`AutoAdjuster` 自动白平衡/曝光；`SkinRetoucher` 皮肤柔化；`StylePreset` 风格 LUT 学习与存储
  - `ChatEditor` 对话改图：把一句话换算成调色参数、要去掉的物体和要重画的区域，并校正位置；
  - `CleanupEngine` + `InpaintService` 去杂物（也用于对话改图的重画，传入指令）；`DistractionLocator` 让看图模型框出干扰物并转成画笔笔触；`PhotoRenderer` 合成修补块、套用修图、导出 JPG
  - `ViewingAids` 直方图、合焦高亮、过曝欠曝提示、拍摄参数；`AFPointReader` 解析佳能 MakerNote 的 AFInfo2 读相机对焦点
  - `XMPWriter` 星级写回；`SessionStore` 选片记录；`KeychainStore` 密钥；`ImageLoader` 读图与缓存
- `AIPhoto/Views/`：SwiftUI 界面。侧栏分组 `GroupSidebar`、大图 `PhotoViewer`（基于 `ZoomableImage`：放大平移、修复前后对比分割线、导航图）、胶片条 `Filmstrip`、右侧 `InspectorView`（内含 `ChatEntrySection`，点开后整列换成 `ChatPanel` 对话改图；以及 `ShootingInfoSection`、`CleanupSection`、`EditSection`、`RetouchLogSection`）、一键初修 `RetouchViews`、`SettingsView`。
- 需求与验收标准见 `docs/需求清单.md`，新功能先在那里确认再开发。

## 外部模型服务（用户已定，不要改动方向）

两项能力都走用户本机的 **Magpie**（OpenAI 兼容接口，`http://127.0.0.1:3425/v1`，不需要密钥）：

- **AI 选片**：`/chat/completions`，模型 `group/auto-auto`。**用户明确不用 Claude 选片，也不要通过 Magpie 代理 Claude 接口。**
- **对话改图**：`/chat/completions`，模型 `group/auto-gemini-3-8-flash`（设置可改）。需要框出物体位置，实拍对比 `group/auto-auto` 定位不准。
- **去杂物**：`/images/edits`，**模型留空**，由 Magpie 使用默认的 `codex/gpt-image-2`。`group/auto-auto` 会被路由到只回文字的模型，不出图。

## 数据与设计约束

- 原片只读。选片记录写在照片文件夹的 `.aiphoto/session.json`，去杂物的修补块写在 `.aiphoto/patches/`；风格预设写在 `~/Library/Application Support/AIPhoto/styles/`。
- 新增 `Codable` 字段必须兼容旧记录：用可选类型，或者像 `EditSettings` 那样手写 `decodeIfPresent`。
- 修图非破坏：只存参数，预览和导出时才渲染。XMP 只改 `xmp:Rating`，不覆盖 Lightroom 已写的其他内容。
- **修图底图优先用相机 JPG**，只有 RAW 没有 JPG 时才用 CIRAWFilter 解码（`Photo.editURL` / `PhotoRenderer.fullResolution`）。预览、自动调色、风格学习、导出都必须用同一底图，否则预览和导出颜色不一致。实拍验证过：CIRAWFilter 默认解码比相机 JPG 灰、反差低，在它上面自动调色容易发灰或溢出。
- 自动调色（`AutoAdjuster`）：有人脸按脸部亮度定曝光；无人脸只在场景过暗/过亮时调整；提亮受高光保护（新增死白 ≤ 2%），提不够的用阴影补；不加自然饱和度。
- 竖拍靠方向标记转正：读图一律带 transform；导出时方向写回 1。
- 去杂物：只上传涂抹区域附近的正方形局部图（最长边 1024）。gpt-image 会重画整张局部图，所以结果先按蒙版外区域校色，再只取蒙版区域羽化贴回。
- AI 选片按亲子纪实标准：哭、闭眼大笑不算废片；互动优先；全家福逐人检查；可后期去掉的干扰物不影响推荐；每组独立判断、至少推荐一张；不跨组比较。改提示词时保留这些规则。

## 二期新增的关键机制

- **撤销**：`AppModel.recordUndo` 在改动前按字段类别（选片标记 / 修图参数 / 去杂物）记录旧值，撤销时只恢复那一类字段，避免冲掉期间异步写入的 AI 结果和去杂物结果。新增会改用户字段的操作必须先调用它；滑块拖动只在开始时记一次（`beginEditChange`）。
- **放大**：`ZoomState.pixelRatio` 是"屏幕像素 / 原图像素"（1 = 100%），存在 `AppModel` 里，切换照片时保持。放大超过预览分辨率（3000）时大图改加载全尺寸。
- **后台去杂物队列**：`enqueueCleanup` 排队，最多 2 个并发，同一张照片的任务按顺序执行（后一次叠加在前一次结果上）；不使用 `perform`/`isBusy`，不占住界面。失败在队列清空时统一提示。
- **网格总览**：`gridMode` + `gridSelection`；P/X/U 在网格里作用于整批选中照片（`decisionTargets`），整批算一步撤销。
- **一键初修**：对已选照片全自动调色（手动修过的保留）、皮肤 0.25、AI 定位背景杂物后入队去除；主体相关物品只记录不去除。每张的结果写进 `Photo.retouchLog`，完成后弹初修总结。

## 踩过的坑

- **`@Observable` 独占访问崩溃**：不要在同一条语句里一边写 `photos[...]` 一边读 `photos`（例如 `photos[id]?.x = (photos[id]?.x ?? []) + [...]`）。先读到局部变量，再写回。
- **Vision 的眼部关键点几乎不随眼皮开合变化**，闭眼改为看眼部深色像素的竖直高度（`LumaPlane.darkColumnHeight`，阈值 0.18，两眼都低才算闭眼）。
- **Vision 对戴帽子的背影、小侧脸经常检测不到人脸和人体**。清晰度按"人脸 > 自身人体框 > 同组人体框 > 最清晰区块"取，保证组内用同一区域比较；表情交给 AI 判断。
- 单窗口用 `Window` 场景。`WindowGroup` 在用访达或 `open` 打开文件夹时会多开窗口。
- 不能只靠合成图验证：闭眼检测和竖拍方向问题都是换成真实照片才暴露出来的。
- 过曝提示要看"三个通道都到顶"（死白），不能用"任一通道到顶"：饱和的红色衣服、红房子会整片误报。
- **钥匙串会卡界面**：临时签名每次重新编译都会变，读钥匙串时 macOS 弹授权框，同步读取会把主线程卡住。现在只在设置里保存过密钥时才读（`KeychainStore.isSaved` 记在 UserDefaults），并在后台读（`loadIfSaved`）。Magpie 不需要密钥，不会触发读取。
- **对话改图的位置不能直接信模型**：人像修饰对齐本地人脸框，其他物体放大局部再确认（`ChatEditor.resolve`）。重画放大回原尺寸超过 3 倍不执行（`maxRedrawUpscale`），大面积改色走整体调色。
- 主窗口的快捷键挂在 `ContentView` 上，文本框有焦点时必须让出（`isEditingText`），否则在对话框里打字会触发淘汰、缩放等。
- 连拍分组：间隔 ≤ 1 秒算同一连拍；否则同场景 30 秒内、画面差异 ≤ 0.3 也归一组。
- 远处小脸 Vision 在预览图上量不到眼睛，`LocalAnalyzer.highResEyeOpenness` 会按高分辨率裁出脸部重测。
- 定位模型偶尔把围栏、树木等景物列为背景杂物，`DistractionLocator.sceneryWords` 里的景物一律保留。
- 看图模型被路由到不同模型时输出格式会变（数字写成字符串、用 `box_2d` 表示框），`DistractionLocator.parse` 做了宽容解析并重试一次。

## 验证方式

- 改动后先编译通过。核心逻辑可写临时命令行程序（`main.swift` + `AIPhoto/Core/*.swift` 一起 `swiftc`），直接调用 App 的同一份代码验证，程序和产物放在会话的临时目录，不进仓库。
- 界面用 computer-use 截图检查；画布涂抹等自定义视图需要接管屏幕，操作前先告知用户。
- 用户提供过两组实拍：`~/Desktop/raw+jpg`（佳能 R6 Mark II，6 组 CR3+JPG，含竖拍）和 `~/Desktop/raw+jpg+2`（25 张 CR3+JPG）。测试请复制到临时目录再跑，不要改动原片。

## 当前状态与待办

- 一期已完成并验收（2026-10-19），仓库：`github.com/fulisadawang/aiphoto`（2026-10-20 起公开，MIT 许可证，`main`）。仓库公开后提交作者邮箱用 GitHub noreply 地址，不要用公司邮箱；不要提交照片、密钥或本机路径。
- 二期（2026-10-20 起）按 `docs/需求清单.md` 的阶段 A～D 开发；A～D 已完成并离屏验证，界面效果待用户方便时接管屏幕一起验证。
- 待验证：在能看清孩子脸的实拍上测试皮肤柔化与闭眼检测（等用户提供照片）。
- 已知局限：风格学习对训练中没见过的场景效果明显减弱（留一验证平均误差降 28%，独立场景只降 7%），靠多样化的样片改善。
