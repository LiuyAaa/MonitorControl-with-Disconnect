# 软件断开外接显示器

**状态**: 已批准,等待实现
**作者**: Brainstorming + 用户
**日期**: 2026-07-06
**关联**: MonitorControl (菜单栏亮度/音量控制 app)

## 目标

让用户能直接从 MonitorControl 菜单栏里"软件断开"某个外接显示器——不需要进入"系统设置→显示器",也不用物理拔线。断开后,macOS 会把窗口/鼠标从该显示器回收;显示器仍在物理上连着,但系统不再使用它。系统后续重置(如唤醒、休眠恢复)后,显示器会重新被 macOS 自动识别并使用,即用户无需"手动恢复"。

## 不在范围内 (YAGNI)

- 不做 DDC/辅助工具级电源切断(不在本版本实现)
- 不做"按偏好保持断开"功能——本版本只是临时断开
- 不为内建显示器 / AppleTV / AirPlay 显示器提供断开入口

## 用户体验

1. 用户打开 MonitorControl 菜单栏图标
2. 看到每个外接显示器块(已是现有的)。在每个非内建显示器的子菜单里多出一项 **"断开连接"**(菜单底部,跟在 slider 块后)
3. 点击后直接执行,无确认对话框
4. 显示器即刻变暗,系统把鼠标/窗口甩回主屏
5. 几秒后 MonitorControl 菜单自动刷新(走现有的 `displayReconfigured` 回调)
6. 断开的显示器从菜单中消失
7. 如果 macOS 之后重新识别到该显示器(如系统唤醒),MonitorControl 自动重建它

## 设计

### 1. `DisplayManager` 新增静态方法

在 `MonitorControl/Support/DisplayManager.swift` 里,紧接已有的 `engageMirror()` 之后,新增:

```swift
static func disconnect(displayID: CGDirectDisplayID) -> Bool {
  // 0. 拒绝内建显示器以及 kCGNullDirectDisplay
  guard displayID != kCGNullDirectDisplay,
        CGDisplayIsBuiltin(displayID) == 0 else {
    os_log("Refusing to disconnect built-in or null display %{public}@", type: .error, String(displayID))
    return false
  }
  // 1. 不允许断开作为 mirror source 的显示器(否则会导致 mirror 链路破损)
  //    与 mirror 主镜像允许 —— 用户体感就是丢掉那个 mirror secondary
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
  // 2. 在交易里把指定显示器关掉
  let configureResult = CGConfigureDisplayEnabled(configRef, displayID, false)
  // 3. 提交 (CGComplete 自带回滚——失败时它自己会回退整个 config)
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

代码风格与既有 `engageMirror()` 一致:同样的 `CGBeginDisplayConfiguration` / `CGConfigureDisplay*` / `CGCompleteDisplayConfiguration` 三步式。所有错误都用 `os_log`。

### 2. `MenuHandler` 在每个外接显示器菜单中插入"断开连接"

在 `MonitorControl/Support/MenuHandler.swift` 的 `addDisplayMenuBlock(...)` / `appendMenuHeader(...)` 这一带的逻辑之后,新增一个方法:

```swift
func addDisconnectMenuItem(display: Display, monitorSubMenu: NSMenu) {
  // 不为内建 / virtual 显示器加
  guard !display.isDummy,
        CGDisplayIsBuiltin(display.identifier) == 0 else { return }

  let item = NSMenuItem(
    title: NSLocalizedString("断开连接", comment: "Disconnect external display menu item"),
    action: #selector(app.disconnectDisplayClicked(_:)),
    keyEquivalent: ""
  )
  // 把显示器 ID 通过 representedObject 传给 handler (NSMenuItem 默认 target 为 nil,沿 responder chain 找到 app)
  item.representedObject = NSNumber(value: display.identifier)
  monitorSubMenu.addItem(item)
}
```

在 `updateDisplayMenu(display:asSubMenu:numOfDisplays:)` 里,当 `asSubMenu == false` 时,在已有 slider block 之后插入该项目;当 `asSubMenu == true` 时,在子菜单的最后插入。

### 3. `AppDelegate` 新增 `@objc` 处理函数

在 `MonitorControl/Support/AppDelegate.swift` 里,加一个公开的处理函数:

```swift
@objc func disconnectDisplayClicked(_ sender: NSMenuItem) {
  guard let number = sender.representedObject as? NSNumber else { return }
  let displayID = number.uint32Value
  // 关闭菜单(很丑,不关不行)
  menu.closeMenu()
  let ok = DisplayManager.disconnect(displayID: displayID)
  if !ok {
    self.showDisconnectFailedAlert()
  }
}

