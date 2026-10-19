# 轻贴 macOS PROJECT_MAP

> 单体 macOS 应用速查地图。找文件查「模块文件地图」，理流程查「场景剧本」，改需求查「改动影响链」，调 Bug 查「症状定位表」。代码位置以文件和类型 / 函数名标注，行号会随修改漂移。

---

## 一、项目总览

| 项目 | 内容 |
| --- | --- |
| 形态 | 菜单栏常驻的本地剪贴板管理器（`LSUIElement`），无服务端、无云同步 |
| 源码 | `Sources/LightPaste/`，单个 Swift Package 可执行目标 `LightPaste` |
| 技术栈 | Swift 5 语言模式（本机 Swift 6.2 工具链）、AppKit + SwiftUI、SQLite3（系统库）、CryptoKit、Vision、LinkPresentation、QuickLookThumbnailing、ServiceManagement、Carbon 热键 |
| 最低系统 | macOS 13 |
| 构建 | `./build.sh`：`swift build -c release`，组装 `轻贴.app` 并临时签名；设 `LIGHTPASTE_SIGN_IDENTITY` / `LIGHTPASTE_NOTARY_PROFILE` 时改为 Developer ID 签名并公证；只需 Command Line Tools |
| 版本 | `build.sh` 顶部 `APP_VERSION` / `APP_BUILD`（当前 0.6.0 / 6），与 CHANGELOG 一致 |
| Bundle ID | `com.local.lightpaste` |
| 数据目录 | `~/Library/Application Support/LightPaste/`（目录 0700，数据库及 -wal/-shm 0600） |
| 安装位置 | `/Applications/轻贴.app`（本机） |

---

## 二、业务术语词典

| 业务说法 | 代码类型 | 存储 | 关键字段 |
| --- | --- | --- | --- |
| 历史条目 / 卡片 | `ClipItem` | 表 `clips` | `id`、`kind`、`title`、`text`（摘要，最多 131,072 字符）、`last_copied_at`、`is_favorite` |
| 原始载荷（多格式） | `[ClipboardEntry]` → `ClipboardRepresentation(type, data)` | `clips.payload`（二进制 plist） | 每个剪贴板项的各格式原始字节 |
| 内容类型 | `ClipKind` | `clips.kind` | text / link / image / files / other |
| 智能识别 | `ClipDetail` | `clips.detail_kind` | color / code / phone / email / otp / sensitive |
| 去重指纹 | `HistoryStore.fingerprint` | `clips.fingerprint`（UNIQUE） | 全部载荷的 SHA-256 |
| 过期时间 | `ClipItem.expiresAt` | `clips.expires_at` | 验证码 5 分钟；敏感内容默认 10 分钟；收藏不过期 |
| 图片文字 | `ClipItem.ocrText` | `clips.ocr_text` | 空串表示已识别但无文字 |
| 链接标题 / 图标 | `ClipItem.linkTitle` | `clips.link_title`、表 `link_icons(clip_id, png)` | 空串表示抓取失败，不再重试 |
| 收藏分类 | `FavoriteBoard` | 表 `boards`、`board_membership(clip_id, board_id)` | 删除分类保留内容与收藏 |
| 一次采集 | `CapturedClip` → `HistoryStore.PreparedCapture` | — | 采集中间态：摘要、指纹、识别结果、编码后载荷 |
| 筛选 | `SidebarFilter`、`DateFilter`、来源 `sourceFilter` | 内存 | 日期按最近复制时间 |
| 常用文本变量 | `SnippetExpander` | — | `{日期}` `{时间}` `{剪贴板}` `{光标}`，仅轻贴内新建的文本展开 |
| 唤起快捷键 | `HotKeySpec` | 偏好 `hotKeyCode` / `hotKeyModifiers` | 默认 ⌥Space |
| 搜索语法 | `SearchQuery`（Models.swift） | — | `app:` `type:` `date:` `is:收藏`；未识别的值被忽略 |
| 拼音索引 | `HistoryStore.pinyinKeys`、`PinyinTable` | 内存（并入 `searchHaystacks`） | 全拼与首字母，按单字缓存 |
| 粘贴为 | `TextTransform` | — | 去空白、单行、大小写、JSON、去跟踪参数、颜色格式 |
| 收藏备份 | `HistoryStore.FavoritesArchive` | `.lightpaste` 文件（二进制 plist） | 收藏、分类、原始载荷；按指纹去重 |
| 复制来源 | `ClipboardMonitor.Source` | `clips.source_*` | 最近一次观察到的前台应用，切换时先检查剪贴板 |

