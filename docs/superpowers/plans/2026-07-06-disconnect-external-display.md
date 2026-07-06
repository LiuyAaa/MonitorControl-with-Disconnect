# 软件断开外接显示器 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 MonitorControl 菜单栏的每个非内建显示器子菜单里加一项"断开连接",让用户能一行点击就让 macOS 软件卸载该显示器。

**Architecture:** 仿照项目里既有的 `engageMirror()` 模式,用 `CGConfigureDisplayEnabled(displayID, false)` 跑一遍 `CGBeginDisplayConfiguration` 交易,然后 `CGCompleteDisplayConfiguration`。触发链:`菜单项点击` → `AppDelegate.disconnectDisplayClicked(_:)` → `DisplayManager.disconnect(displayID:)`,断开后由既有的 `CGDisplayRegisterReconfigurationCallback` 回调刷新菜单。

**Tech Stack:** Swift 5+,AppKit (`NSMenuItem`, `NSAlert`),CoreGraphics (`CGConfigureDisplayEnabled`),本地化用 `NSLocalizedString`。

## Global Constraints

- 改动必须只在 macOS 主 app target 范围内,不动 `MonitorControlHelper`
- 沿用项目命名风格:os_log 用 `type: .info`/`.error`,`NSLocalizedString(_, comment: ...)` 必须带 comment 提示语境
- 不引入新依赖(无 SwiftLint 要求安装,项目已有 `.swiftlint.yml` 但 lint 不强制)
- 中文文案以简体为准,字符用 `…`/`“`/`”` 等 ASCII-safe;或者直接中文,NSLocalizedString 接受 UTF-8
- 本项目无单元测试 target(`MonitorControlTests/` 不存在),验证方式为: `xcodebuild` 编译 + 人工 UI 清单

## File Structure

新增与改动的文件:

| 文件 | 性质 | 责任 |
| --- | --- | --- |
| `MonitorControl/Support/DisplayManager.swift` | 改 | 新增 `disconnect(displayID:)` 静态方法 |
| `MonitorControl/Support/MenuHandler.swift` | 改 | 新增 `addDisconnectMenuItem(display:monitorSubMenu:)`,并在 `updateDisplayMenu` 中插入调用 |
| `MonitorControl/Support/AppDelegate.swift` | 改 | 新增 `@objc func disconnectDisplayClicked(_:)` + private `showDisconnectFailedAlert()` |
| `MonitorControl/UI/en.lproj/Localizable.strings` | 改 | 新增 1 个 key:"Disconnect" (菜单)+ 3 个 key (alert title/body/OK) |
| `MonitorControl/UI/zh-Hans.lproj/Localizable.strings` | 改 | 同 4 个 key 的简体中文翻译 |

文件边界:每个文件一处责任,改动不超过 ~15 行,审阅者可在 PR 里快速对照 spec。

---

## Task 1: 新增 `DisplayManager.disconnect(displayID:)`

**Files:**
- Modify: `MonitorControl/Support/DisplayManager.swift:495` (在现有 `engageMirror()` 之后)

**Interfaces:**
- Consumes: `CGDirectDisplayID`(系统类型)
- Produces:
  - `static func DisplayManager.disconnect(displayID: CGDirectDisplayID) -> Bool`
    - 入参:要断开的显示器 ID
    - 返回:`true` macOS 已成功提交 config,`false` 被拒绝或输入不合法
    - 副作用:无返回值成功的情况,macOS 触发 `CGDisplayRegisterReconfigurationCallback`

- [ ] **Step 1: 在 `engageMirror()` 关闭括号后插入新静态方法**

打开 `MonitorControl/Support/DisplayManager.swift`,找到 `engageMirror()` 函数的最后一个 `return true`(大约第 494 行)之后、`resolveEffectiveDisplayID(_:)` 之前。新增方法:

```swift
  static func disconnect(displayID: CGDirectDisplayID) -> Bool {
    // 0. 拒绝 kCGNullDirectDisplay 与内建显示器
    guard displayID != kCGNullDirectDisplay,
          CGDisplayIsBuiltin(displayID) == 0 else {
      os_log("Refusing to disconnect built-in or null display %{public}@", type: .error, String(displayID))
      return false
    }
    // 1. 不允许断开作为 mirror source 的显示器
    if CGDisplayIsInHWMirrorSet(displayID) != 0 || CGDisplayIsInMirrorSet(displayID) != 0,
       CGDisplayMirrorsDisplay(displayID) == kCGNullDirectDisplay {
      os_log("Refusing to disconnect mirror source %{public}@", type: .error, String(displayID))
      return false
    }

    var configRef: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&configRef) == .success else {
      os_log("CGBeginDisplayConfiguration failed for %{public}@", type: .error, String(displayID))
      return false
    }
    let configureResult = CGConfigureDisplayEnabled(configRef, displayID, false)
    // CGComplete 自带回滚——失败时它自己会回退整个 config
    let commitResult = CGCompleteDisplayConfiguration(configRef, CGConfigureOption.permanently)

    if configureResult != .success || commitResult != .success {
      os_log("CGConfigureDisplayEnabled/complete failed for %{public}@ (cfg=%{public}@ commit=%{public}@)",
             type: .error,
             String(displayID),
             String(configureResult.rawValue),
             String(commitResult.rawValue))
      return false
    }
    os_log("Disconnected display %{public}@", type: .info, String(displayID))
    return true
  }
```

