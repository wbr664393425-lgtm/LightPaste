# 轻贴 · LightPaste

一款 macOS 本地剪贴板管理器。通过屏幕边缘的横向卡片抽屉，查找、收藏和再次使用复制过的文本、链接、图片与文件。当前版本：**0.6.0**。

## 功能

- **剪贴板历史**：保存文本、链接、图片、文件及原始多格式内容，支持搜索、收藏、自定义分类、多选和批量操作。
- **屏幕边缘抽屉**：默认从底部展开，可切换到顶部；跟随系统深浅色外观，提供三档卡片尺寸。
- **快速搜索**：检索正文、标题、来源应用、链接标题和图片文字；支持中文拼音、首字母及类型、日期等组合筛选。
- **再次粘贴**：复制、自动粘贴、纯文本粘贴、合并粘贴、按顺序粘贴，以及向其他应用拖出内容。
- **内容处理**：文本编辑、创建副本、常用文本变量、JSON 格式化、大小写转换、链接跟踪参数清理和颜色格式转换。
- **本机识别**：识别代码、颜色、邮箱、电话、验证码与敏感内容；使用系统 Vision 框架识别图片中的中英文。
- **记录与隐私设置**：暂停记录、排除指定应用、敏感内容自动到期、共享屏幕时隐藏抽屉与预览、收藏导入导出。

## 系统要求

- macOS 13 或更新版本。
- 构建需要 Apple Command Line Tools、`python3` 和 `zsh`，无需完整 Xcode。
- 当前主要在 Apple Silicon 上构建和使用，**Intel Mac 尚未验证**。

## 构建与启动

安装 Command Line Tools 后，确认 `python3` 可用，再运行：

```sh
git clone https://github.com/wbr664393425-lgtm/LightPaste.git
cd LightPaste
./build.sh
open "轻贴.app"
```

构建结果为仓库目录中的 `轻贴.app`，默认使用本机临时签名。可将应用移入“应用程序”目录；移动位置或重建临时签名后，可能需要重新授予辅助功能权限。

需要对外分发时，可自行使用 Developer ID 签名并公证（需要 Apple 开发者账号与有效签名证书）：

```sh
xcrun notarytool store-credentials lightpaste-notary
LIGHTPASTE_SIGN_IDENTITY="Developer ID Application: 名称 (TEAMID)" \
LIGHTPASTE_NOTARY_PROFILE=lightpaste-notary ./build.sh
```

脚本将签名、公证并在 `.build/` 中生成 ZIP；只设置 `LIGHTPASTE_SIGN_IDENTITY` 时仅签名。公证凭据保存在本机钥匙串。

## 使用

在其他应用中正常复制内容，即可加入历史。按默认快捷键 **⌥Space** 或左键点击菜单栏图标展开抽屉，右键图标打开更多操作；快捷键可在设置中更改。

| 操作 | 快捷键或手势 |
| --- | --- |
| 浏览与选择 | 横向滚动、**← →**；搜索时用 **↑ ↓** 选择结果 |
| 使用选中内容 | **Enter** 或双击卡片 |
| 使用纯文本 | **⇧Enter** |
| 快速使用前 9 项 | **⌘1–9**；加 **⇧** 使用纯文本 |
| 快速预览 / 收起 | **Space** / **Esc** |
| 搜索 | 直接输入或 **⌘F** |
| 多选 | **⌘ 点击**逐个选择、**⇧ 点击**连选、**⌘A** 全选当前结果 |
| 按顺序粘贴 | 多选后 **⌥Enter**，此后在目标应用按 **⌘V** 使用下一项，**Esc** 结束 |
| 新建常用文本 | **⌘N** |

开启“始终粘贴为纯文本”或为特定应用设置纯文本粘贴后，按 **⇧** 使用会改为保留原格式；图片和文件不受影响。中文输入法正在组词时，Enter 先确认组词。

**自动粘贴权限**：首次使用时，按提示前往“系统设置 → 隐私与安全性 → 辅助功能”授权轻贴。拒绝授权仍可复制条目，再手动按 **⌘V**。文本和链接会检查目标输入焦点；图片和文件、无法判断焦点的部分应用采用直接尝试粘贴的方式。自动粘贴依赖目标应用的响应。