---

## 三、模块文件地图（`Sources/LightPaste/`）

| 模块 | 文件 | 主要类型 / 职责 |
| --- | --- | --- |
| 启动 | `Launch.swift` | `@main`、`AppDelegate`：选数据目录（支持 `LIGHTPASTE_DATA_DIR`）、建主菜单、创建 `AppController` |
| 应用中枢 | `AppController.swift` | 全部界面状态（`@Published`）、选择与多选、筛选、粘贴 / 按顺序粘贴、收藏分类、编辑 / 副本 / 打开 / 共享、暂停、设置保存、抽屉窗口与键盘路由（`handleKey`）、菜单栏、后台补充调度（`scheduleEnrichment`、`runNextOCR`）、定时清理 |
| 剪贴板采集 | `ClipboardMonitor.swift` | 0.6 秒轮询 `changeCount`；`readEntries`（主线程读原始数据）、`clip(from:)`（解析摘要与类型）、`fullText`、私密格式过滤、串行采集队列 |
| 数据存储 | `HistoryStore.swift` | `HistoryStore`（主连接、内存列表、搜索索引、收藏分类、清理、迁移）；`CaptureWriter`（采集队列上的第二连接，只插入新条目） |
| 后台资源 | `ClipResources.swift` | `actor`，独立只读连接读取载荷：缩略图、OCR 用图、拖出导出数据 |
| 内容识别 | `ContentDetector.swift` | 密钥 / 银行卡 / 身份证（全文扫描，文本与链接）、验证码、颜色、邮箱、电话、代码语言；`SnippetExpander` |
| 粘贴转换 | `TextTransform.swift` | “粘贴为”的各项转换，纯 Foundation |
| 联网与图标 | `Enrichment.swift` | `OCRService`（Vision）、`LinkPreviewService`（LPMetadataProvider；`allowsAutomaticFetch` 自动预览规则）、`IconProvider`（应用图标、主色、Quick Look 缩略图） |
| 抽屉界面 | `DrawerView.swift` | 工具栏（分类标签、筛选菜单、搜索框）、底栏 / 批量栏、`DrawerClipCard`（卡片内容，Equatable） |
| 卡片条 | `NativeCardStrip.swift` | `NSCollectionView` 单行横排、按类型复用单元格、增量插删、选中居中滚动 |
| 卡片交互 | `NativeCardInteraction.swift` | 卡片上的透明 AppKit 层：单 / 双击、⌘ / ⇧ 多选、拖出、右键菜单 |
| 分类拖入 | `NativeBoardInteraction.swift` | 分类标签的拖放目标 |
| 系统服务 | `SystemServices.swift` | `HotKeyManager`、`HotKeySpec`、`ClipboardWindow`（抽屉面板，拦截按键）、`PasteService`（写剪贴板、模拟 ⌘V、焦点检测） |
| 编辑窗口 | `ItemEditor.swift` | `ItemEditorController`：富文本编辑、写作工具、保存为 RTF + 纯文本 |
| 预览 | `ItemPreviewView.swift` | 空格预览窗口内容 |
| 设置 / 引导 | `Views.swift` | `SettingsView`、`ShortcutRecorder`、`ExcludedAppsPicker`、`OnboardingView` |
| 文本样式 | `TextStyling.swift` | 搜索高亮与摘录、代码着色、`CodeLanguageCache`、`CardTime` |
| 设计令牌 | `DesignTokens.swift` | `DS` 字号、间距、圆角、颜色、动效；`KeyCap`、图标按钮样式 |
| 几何 | `DrawerGeometry.swift` | `DrawerEdge`、`CardSize`、抽屉显示 / 隐藏帧计算 |
| 提示 | `FeedbackHUD.swift` | 屏幕下方的短暂结果提示 |
| 模型 | `Models.swift` | 上表中的数据类型与筛选枚举 |