- [ ] **Step 2: 编译验证**

Run: `cd /Users/liuyaaa/Code/MonitorControl && xcodebuild -project MonitorControl.xcodeproj -scheme MonitorControl -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -50`
Expected: 以 `** BUILD SUCCEEDED **` 结尾;若失败,只可能是此 Task 加进的方法有语法错误,fix 后重跑。

- [ ] **Step 3: 提交**

```bash
cd /Users/liuyaaa/Code/MonitorControl
git add MonitorControl/Support/DisplayManager.swift
git commit -m "feat: DisplayManager.disconnect — 软件断开外接显示器 (Task 1/5)"
```

---

## Task 2: 在 `MenuHandler` 加菜单项构建方法

**Files:**
- Modify: `MonitorControl/Support/MenuHandler.swift:178` (在 `updateDisplayMenu(display:asSubMenu:numOfDisplays:)` 末尾之后)

**Interfaces:**
- Consumes: `Display`(已有类型)
- Produces:
  - `func MenuHandler.addDisconnectMenuItem(display: Display, monitorSubMenu: NSMenu)`
    - 入参:目标显示器,以及该显示器所在的子菜单引用
    - 副作用:在子菜单末尾插入一项 "Disconnect"
    - 内部通过 `display.isDummy` 与 `CGDisplayIsBuiltin(display.identifier)` 双重过滤

- [ ] **Step 1: 在 `updateDisplayMenu(display:asSubMenu:numOfDisplays:)` 函数后面新增方法**

打开 `MonitorControl/Support/MenuHandler.swift`,在 `updateDisplayMenu(...)` 末尾(第 203 行 `app.updateStatusItemVisibility(true) }`)之前,新增:

```swift
  func addDisconnectMenuItem(display: Display, monitorSubMenu: NSMenu) {
    guard !display.isDummy,
          CGDisplayIsBuiltin(display.identifier) == 0 else { return }
    let item = NSMenuItem(
      title: NSLocalizedString("Disconnect", comment: "Disconnect external display menu item"),
      action: #selector(app.disconnectDisplayClicked(_:)),
      keyEquivalent: ""
    )
    // 把显示器 ID 通过 representedObject 传给 handler (NSMenuItem 默认 target 为 nil,沿 responder chain 找到 app)
    item.representedObject = NSNumber(value: display.identifier)
    monitorSubMenu.addItem(item)
  }
```

- [ ] **Step 2: 在 `updateDisplayMenu(...)` 末尾挂上调用点**

修改 `updateDisplayMenu(display:asSubMenu:numOfDisplays:)` 的最后一行(目前是 `app.updateStatusItemVisibility(true) }`)之前,插入:

```swift
    self.addDisconnectMenuItem(display: display, monitorSubMenu: monitorSubMenu)
```

完整结尾应该是:

```swift
    if addedSliderHandlers.count > 0, prefs.integer(forKey: PrefKey.menuIcon.rawValue) == MenuIcon.sliderOnly.rawValue {
      app.updateStatusItemVisibility(true)
    }
    self.addDisconnectMenuItem(display: display, monitorSubMenu: monitorSubMenu)
  }
```

- [ ] **Step 3: 编译验证**

Run: `cd /Users/liuyaaa/Code/MonitorControl && xcodebuild -project MonitorControl.xcodeproj -scheme MonitorControl -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40`
Expected: `** BUILD SUCCEEDED **`。

注:这一步会编译失败 —— 因为 Task 3 还没创建 `app.disconnectDisplayClicked(_:)`,`#selector(app.disconnectDisplayClicked(_:))` 引用会找不到方法。预期失败信息形如 `Cannot find 'disconnectDisplayClicked' in scope`。这是预期状态,验证"调用点已接好"后立即进入 Task 3 修复。

- [ ] **Step 4: 提交(阶段性 commit)**

