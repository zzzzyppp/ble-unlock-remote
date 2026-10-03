// BLE Unlock 设置向导 — 主流程
//
// 设计：App 由用户拖拽安装到「应用程序」后再运行，此时它位于一个稳定的路径，
// 于是可以在应用内完成全部配置（服务端、密钥、钥匙串、开机自启、权限引导）。
//
// 入口在 main.swift（显式 NSApplication），本文件只放类定义。

import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let setup = SetupWindow()
    private let installer = Installer(log: { _ in })
    private var alreadyInstalled = false
    private var pendingToken = ""
    private var accessibilityPollTimer: Timer?
    private var didFinishAccessibility = false
    private var stepIndex = 0
    private let totalSteps = 4.0

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        diag("=== 设置向导启动 pid=\(getpid()) ===")
        diag("bundle=\(Bundle.main.bundlePath)")
        diag("support=\(Const.supportDir.path)")

        if isTranslocated() {
            diag("警告：App 正运行于随机只读路径（Gatekeeper 路径随机化）")
        }

        NSApp.setActivationPolicy(.regular)
        buildMainMenu()

        alreadyInstalled = FileManager.default.fileExists(atPath: Const.serviceApp.path)
        diag("是否已安装：\(alreadyInstalled)")

        setup.installer = installer
        setup.onPrimary = { [weak self] stage in self?.handlePrimary(stage) }
        setup.onSecondary = { [weak self] in self?.handleSecondary() }
        setup.present()

        if alreadyInstalled && installer.hasAccessibility() {
            setup.appendLog("检测到服务端与权限均已就绪")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: - 主菜单（没有它对话框可能不显示）

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        let name = "BLE Unlock"
        appMenu.addItem(withTitle: "关于 \(name)",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 \(name)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = mainMenu
    }

    /// Gatekeeper 会把未公证的 App 放到随机只读路径运行。
    /// 该路径每次启动都不同，会导致辅助功能权限无法稳定绑定。
    private func isTranslocated() -> Bool {
        Bundle.main.bundlePath.contains("/AppTranslocation/")
    }

    // MARK: - 按钮分发

    private func handlePrimary(_ stage: SetupWindow.Stage) {
        switch stage {
        case .intro:
            setup.showPassword(alreadyInstalled: alreadyInstalled)
        case .needPassword:
            let password = setup.passwordValue
            if password.isEmpty {
                setup.appendLog("✗ 密码不能为空，请重新输入")
                setup.shakePassword()
                return
            }
            runInstall(password: password)
        case .finished:
            NSApp.terminate(nil)
        case .working:
            break
        }
    }

    private func handleSecondary() {
        switch setup.stage {
        case .intro:
            NSApp.terminate(nil)
        case .needPassword:
            setup.showIntro(alreadyInstalled: alreadyInstalled)
        case .finished:
            if didFinishAccessibility {
                copyToken()
            } else {
                openLog()
            }
        case .working:
            break
        }
    }

    private func copyToken() {
        guard !pendingToken.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(pendingToken, forType: .string)
        setup.appendLog("✓ 配对令牌已复制到剪贴板")
    }

    private func openLog() {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/BLEUnlockSetup.log")
        NSWorkspace.shared.open(path)
    }

    // MARK: - 安装流程

    private func runInstall(password: String) {
        setup.showProgress()
        setup.setStep(0, total: totalSteps)
        stepIndex = 0

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var failure: String?

            func step(_ title: String, _ work: () -> String?) {
                DispatchQueue.main.sync {
                    self.stepIndex += 1
                    self.setup.appendLog("→ \(title)")
                    self.setup.setStep(Double(self.stepIndex) - 0.5, total: self.totalSteps)
                }
                if let err = work() {
                    failure = err
                    DispatchQueue.main.sync { self.setup.appendLog("✗ \(title) 失败：\(err)") }
                } else {
                    DispatchQueue.main.sync {
                        self.setup.appendLog("✓ \(title)")
                        self.setup.setStep(Double(self.stepIndex), total: self.totalSteps)
                    }
                }
            }

            // 1. 安装服务端
            step("安装服务端程序") {
                if case .failed(let e) = self.installer.installService() { return e }
                return nil
            }
            if failure == nil {
                // 2. 配对密钥
                step(self.alreadyInstalled ? "保留配对密钥" : "生成配对密钥") {
                    if case .failed(let e) = self.installer.ensureKey() { return e }
                    return nil
                }
            }
            if failure == nil {
                // 3. 开机自启
                step("设置开机自启") {
                    if case .failed(let e) = self.installer.installLaunchAgent() { return e }
                    return nil
                }
            }
            if failure == nil {
                // 4. 登录密码
                step("保存登录密码到钥匙串") {
                    if case .failed(let e) = self.installer.storePassword(password) { return e }
                    return nil
                }
            }

            let token = self.installer.pairingToken() ?? ""
            _ = self.installer.verifyPassword()
            self.installer.startService()

            DispatchQueue.main.async {
                if let failure = failure {
                    let logPath = "~/Library/Logs/BLEUnlockSetup.log"
                    self.setup.showFinished(success: false, message: """
                    安装过程中出错，服务端可能未正确配置：

                    \(failure)

                    详细信息见日志：\(logPath)
                    """)
                    diag("安装失败：\(failure)")
                    return
                }
                self.pendingToken = token
                self.finishSuccessfully(token: token)
            }
        }
    }

    private func finishSuccessfully(token: String) {
        let axOK = installer.hasAccessibility()
        diag("安装完成，辅助功能权限：\(axOK)")

        var message = """
        服务端已就绪。

        ───── 配对令牌 ─────
        \(token)
        ───────────────────

        在手机 App 里点「＋ 添加 Mac」，粘贴上面的令牌，然后点「解锁」。
        """

        if axOK {
            didFinishAccessibility = true
            message += "\n\n「辅助功能」权限已授权，一切就绪。"
            setup.showFinished(success: true, message: message)
        } else {
            didFinishAccessibility = false
            message += "\n\n还差最后一步：「辅助功能」权限尚未授权。点下方按钮前往授权。"
            setup.showFinished(success: true, message: message)
            setup.setSecondaryTitle("复制配对令牌")
            setup.setPrimaryTitle("打开系统设置授权")
            setup.onPrimary = { [weak self] _ in self?.startAccessibilityFlow() }
            // 给用户 3 秒读完令牌，再自动引导
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.startAccessibilityFlow()
            }
        }
    }

    // MARK: - 辅助功能权限引导

    private func startAccessibilityFlow() {
        if installer.hasAccessibility() {
            confirmAccessibilityOK()
            return
        }
        setup.appendLog("")
        setup.appendLog("→ 打开「系统设置 → 隐私与安全性 → 辅助功能」")
        setup.appendLog("  在列表中找到 BLEUnlockCmd 并打开开关")
        setup.appendLog("  若列表中没有，点左下角 ＋ 添加：")
        setup.appendLog("  \(Const.serviceBin.path)")
        installer.openAccessibilitySettings()

        // 轮询等待用户完成授权，最多 3 分钟
        accessibilityPollTimer?.invalidate()
        var waited = 0.0
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) {
            [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            waited += 2.0
            if self.installer.hasAccessibility() {
                timer.invalidate()
                self.confirmAccessibilityOK()
            } else if waited >= 180 {
                timer.invalidate()
                self.setup.appendLog("✗ 等待超时，权限仍未生效")
                self.setup.appendLog("  可稍后重新打开本 App，它会再次引导")
            } else if Int(waited) % 20 == 0 {
                self.setup.appendLog("  等待授权中…（已等待 \(Int(waited)) 秒）")
            }
        }
    }

    private func confirmAccessibilityOK() {
        didFinishAccessibility = true
        setup.appendLog("✓ 「辅助功能」权限已生效")
        setup.setPrimaryTitle("完成")
        setup.setSecondaryTitle("复制配对令牌")
        setup.onPrimary = { [weak self] _ in NSApp.terminate(nil) }
        setup.showFinished(success: true, message: """
        全部就绪！现在可以用手机解锁这台 Mac 了。

        ───── 配对令牌 ─────
        \(pendingToken)
        ───────────────────

        在手机 App 里点「＋ 添加 Mac」粘贴令牌，然后点「解锁」。

        如果解锁没反应：
        • 确认 Mac 屏幕已锁定（未锁定时会返回 NOT_LOCKED）
        • 确认手机与 Mac 的蓝牙都已开启
        """)
    }
}