脚本与文档：

| 文件 | 用途 |
| --- | --- |
| `build.sh` | Release 构建、生成 Info.plist、图标、临时签名 |
| `Scripts/VerifyCore.swift` | 存储核心 30 项（去重、持久化、迁移、收藏、清理、搜索、编辑、副本、后台写入、排除应用时序、敏感全文扫描、拼音与搜索语法、收藏导出导入） |
| `Scripts/VerifyDetection.swift` | 内容识别、链接预览规则与粘贴转换 65 项 |
| `Scripts/VerifyResources.swift` | 后台资源 5 项 |
| `Scripts/VerifyInteractions.swift` | 原生交互处理 8 项（自带精简 `AppController` 替身） |
| `Scripts/VerifyDrawer.swift` | 抽屉几何 45 种配置 |
| `Scripts/BenchPerformance.swift` | 合成数据性能基线（启动、采集、搜索、方向键、逐字输入） |
| `Scripts/MakeIcon.swift`、`PackIcon.py` | 生成应用图标 |
| `Tests/LightPasteTests/HistoryTests.swift` | XCTest 版本（需完整 Xcode） |
| `README.md` | 使用说明、数据范围、验证命令、性能基线 |

---

## 四、场景剧本

### 场景 A：复制后进入历史

```
[其他应用] 用户复制
  ↓ ClipboardMonitor.poll()（主线程，0.6 秒定时器；切换应用时 applicationDidActivate 先 poll 再更新来源）
      ├─ changeCount 未变 / 已暂停 → 结束
      ├─ 最近观察到的前台应用在排除列表 → 结束；定时器路径另查当前前台应用，任一被排除即不记录
      └─ readEntries()：发现 concealed / transient 等私密格式 → 结束；超过 20 MB → 报错
  ↓ captureQueue（串行，后台）
      ├─ ClipboardMonitor.clip(from:)：纯文本 > RTF > HTML 选摘要，判定 kind、标题；全部文字表示（含 HTML 原文、链接）扫描密钥 → containsSecret
      ├─ HistoryStore.prepare()：SHA-256 指纹、containsSecret ? .sensitive : ContentDetector.detect、plist 编码
      └─ CaptureWriter.write()：指纹已存在 → needsMainThread；否则 INSERT 新行并建好搜索索引
  ↓ 主线程
      ├─ .written → HistoryStore.adoptCapture()：行仍在库中才并入列表，按上限清理
      └─ .needsMainThread → HistoryStore.capture()：更新已有条目时间与来源（或冲突回退插入）
  ↓ store.objectWillChange → AppController.refreshResults() + scheduleEnrichment()
```

### 场景 B：唤起抽屉并粘贴

```
⌥Space（HotKeyManager）或点击菜单栏图标
  ↓ AppController.togglePanel() → showPanel()：记住前台应用 previousApplication，抽屉滑出
  ↓ ClipboardWindow.sendEvent → AppController.handleKey()
      ├─ ← → ↑ ↓：select() + selectionScrollRevision（卡片条居中）
      ├─ Enter / ⇧Enter / ⌘1–9：useSelected()
      ├─ Space：showItemPreview()；Esc：清多选 / 清搜索 / 收起
      └─ 可打印字符：聚焦搜索框并输入
  ↓ useSelected()
      ├─ store.payload() 读完整载荷；纯文本时 ClipboardMonitor.fullText()
      ├─ 轻贴内新建文本含变量 → SnippetExpander.expand()
      ├─ PasteService.write() 写剪贴板 → monitor.markOwnWrite()（避免自己再采集一次）
      ├─ 无辅助功能权限 → 只复制并提示 ⌘V
      ├─ 纯文本默认：始终纯文本，或目标应用在 plainTextApps 列表（pastesPlainText）；“粘贴为”走 TextTransform 后按纯文本写入
      ├─ 文本 / 链接且目标无输入焦点（focusedTextInput == false）→ 只复制
      └─ PasteService.paste()：激活目标应用，确认前台后发送 ⌘V，HUD 提示
```