private func showDisconnectFailedAlert() {
  let alert = NSAlert()
  alert.messageText = NSLocalizedString(
    "无法断开显示器",
    comment: "Disconnect failure alert title"
  )
  alert.informativeText = NSLocalizedString(
    "macOS 拒绝了本次断开操作。请检查"辅助功能"权限,或拔掉再插一次。",
    comment: "Disconnect failure alert body"
  )
  alert.addButton(withTitle: NSLocalizedString("好", comment: "OK button"))
  alert.runModal()
}
```

调用 `menu.closeMenu()` 让菜单消失,避免我们改 CG 配置时 NSMenu 在持有过期 displayID。

### 4. 本地化

新增一个 `Main.strings` 条目 `disconnectDisplay` = "断开连接"。所有现有语言都加(尽可能 fallback 到 Base.lproj 的 English "Disconnect")。本 MR 主要新增 `en.lproj/Main.strings` 与 `zh-Hans.lproj/Main.strings` 两个;其它翻译留空走英文 fallback。

## 数据流 (交互时序)

```
User
 │  click "断开连接" in menu
 ▼
AppDelegate.disconnectDisplayClicked(_:)         (AppDelegate.swift, new)
 │   │
 │   │  pull displayID from sender.representedObject
 │   ▼
 │  menu.closeMenu()                            (MenuHandler.swift, existing)
 │   │
 │   ▼
 │  DisplayManager.disconnect(displayID:)        (DisplayManager.swift, new)
 │   │  begin / CGConfigureDisplayEnabled(false) / complete
 │   ▼
 │  macOS 内核 → 触发 CGDisplayRegisterReconfigurationCallback(...)
 │   │
 │   ▼
 │  AppDelegate.displayReconfigured()            (AppDelegate.swift, existing)
 │   │  → DisplayManager.shared.configureDisplays() rebuild
 │   │  → updateMenusAndKeys()  ⟹ 菜单里不再显示该显示器
```

`displayReconfigured` 的回调已经在 `applicationDidFinishLaunching` 注册,本功能无需额外注册。

## 错误处理

- **内建显示器**: `DisplayManager.disconnect` 在 `CGDisplayIsBuiltin != 0` 时返回 `false`,不显示菜单项 (MenuHandler 那侧已经过滤)
- **`CGConfigureDisplayEnabled` 返回非 success**: 调 `CGCancelDisplayConfiguration` 回滚,弹 NSAlert
- **部分 macOS 版本上对特定转接器返回 permission denied**: 弹 NSAlert 提示用户检查辅助功能权限或拔插
- **菜单项点击时显示器已经被移除**: `DisplayManager.disconnect` 校验 `displayID != kCGNullDirectDisplay`,并由 `displayReconfigured` 在几秒后自动清掉过期菜单项

## 测试

本功能无法纯单元测试(CoreGraphics 配置需要真实硬件 + Aqua session)。

### 手工验收

- [ ] 内建显示器(iMac/MacBook 自己的屏)的菜单里没有"断开连接"项
- [ ] virtual / dummy 显示器(空名字、`isDummy == true`)的菜单里没有"断开连接"项
- [ ] 外接 4K 显示器的菜单里有"断开连接"项
- [ ] 点击后 macOS 立刻让该显示器变暗,鼠标甩回主屏
- [ ] 1~2 秒后 MonitorControl 菜单刷新,断开的显示器消失
- [ ] 唤醒或休眠后,显示器自动重新出现在菜单
- [ ] 权限不足的显示器:点 → 弹 alert
- [ ] 中文(zh-Hans)正确显示"断开连接"

### 自动化 / 静态检查

- [ ] `swift build`(或 xcodebuild)编译通过
- [ ] `swiftlint run` 无新增 warning(沿用项目 `.swiftlint.yml`)

## 涉及文件清单

| 文件 | 类型 | 改动 |
| --- | --- | --- |
| `MonitorControl/Support/DisplayManager.swift` | 改 | 新增 `static func disconnect(displayID:) -> Bool` |
| `MonitorControl/Support/MenuHandler.swift` | 改 | 新增 `addDisconnectMenuItem`,在 `updateDisplayMenu` 内调用 |
| `MonitorControl/Support/AppDelegate.swift` | 改 | 新增 `disconnectDisplayClicked(_:)` + `showDisconnectFailedAlert()` |
| `MonitorControl/UI/en.lproj/Main.strings` | 改 | 新增 `disconnectDisplay` = "Disconnect" 等 |
| `MonitorControl/UI/zh-Hans.lproj/Main.strings` | 改 | 新增 `断开连接` 等 |

## 风险

1. **`CGConfigureDisplayEnabled` 的未来兼容性**: 此 API 自 macOS 10.9 起被标记为 deprecated,但项目已经用了同样被 deprecated 的 `CGConfigureDisplayMirrorOfDisplay`(见 `engageMirror`),取舍一致。
2. **某些外接显示器无法软件断开**: NSAlert 弹窗告知用户。
3. **菜单刷新时机**: 依赖现有 `CGDisplayRegisterReconfigurationCallback` → `displayReconfigured`,延迟 1 秒。已在线上验证可行。