**搜索与筛选**：可组合使用 `app:微信`、`type:图片`、`date:今天`、`is:收藏`；也支持 `来源:`、`类型:`、`日期:` 及中文冒号。日期支持今天、昨天、本周、本月；类型支持文本、链接、图片、文件及代码、颜色、邮箱、电话、验证码、敏感。中文全拼或首字母搜索覆盖标题和正文前 2,000 字中的前 600 个汉字。

**收藏与分类**：星标收藏，分类标签末尾的加号新建分类；卡片可拖入分类，也可右键“收藏到”。删除分类会保留内容与收藏。设置“本机数据”中可导出、导入含分类的 `.lightpaste` 收藏备份；相同内容和同名分类会合并，重复导入不会新增相同条目。

**编辑与转换**：文本和链接卡片右键“编辑…”可修改内容与基本格式，**⌘S** 保存；保存会替换原有内容格式。“创建副本”生成独立条目。“粘贴为”提供文本清理、JSON、链接和颜色转换，原条目不变。多选后可按选择顺序合并文字，图片会跳过；也可拖出整组内容，接收效果取决于目标应用。

**常用文本变量**：通过“新建常用文本”保存的内容支持 `{日期}`、`{时间}`、`{剪贴板}` 和 `{光标}`；复制进入历史的普通内容不会展开变量。

**暂停与排除**：菜单栏右键“暂停记录”可选 15 分钟、1 小时、8 小时或手动恢复；在设置“隐私”中选择不记录的应用。带机密或临时剪贴板标记的内容会跳过。无法可靠判断复制来源时，可能跳过该次记录。

## 数据与隐私

历史与载荷保存在 `~/Library/Application Support/LightPaste/`，**本地数据和导出的收藏备份未加密**。默认保留最近 30 天、最多 1,000 条，保留时长可调整；收藏不受自动清理影响。单次采集上限为 20 MB。退出应用后停止监测，已有记录仍保留在本机。暂未提供云同步。

内容识别与图片文字识别在本机完成。识别出的敏感内容在卡片中打码，悬停或预览可显示原文，默认 10 分钟后删除（可调整）；验证码默认 5 分钟后删除，收藏不会自动到期。识别是启发式判断，可能存在漏判和误判；打码不代表数据已加密。旧版本记录升级时不会自动追加过期时间。

**链接预览默认开启且会联网**：复制 HTTPS 链接后，会访问对应网站获取标题与图标，每个链接只尝试一次。HTTP、常见本机与局域网地址、带账号密码或凭据参数、已识别为敏感内容的链接不会自动访问；非敏感链接可通过右键手动获取标题。判断基于原始链接，跳转后的地址由系统决定。可在设置“记录 → 显示链接标题和图标”中关闭此功能；除链接预览外，历史数据不上传。

## 验证与已知限制

仓库包含数据存储、内容识别、资源处理、原生交互、抽屉布局和性能验证脚本，位于 `Scripts/`；另有 `Tests/LightPasteTests/`。仅安装 Command Line Tools 时，可运行核心验证：

```sh
mkdir -p .build/verification-cache
swiftc -swift-version 5 -parse-as-library -module-cache-path .build/verification-cache \
  Sources/LightPaste/Models.swift Sources/LightPaste/HistoryStore.swift Sources/LightPaste/ContentDetector.swift \
  Sources/LightPaste/ClipboardMonitor.swift Sources/LightPaste/SystemServices.swift Sources/LightPaste/ItemEditor.swift \
  Scripts/VerifyCore.swift -o .build/VerifyCore -lsqlite3
.build/VerifyCore
swiftc -swift-version 5 -parse-as-library -module-cache-path .build/verification-cache \
  Sources/LightPaste/Models.swift Sources/LightPaste/ContentDetector.swift \
  Sources/LightPaste/TextTransform.swift Sources/LightPaste/Enrichment.swift \
  Scripts/VerifyDetection.swift -o .build/VerifyDetection
.build/VerifyDetection
```

核心验证使用临时目录和专用剪贴板，不读取或改写用户的系统剪贴板。具备 XCTest 的完整 Xcode 环境可运行 `swift test`。

真实跨应用自动粘贴、按顺序粘贴和拖放提交尚未完成完整验收；目标应用兼容性需要实机确认。界面或处理器验证不能代替这些结果。自动粘贴失败时，可复制条目后手动粘贴。

## 反馈与许可

问题与建议请提交到 [GitHub Issues](https://github.com/wbr664393425-lgtm/LightPaste/issues)。提交时请勿附带真实剪贴板内容、密钥或其他隐私数据。

本项目采用 [MIT License](LICENSE)。