### 场景 C：搜索与筛选

```
搜索框（$controller.query）/ 筛选菜单（filter、sourceFilter、dateFilter）
  ↓ AppController.refreshResults()：SearchQuery.parse 拆出关键词与 app:/type:/date:/is: 筛选
      ├─ HistoryStore.search()：关键词折叠后按 UTF-8 字节匹配预建索引 searchHaystacks（含拼音全拼与首字母）
      │     （启动时索引在后台建立；未建完时当场补齐）
      └─ 收藏范围、来源、日期过滤 → filteredItems
  ↓ DrawerView → NativeCardStrip.apply()：小变化动画插删，大变化 reloadData
  ↓ DrawerClipCard：SearchHighlight 高亮、从命中行摘录
```

### 场景 D：多选与按顺序粘贴

```
⌘ 点击 / ⇧ 点击 / ⇧← → / ⌘A → multiSelection
  ↓ ⌥Enter → AppController.startPasteQueue()（需辅助功能）
      ├─ writeQueueItem(0) 写第一项，自动粘贴到目标应用
      ├─ 自动粘贴完成 → queuePasted(index: 0)；全局 keyDown 监听用户 ⌘V（忽略重复按键和轻贴自己带标记的 ⌘V）→ queuePasted(当前项)
      ├─ 延迟 200 ms → advancePasteQueue(from:)：只有当前项仍是该项时才写下一项
      └─ Esc 或最后一项 → endPasteQueue()
多选底栏“合并粘贴” → pasteMerged(separator:)：合并文字 → store.capture 新条目 → useSelected()
```
审查 R04：仍以“看到 ⌘V”加固定延迟推进，无法确认目标应用已读到剪贴板。

### 场景 E：编辑、副本、新建

```
右键“编辑…” → AppController.editItem() → ItemEditorController
  ↓ ⌘S → saveEdit() → HistoryStore.updateContent()：重新识别、标题随首行、链接清空标题待重新抓取
右键“创建副本” → HistoryStore.duplicate()
⌘N → AppController.createTextItem() → HistoryStore.capture()（来源为轻贴自身，可用变量）
```

### 场景 F：后台补充（图片文字、链接预览）

```
scheduleEnrichment()（历史变化后触发）
  ├─ runNextOCR()：逐张图片 → ClipResources.ocrImage → OCRService（Vision，本机）→ store.setOCRText
  │    setOCRText：识别出密钥 → detail = sensitive 并设置到期时间
  └─ 链接预览（默认开启，最多 2 个并发）：LinkPreviewService.webURL
        → 敏感或 allowsAutomaticFetch == false → 记空标题（右键“获取链接标题”可手动一次）
        → startLinkFetch → fetch（联网，8 秒超时）→ 回写前核对令牌与当前链接 → store.setLinkPreview
        关闭设置会取消进行中的请求；编辑保存会取消该条在途请求
```

### 场景 G：过期与容量清理

```
维护定时器每 30 秒 → AppController.pruneHistory() → HistoryStore.prune(olderThan:maxItems:)
  ├─ 删除已过期（验证码、敏感内容），收藏除外
  └─ 超出保留天数或条数上限的非收藏条目
```

---

## 五、入口与快捷键索引

| 操作 | 入口 | 处理函数 |
| --- | --- | --- |
| 唤起 / 收起抽屉 | 全局快捷键、菜单栏左键 | `AppController.togglePanel` |
| 选择、使用、预览 | 抽屉内按键 | `AppController.handleKey` |
| 双击 / 拖出 / 右键 | 卡片 | `NativeCardInteractionView` |
| 拖到分类 | 分类标签 | `NativeBoardInteractionView` → `HistoryStore.assignToBoard` / `favorite` |
| 暂停记录 | 菜单栏右键 | `pauseCapture(for:)` / `resumeCapture` |
| 设置 | 菜单栏右键、工具栏齿轮、⌘, | `showSettings` → `SettingsView`，保存走 `saveSettings` |
| 新建常用文本 | ⌘N | `createTextItem` |
| 打开 / 在访达中显示 | ⌘O、右键 | `openItem`、`revealItem` |
| 粘贴为 | 卡片右键 | `transforms(for:)`、`paste(_:as:)` → `useSelected(transform:)` |
| 合并粘贴 | 多选底栏 | `pasteMerged(separator:)` |
| 获取链接标题 | 卡片右键（被规则跳过或失败的链接） | `fetchLinkPreview` |
| 导出 / 导入收藏 | 设置“本机数据” | `exportFavorites`、`importFavorites` → `HistoryStore.exportFavorites` / `importFavorites` |

