// BLE Unlock 安装器 — 界面与主流程
//
// 注意：入口不在这里。@main 属性在只有 Command Line Tools 的 Swift 工具链下
// 不会正确启动 AppKit（applicationDidFinishLaunching 根本不被调用，表现为
// 进程在跑但没有窗口）。因此入口改为 installer-src/main.swift 中的显式
// NSApplicationMain，本文件只放类定义。

import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    var installer = Installer(log: { _ in })

    func applicationDidFinishLaunching(_ notification: Notification) {
        diag("=== 安装器启动 pid=\(getpid()) ===")
        diag("bundle=\(Bundle.main.bundlePath)")

        NSApp.setActivationPolicy(.regular)
        buildMainMenu()
        NSApp.activate(ignoringOtherApps: true)
        diag("激活策略 regular，主菜单已建立")

        DispatchQueue.main.async { self.runFlow() }
    }

    /// 没有主菜单时，NSAlert.runModal() 在部分 macOS 版本上不会显示窗口。
    /// 必须建立一个最小可用的 App 菜单。
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        let appName = "BLE Unlock 安装器"
        appMenu.addItem(withTitle: "关于 \(appName)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "隐藏 \(appName)",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 \(appName)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        NSApp.mainMenu = mainMenu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: - 主流程

    private func runFlow() {
        let fm = FileManager.default
        let isUpgrade = fm.fileExists(atPath: Const.serviceApp.path)

        // ---------- 欢迎 ----------
        let welcomeText = """
        这个安装器会在你的 Mac 上完成以下配置：

        1. 安装蓝牙解锁服务端到「应用程序支持」目录
        2. \(isUpgrade ? "保留原有的配对密钥" : "生成你的专属配对密钥")
        3. 把你的登录密码存入 macOS 钥匙串
        4. 设置开机自动启动
        5. 引导你授权「辅助功能」权限

        全程不需要终端，也不需要安装 Xcode。
        """
        let welcomeChoice = present(
            title: isUpgrade ? "更新 BLE Unlock 服务端" : "安装 BLE Unlock 服务端",
            message: welcomeText,
            buttons: [isUpgrade ? "开始更新" : "开始安装", "退出"])
        guard welcomeChoice == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue else {
            NSApp.terminate(nil)
            return
        }

        // ---------- 密码 ----------
        guard let password = askPassword(isUpgrade: isUpgrade) else {
            NSApp.terminate(nil)
            return
        }

        // ---------- 执行安装 ----------
        var report: [String] = []

        installer.log = { msg in
            NSLog("[BLEUnlock] %@", msg)
            report.append(msg)
        }

        installer.stopService()

        if case .failed(let e) = installer.installService() {
            alert("安装失败", e, style: .critical)
            NSApp.terminate(nil)
            return
        }
        if case .failed(let e) = installer.ensureKey() {
            alert("安装失败", e, style: .critical)
            NSApp.terminate(nil)
            return
        }
        if case .failed(let e) = installer.installLaunchAgent() {
            alert("安装失败", e, style: .critical)
            NSApp.terminate(nil)
            return
        }
        if case .failed(let e) = installer.storePassword(password) {
            alert("安装失败", e, style: .critical)
            NSApp.terminate(nil)
            return
        }

        installer.startService()
        // 给服务一点启动时间，便于随后查询权限状态
        Thread.sleep(forTimeInterval: 1.5)

        // ---------- 结果与令牌 ----------
        let token = installer.pairingToken() ?? "（读取失败，请重新运行安装器）"
        let axOK = installer.hasAccessibility()

        let doneText = """
        接下来只需两步：

        1. 在手机 App 里点「＋ 添加 Mac」，粘贴下面的配对令牌
        2. 点「解锁」即可

        ───── 配对令牌 ─────
        \(token)
        ───────────────────

        \(axOK
            ? "「辅助功能」权限已授权，一切就绪。"
            : "还差最后一步：「辅助功能」权限尚未授权，未授权时无法自动解锁。")
        """
        let choice = present(title: isUpgrade ? "更新完成" : "安装完成",
                             message: doneText,
                             buttons: [axOK ? "完成" : "去授权", "复制令牌"])

        if choice == NSApplication.ModalResponse.alertSecondButtonReturn.rawValue {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(token, forType: .string)
            alert("已复制", "配对令牌已复制到剪贴板，可粘贴到手机 App。")
        }

        if !installer.hasAccessibility() {
            guideAccessibility()
        }

        NSApp.terminate(nil)
    }

    // MARK: - 密码输入

    private func askPassword(isUpgrade: Bool) -> String? {
        while true {
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            field.placeholderString = "登录密码"

            let response = present(
                title: "输入你的登录密码",
                message: """
                蓝牙解锁需要用你的登录密码来自动解锁屏幕。
                密码会存入 macOS 钥匙串，不会写入任何配置文件，也不会通过网络传输。

                请务必填写正确，否则锁屏时无法解锁。
                """,
                buttons: ["确定", "取消"],
                accessory: field)

            guard response == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue else {
                return nil
            }
            let value = field.stringValue
            if value.isEmpty {
                alert("密码不能为空", "请重新输入。", style: .warning)
                continue
            }
            return value
        }
    }

    // MARK: - 辅助功能引导

    private func guideAccessibility() {
        let choice = present(
            title: "最后一步：授权「辅助功能」",
            message: """
            macOS 要求「辅助功能」权限才允许程序模拟键盘输入。
            没有这个权限，解锁会静默失败。

            点击「打开系统设置」后：
            1. 在列表里找到 BLEUnlockCmd
            2. 打开它的开关
            3. 若列表里没有，点左下角 ＋ 添加：
               \(Const.serviceBin.path)

            授权后无需重启，立即生效。
            """,
            buttons: ["打开系统设置", "稍后再说"])

        if choice == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue {
            installer.openAccessibilitySettings()
        }

        // 等用户操作完再复查一次
        let check = present(title: "授权好了吗？",
                            message: "点「检查」来确认权限是否已生效。",
                            buttons: ["检查", "跳过"])
        if check == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue {
            if installer.hasAccessibility() {
                alert("权限已生效", """
                一切就绪，现在可以用手机解锁这台 Mac 了。

                如果解锁没反应，检查一下：
                • Mac 上是否已锁定屏幕（未锁定时解锁会返回 NOT_LOCKED）
                • 手机与 Mac 的蓝牙是否都开启
                """)
            } else {
                alert("权限还未生效", """
                系统设置里可能还没打开开关，或者需要退出系统设置重新打开。

                你可以随时重新运行这个安装器再检查一次，
                或在终端执行：
                \(Const.serviceBin.path) --check
                """, style: .warning)
            }
        }
    }
}