```bash
cd /Users/liuyaaa/Code/MonitorControl
git add MonitorControl/Support/MenuHandler.swift
git commit -m "feat: MenuHandler.addDisconnectMenuItem (Task 2/5)"
```

---

## Task 3: 在 `AppDelegate` 加菜单处理函数

**Files:**
- Modify: `MonitorControl/Support/AppDelegate.swift`(在 `quitClicked` 之后、`prefsClicked` 之前)

**Interfaces:**
- Consumes: `NSMenuItem`(系统类型)
- Produces:
  - `@objc func AppDelegate.disconnectDisplayClicked(_ sender: NSMenuItem)` —— 处理菜单点击
  - `private func AppDelegate.showDisconnectFailedAlert()` —— 失败 NSAlert 弹窗

- [ ] **Step 1: 找到插入点**

打开 `MonitorControl/Support/AppDelegate.swift`,在第 71 行 `@objc func quitClicked(_: AnyObject) { ... }` 函数结束之后、第 79 行 `@objc func prefsClicked(_: AnyObject) { ... }` 之前,新增以下两个方法:

```swift
  @objc func disconnectDisplayClicked(_ sender: NSMenuItem) {
    guard let number = sender.representedObject as? NSNumber else { return }
    let displayID = number.uint32Value
    // 关掉菜单避免 NSMenu 持有过期的 displayID
    menu.closeMenu()
    let ok = DisplayManager.disconnect(displayID: displayID)
    if !ok {
      self.showDisconnectFailedAlert()
    }
  }

  private func showDisconnectFailedAlert() {
    let alert = NSAlert()
    alert.messageText = NSLocalizedString(
      "Could not disconnect display",
      comment: "Disconnect failure alert title"
    )
    alert.informativeText = NSLocalizedString(
      "macOS refused to disconnect this display. Check Accessibility permissions or try replugging the display.",
      comment: "Disconnect failure alert body"
    )
    alert.addButton(withTitle: NSLocalizedString("OK", comment: "OK button"))
    alert.runModal()
  }
```

- [ ] **Step 2: 编译验证(全工程)**

Run: `cd /Users/liuyaaa/Code/MonitorControl && xcodebuild -project MonitorControl.xcodeproj -scheme MonitorControl -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -50`
Expected: `** BUILD SUCCEEDED **`。如果失败:
- 检查 `disconnectDisplayClicked(_:)` 是否拼写一致(对应 MenuHandler 里的 `#selector`)
- 检查 `menu.closeMenu()` 引用 —— `menu` 是 AppDelegate 的全局变量(在 `main.swift` 定义为 `MenuHandler`),Swift 编译器应能解析

- [ ] **Step 3: 提交**

```bash
cd /Users/liuyaaa/Code/MonitorControl
git add MonitorControl/Support/AppDelegate.swift
git commit -m "feat: AppDelegate.disconnectDisplayClicked handler (Task 3/5)"
```

---

## Task 4: 本地化

**Files:**
- Modify: `MonitorControl/UI/en.lproj/Localizable.strings`
- Modify: `MonitorControl/UI/zh-Hans.lproj/Localizable.strings`

新增 4 个 key,每个 key 包含 iOS/macOS 上 NSLocalizedString 的 comment 注释。

- [ ] **Step 1: English**

在 `MonitorControl/UI/en.lproj/Localizable.strings` 文件末尾追加(注意按字母序插入别破坏其他 key 的位置):

```strings
/* Disconnect external display menu item */
"Disconnect" = "Disconnect";

/* Disconnect failure alert title */
"Could not disconnect display" = "Could not disconnect display";

/* Disconnect failure alert body */
"macOS refused to disconnect this display. Check Accessibility permissions or try replugging the display." = "macOS refused to disconnect this display. Check Accessibility permissions or try replugging the display.";

/* OK button */
"OK" = "OK";
```

(实际插入时,需与现有 key 字母序一致 —— 比如 `D` 部分夹在现有 `Decrease` 与 `Disable gamma...` 之间即可;如果嫌麻烦,直接追加到文件末尾也行,NSLocalizedString 按 key 取值时不在意顺序。)

**简化的步骤:** 直接把以上 4 条追加在文件末尾(现有 key 的 order 不会被破坏,因为 NSLocalizedString 走 key lookup,不影响翻译)。

- [ ] **Step 2: Simplified Chinese**

在 `MonitorControl/UI/zh-Hans.lproj/Localizable.strings` 末尾追加:

```strings
/* Disconnect external display menu item */
"Disconnect" = "断开连接";

/* Disconnect failure alert title */
"Could not disconnect display" = "无法断开显示器";

/* Disconnect failure alert body */
"macOS refused to disconnect this display. Check Accessibility permissions or try replugging the display." = "macOS 拒绝了本次断开操作。请检查「辅助功能」权限,或拔掉再插一次。";

/* OK button */
"OK" = "好";
```