偏好设置键（`UserDefaults`）：`retentionDays`、`maxItems`、`drawerEdge`、`cardSize`、`linkPreview`、`ocr`、`sensitiveMinutes`、`alwaysPlainText`、`plainTextApps`（默认终端、iTerm2、VS Code、Xcode）、`hideDuringScreenShare`、`excludedApps`（默认含常见密码管理器）、`hotKeyCode`、`hotKeyModifiers`、`onboardingDone`；0.3 遗留 `shortcutOption`。

---

## 六、改动影响链

### 给 `clips` 表加字段 → 同步改：
```
HistoryStore.init                 增量迁移（ALTER TABLE ADD COLUMN，旧行不重写）
Models.ClipItem                   字段
HistoryStore.loadMetadata         SELECT 列与读取
HistoryStore.capture(_ prepared:) 以及 CaptureWriter.write   两处 INSERT 语句
HistoryStore.duplicate            副本 INSERT
需要搜索时：HistoryStore.haystack(for:) 与 publishItems 的变更判断
Scripts/VerifyCore.swift          旧库升级用例 seedLegacyDatabase
```

### 改采集规则（哪些格式保存、摘要怎么取）→ 只改：
```
ClipboardMonitor.isPrivateType / isPersistentType    过滤
ClipboardMonitor.readEntries                         读取与 20 MB 上限
ClipboardMonitor.clip(from:)                         摘要、kind、标题
↳ fullText 与 ClipResources.exportData 也各自取文本，改摘要优先级时一并核对
```

### 改敏感 / 识别规则 → 改：
```
ContentDetector（规则）+ Scripts/VerifyDetection.swift（用例）
过期时长：HistoryStore.expiry(for:from:sensitiveLifetime:)；设置项 sensitiveMinutes → applySettings
卡片展示：DrawerClipCard.detailContent
```

### 改卡片外观 → 改：
```
DrawerClipCard（DrawerView.swift）；新增输入要加进 DrawerClipCard.== ，否则不会刷新
卡片条级别的状态：CardStripState（NativeCardStrip.swift）+ DrawerView.cardStrip 的构造
尺寸：CardSize（DrawerGeometry.swift）
```

### 改搜索 → 改：
```
HistoryStore.search / normalized / haystack(for:) / containsBytes
卡片高亮：SearchHighlight（TextStyling.swift）
```

### 改粘贴行为 → 改：
```
AppController.useSelected / startPasteQueue / advancePasteQueue
PasteService.write / paste / focusedTextInput
写剪贴板后必须调用 monitor.markOwnWrite()
```

---

## 七、症状定位表

