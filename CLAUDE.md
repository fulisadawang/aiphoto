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
- Swift 5 语言模式，macOS 15+，本机临时签名、无沙盒、无 Hardened Runtime。`NSAllowsLocalNetworking` 已开，用于访问本机 http 服务。
- 没有单元测试。未经用户同意不要新增测试；验证方式见下文。

## 目录结构

- `AIPhoto/AppModel.swift`：唯一的 `@MainActor @Observable` 状态源，负责打开/分析/分组/AI 选片/调色/去杂物/导出等全部用户动作，以及选片记录的防抖保存。
- `AIPhoto/Core/`：不依赖界面的逻辑。
  - `PhotoScanner` 扫描配对 → `LocalAnalyzer` 本地分析（清晰度、人脸、闭眼、人体框、曝光、画面特征）→ `Culling` 分组与评分 → `AIRanker` + `VisionChatClient` AI 选片
  - `EditSettings` 非破坏性修图参数；`AutoAdjuster` 自动白平衡/曝光；`SkinRetoucher` 皮肤柔化；`StylePreset` 风格 LUT 学习与存储
  - `CleanupEngine` + `InpaintService` 去杂物；`PhotoRenderer` 合成修补块、套用修图、导出 JPG
  - `XMPWriter` 星级写回；`SessionStore` 选片记录；`KeychainStore` 密钥；`ImageLoader` 读图与缓存
- `AIPhoto/Views/`：SwiftUI 界面。侧栏分组 `GroupSidebar`、大图 `PhotoViewer`（含画笔层）、胶片条 `Filmstrip`、右侧 `InspectorView`（内含 `CleanupSection`、`EditSection`）、`SettingsView`。

## 外部模型服务（用户已定，不要改动方向）

两项能力都走用户本机的 **Magpie**（OpenAI 兼容接口，`http://127.0.0.1:3425/v1`，不需要密钥）：

- **AI 选片**：`/chat/completions`，模型 `group/auto-auto`。**用户明确不用 Claude 选片，也不要通过 Magpie 代理 Claude 接口。**
- **去杂物**：`/images/edits`，**模型留空**，由 Magpie 使用默认的 `codex/gpt-image-2`。`group/auto-auto` 会被路由到只回文字的模型，不出图。

## 数据与设计约束

- 原片只读。选片记录写在照片文件夹的 `.aiphoto/session.json`，去杂物的修补块写在 `.aiphoto/patches/`；风格预设写在 `~/Library/Application Support/AIPhoto/styles/`。
- 新增 `Codable` 字段必须兼容旧记录：用可选类型，或者像 `EditSettings` 那样手写 `decodeIfPresent`。
- 修图非破坏：只存参数，预览和导出时才渲染。XMP 只改 `xmp:Rating`，不覆盖 Lightroom 已写的其他内容。
- **有 RAW 的照片，修图底图统一用 CIRAWFilter 解码**（`ImageLoader.editBase` / `Photo.editURL`）。预览、自动调色、风格学习、导出都必须用同一底图，否则预览和导出颜色不一致。仅浏览时用相机 JPG（快）。
- 竖拍靠方向标记转正：读图一律带 transform；导出时方向写回 1。
- 去杂物：只上传涂抹区域附近的正方形局部图（最长边 1024）。gpt-image 会重画整张局部图，所以结果先按蒙版外区域校色，再只取蒙版区域羽化贴回。
- AI 选片按亲子纪实标准：哭、闭眼大笑不算废片；互动优先；全家福逐人检查；可后期去掉的干扰物不影响推荐；每组独立判断、至少推荐一张；不跨组比较。改提示词时保留这些规则。

## 踩过的坑

- **`@Observable` 独占访问崩溃**：不要在同一条语句里一边写 `photos[...]` 一边读 `photos`（例如 `photos[id]?.x = (photos[id]?.x ?? []) + [...]`）。先读到局部变量，再写回。
- **Vision 的眼部关键点几乎不随眼皮开合变化**，闭眼改为看眼部深色像素的竖直高度（`LumaPlane.darkColumnHeight`，阈值 0.18，两眼都低才算闭眼）。
- **Vision 对戴帽子的背影、小侧脸经常检测不到人脸和人体**。清晰度按"人脸 > 自身人体框 > 同组人体框 > 最清晰区块"取，保证组内用同一区域比较；表情交给 AI 判断。
- 单窗口用 `Window` 场景。`WindowGroup` 在用访达或 `open` 打开文件夹时会多开窗口。
- 不能只靠合成图验证：闭眼检测和竖拍方向问题都是换成真实照片才暴露出来的。

## 验证方式

- 改动后先编译通过。核心逻辑可写临时命令行程序（`main.swift` + `AIPhoto/Core/*.swift` 一起 `swiftc`），直接调用 App 的同一份代码验证，程序和产物放在会话的临时目录，不进仓库。
- 界面用 computer-use 截图检查；画布涂抹等自定义视图需要接管屏幕，操作前先告知用户。
- 用户提供过一组实拍：`~/Desktop/raw+jpg`（佳能 R6 Mark II，6 组 CR3+JPG，含竖拍）。测试会在其中生成 `.aiphoto/`，不要改动原片。

## 当前状态与待办

- 一期已完成并验收（2026-10-19），仓库：`github.com/fulisadawang/aiphoto`（私有，`main`）。
- 待验证：在能看清孩子脸的实拍上测试皮肤柔化与闭眼检测（等用户提供照片）。
- 已知局限：风格学习对训练中没见过的场景效果明显减弱（留一验证平均误差降 28%，独立场景只降 7%），靠多样化的样片改善。