- [ ] **Step 3: 校验格式**

Run: `cd /Users/liuyaaa/Code/MonitorControl && plutil -lint MonitorControl/UI/en.lproj/Localizable.strings MonitorControl/UI/zh-Hans.lproj/Localizable.strings`
Expected: 两行 `OK`,没有错误。

- [ ] **Step 4: 编译验证(再次确认)**

Run: `cd /Users/liuyaaa/Code/MonitorControl && xcodebuild -project MonitorControl.xcodeproj -scheme MonitorControl -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -30`
Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 5: 提交**

```bash
cd /Users/liuyaaa/Code/MonitorControl
git add MonitorControl/UI/en.lproj/Localizable.strings MonitorControl/UI/zh-Hans.lproj/Localizable.strings
git commit -m "feat: 本地化 — 断开连接 (zh-Hans + en) (Task 4/5)"
```

---

## Task 5: 端到端验证

**Files:**
- Modify:无源码改动,只复跑现有命令

**Interfaces:** 无新增

- [ ] **Step 1: 全工程编译**

Run: `cd /Users/liuyaaa/Code/MonitorControl && xcodebuild -project MonitorControl.xcodeproj -scheme MonitorControl -configuration Debug clean build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -40`
Expected: `** BUILD SUCCEEDED **`。若失败则回到对应 Task 修复。

- [ ] **Step 2: 在 Xcode 里启动 app,跑人工清单**

在 Xcode 里选 scheme `MonitorControl`,Run(⌘R),然后人工验收以下每一条(对应 spec 里 "手工验收" 一节):

- [ ] 内建显示器(iMac/MacBook 自己的屏)的菜单里没有"Disconnect"项
- [ ] 外接 4K 显示器的菜单里有"Disconnect"项(在子菜单底部)
- [ ] 点击后 macOS 立刻让该显示器变暗,鼠标甩回主屏
- [ ] 1~2 秒后 MonitorControl 菜单刷新,断开的显示器消失
- [ ] 唤醒或休眠后,显示器自动重新出现在菜单
- [ ] 把系统语言切到简体中文后,菜单里"断开连接"四字正确显示

(以上只能人工验证,无法在 CI 里跑 —— 把勾选结果记录在 PR description 里)

- [ ] **Step 3: 最终提交**

把第 5 步产生的 build artifact(`.app` 在 DerivedData 下)不进 git。只在前几步 commit 之后做一个空 summary commit 让链完整(可选),或直接关掉 PR。

如果 Step 1 已经成功且代码已合并,此处无需新增 commit。

## Self-Review

**1. Spec coverage:**

- ✅ 目标:每显示器菜单下加 "Disconnect" —— Task 2 + Task 3 实现
- ✅ 不内建 / 不 dummy —— Task 1 (DisplayManager 端 guard) + Task 2 (MenuHandler 端 guard) 双重保护
- ✅ macOS 自动回连(用户不需手动恢复) —— 不需要代码,功能天然就是此行为
- ✅ 触发链:菜单 → AppDelegate → DisplayManager → CGComplete → CGDisplayRegisterReconfigurationCallback —— Task 1+2+3 完整覆盖
- ✅ 失败弹 NSAlert —— Task 3 `showDisconnectFailedAlert`
- ✅ 本地化 en + zh-Hans —— Task 4
- ✅ 错误处理 mirror source —— Task 1 guard
- ⏭ 不在范围内:DDC/HELPER 切断电源、本版本不做"保持断开"持久化,本 plan 未引入

**2. Placeholder scan:**

- 搜索 "TBD" / "TODO" / "implement later" / "fill in details" —— 0 命中
- 没有 "add appropriate error handling" 这种空洞指示,每条 Task 都给了完整代码
- "类似 Task 2" 等偷懒引用无;每 Task 都自包含完整代码

**3. Type consistency:**

- Task 1 `disconnect(displayID: CGDirectDisplayID) -> Bool` —— Task 3 调用 `DisplayManager.disconnect(displayID: displayID)` 同一签名 ✓
- Task 2 菜单项 `action: #selector(app.disconnectDisplayClicked(_:))` —— Task 3 `@objc func disconnectDisplayClicked(_ sender: NSMenuItem)` 同名 ✓
- Task 2 `representedObject = NSNumber(value: display.identifier)` —— Task 3 读 `sender.representedObject as? NSNumber` ✓
- Task 4 4 个 key 的中英文字面量都被 NSLocalizedString 引用:Task 2/3 各用对应 key ✓

无类型不一致。