| 症状 | 第一现场 | 排查重点 |
| --- | --- | --- |
| 复制后没进历史 | `ClipboardMonitor.poll` / `readEntries` | 是否暂停、前台应用在排除列表、带私密格式、超过 20 MB、`onError` 状态文字 |
| 排除应用的内容仍被记录 | `ClipboardMonitor.poll` / `applicationDidActivate` | 切换通知是否到达；复制与切换几乎同时属于已知边界 |
| 普通复制没记录 | `ClipboardMonitor.poll` | 复制后立刻切到排除应用，定时器先于切换通知时会保守跳过 |
| 同一内容出现两条 | `HistoryStore.capture` / `CaptureWriter.write` | 指纹是否一致（格式顺序、编辑后的 `#edit-` 后缀） |
| 密钥没有打码或没按时删除 | `ClipboardMonitor.clip(from:)` / `ContentDetector.isSensitive` / `setOCRText` | 规则是否覆盖该格式；0.6 前入库的旧条目不会重新判定；收藏不过期 |
| 搜索不到 | `HistoryStore.search` / `SearchQuery.parse` | 关键词按空格拆分且全部命中；索引来自标题、正文摘要、来源、OCR、链接标题、识别标签和拼音（前 600 个汉字）；带冒号的筛选写法是否被识别 |
| “粘贴为”里没有某项 | `TextTransform.available` | 只列出会改变内容的转换；按前 20,000 字判断 |
| 导入收藏报错 | `HistoryStore.importFavorites` | 文件格式标识、版本号；无效文件不改动数据 |
| 按 Enter 只复制没粘贴 | `AppController.useSelected` | 辅助功能权限、目标应用是否有输入焦点、`previousApplication` 是否已退出 |
| 按顺序粘贴跳项 / 重复 | `startPasteQueue` / `queuePasted` / `advancePasteQueue(from:)` | 目标读取剪贴板慢于 200 ms；200 ms 内连按两次 ⌘V 会重复粘贴当前项 |
| 链接标题错 / 一直没有 | `scheduleEnrichment` / `LinkPreviewService.allowsAutomaticFetch` | 设置是否关闭、是否被自动预览规则跳过（右键可手动获取）、空串表示已尝试 |
| 图片缩略图空白 | `ClipResources.thumbnail` | 载荷中是否有可解码的图片格式 |
| 快捷键无效 | `HotKeyManager.register` / `setHotKey` | 被其他应用占用时保留原快捷键并提示 |
| 方向键 / 输入卡顿 | `NativeCardStrip`、`DrawerClipCard` | 用 `BENCH_PROFILE=arrows|typing` 运行基准并 `sample` |
| 启动慢 | `HistoryStore.init` | 用 `BENCH_PROFILE=startup` 采样；索引应在后台建立 |
| “数据库已关闭”或写入失败 | `HistoryStore.reportingErrors` / `errorMessage` | 数据目录权限、磁盘空间、`busy_timeout`（两个写连接各 5 秒） |

---

## 八、系统权限与外部访问

| 能力 | 用途 | 位置 |
| --- | --- | --- |
| 辅助功能 | 模拟 ⌘V、判断输入焦点、按顺序粘贴 | `PasteService`、`requestAccessibility` |
| 登录项 | 开机启动 | `setLaunchAtLogin`（SMAppService） |
| 网络 | 仅链接预览访问链接所在网站（自动预览限公网 HTTPS、无凭据） | `LinkPreviewService.fetch` |
| 屏幕共享隐藏 | 窗口 `sharingType = .none` | `applySharingType` |

---

## 九、特殊机制备忘

```
线程模型：
  主线程      剪贴板读取、列表并入、界面、大部分数据库读写（HistoryStore 主连接）
  captureQueue  采集解析、哈希、编码、新条目插入（CaptureWriter 第二连接）
  ClipResources 缩略图、OCR 取图、拖出导出（每次独立只读连接）
  后台 Task    启动时搜索索引、OCR 识别（.utility）
  SQLite 为 WAL 模式、synchronous = FULL；两个写连接靠 busy_timeout 排队

数据库：
  clips              主表，payload 内联保存（单条最多 20 MB）
  boards / board_membership   收藏分类（外键级联删除）
  link_icons         链接图标
  迁移只做增量：新列、新表，从不重写旧行与载荷

环境变量：
  LIGHTPASTE_DATA_DIR   指定数据目录，同时改用 com.local.lightpaste.acceptance 偏好域（验收用）
  BENCH_*               性能基线脚本参数，见 README

业务规则：
  收藏不受时长、条数清理影响，也不过期；收藏超过条数上限也全部保留
  从 0.3 升级的旧记录只补识别，不追加过期时间
  复制来的内容不展开变量，只展开轻贴内新建的常用文本
  链接抓取每条只尝试一次；空串表示已尝试或被规则跳过
  合并粘贴的新条目来源为“轻贴 · 合并”、无 bundle ID，因此不展开变量
  导入收藏：按载荷指纹去重，分类按名称合并，导入的条目不设到期时间
  验证需用 swiftc 直接编译脚本（命令见 README），不依赖 XCTest
```
