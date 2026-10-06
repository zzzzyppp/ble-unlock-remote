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
    private var passwordEditor: PasswordEditor?

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
        setup.onManagePasswords = { [weak self] in self?.openPasswordEditor() }
        setup.present()

        if alreadyInstalled, let daemonAX = installer.daemonAccessibility() {
            setup.appendLog(daemonAX
                ? L("检测到服务端与辅助功能权限均已就绪")
                : L("检测到服务端已安装，但守护进程缺少「辅助功能」权限"))
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
        appMenu.addItem(withTitle: L("关于 \(name)"),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: L("退出 \(name)"),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = mainMenu
    }

    /// Gatekeeper 会把未公证的 App 放到随机只读路径运行。
    /// 该路径每次启动都不同，会导致辅助功能权限无法稳定绑定。
    private func isTranslocated() -> Bool {
        Bundle.main.bundlePath.contains("/AppTranslocation/")
    }

    /// 打开密码管理窗口
    private func openPasswordEditor() {
        if !FileManager.default.isExecutableFile(atPath: Const.serviceBin.path) {
            alert(L("尚未安装"), L("请先完成设置，之后即可在这里管理密码。"))
            return
        }
        if passwordEditor == nil {
            passwordEditor = PasswordEditor(installer: installer)
        }
        passwordEditor?.present { [weak self] in
            // 关闭后刷新主窗口的说明，便于用户看到密码数量变化
            self?.setup.appendLog(L("密码管理窗口已关闭"))
        }
    }

    // MARK: - 按钮分发

    private func handlePrimary(_ stage: SetupWindow.Stage) {
        switch stage {
        case .intro:
            setup.showPassword(alreadyInstalled: alreadyInstalled)
        case .needPassword:
            let password = setup.passwordValue
            if password.isEmpty {
                setup.appendLog(L("✗ 密码不能为空，请重新输入"))
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
        setup.appendLog(L("✓ 配对令牌已复制到剪贴板"))
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
                    DispatchQueue.main.sync { self.setup.appendLog(L("✗ \(title) 失败：\(err)")) }
                } else {
                    DispatchQueue.main.sync {
                        self.setup.appendLog("✓ \(title)")
                        self.setup.setStep(Double(self.stepIndex), total: self.totalSteps)
                    }
                }
            }

            // 1. 安装服务端
            step(L("安装服务端程序")) {
                if case .failed(let e) = self.installer.installService() { return e }
                return nil
            }
            if failure == nil {
                // 2. 配对密钥
                step(self.alreadyInstalled ? L("保留配对密钥") : L("生成配对密钥")) {
                    if case .failed(let e) = self.installer.ensureKey() { return e }
                    return nil
                }
            }
            if failure == nil {
                // 3. 开机自启
                step(L("设置开机自启")) {
                    if case .failed(let e) = self.installer.installLaunchAgent() { return e }
                    return nil
                }
            }
            if failure == nil {
                // 4. 登录密码
                step(L("保存登录密码到钥匙串")) {
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
                    self.setup.showFinished(success: false, message: L("""
                    安装过程中出错，服务端可能未正确配置：

                    \(failure)

                    详细信息见日志：\(logPath)
                    """))
                    diag("安装失败：\(failure)")
                    return
                }
                self.pendingToken = token
                self.finishSuccessfully(token: token)
            }
        }
    }

    private func finishSuccessfully(token: String) {
        // 关键：先清掉旧的守护进程状态，再启动服务，
        // 这样随后读到的必然是本次启动的真实权限判定。
        installer.clearDaemonStatus()
        installer.startService()

        // 等守护进程自己报告权限状态。不能用向导自己的子进程去问——
        // TCC 的辅助功能信任会从父进程继承，向导自身受信任时子进程会假报L("已授权")。
        let daemonAX = installer.waitForDaemonStatus(timeout: 12)
        diag("守护进程权限状态: \(daemonAX.map { $0 ? "已授权" : "未授权" } ?? "未报告")")

        var message = L("""
        服务端已就绪。

        ───── 配对令牌 ─────
        \(token)
        ───────────────────

        在手机 App 里点「＋ 添加 Mac」，粘贴上面的令牌，然后点「解锁」。
        """)

        if daemonAX == true {
            didFinishAccessibility = true
            message += L("\n\n「辅助功能」权限已确认，一切就绪。")
            setup.showFinished(success: true, message: message)
        } else {
            didFinishAccessibility = false
            if daemonAX == nil {
                setup.appendLog(L("⚠️ 守护进程未报告权限状态，请确认它已启动"))
            }
            message += L("""


            还差最后一步：「辅助功能」权限尚未授予**真正运行的守护进程**。

            注意：这一项必须授予 BLEUnlockCmd，而不是本设置 App。
            若系统设置里该项开关已是打开状态，请先删除它再重新添加——
            旧授权可能绑定到了旧版本的程序。
            """)
            setup.showFinished(success: true, message: message)
            setup.setSecondaryTitle(L("复制配对令牌"))
            setup.setPrimaryTitle(L("打开系统设置授权"))
            setup.onPrimary = { [weak self] _ in self?.startAccessibilityFlow() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.startAccessibilityFlow()
            }
        }
    }

    // MARK: - 辅助功能权限引导

    private func startAccessibilityFlow() {
        // 先让守护进程刷新一次（也许用户刚刚已经授权了）
        installer.requestDaemonRefresh()
        Thread.sleep(forTimeInterval: 0.8)
        if installer.daemonAccessibility() == true {
            confirmAccessibilityOK()
            return
        }

        if setup.stage != .finished || !didFinishAccessibility {
            setup.appendLog("")
            setup.appendLog(L("→ 打开「系统设置 → 隐私与安全性 → 辅助功能」"))
            setup.appendLog("")
            setup.appendLog(L("  请把下面这个文件拖进列表（或点 ＋ 选择它）："))
            setup.appendLog("  \(Const.serviceBin.path)")
            setup.appendLog("")
            setup.appendLog(L("  ⚠️ 要添加的是上面这个路径，不是「应用程序」里的 BLE Unlock。"))
            setup.appendLog(L("     两者是不同的程序；授权给 App 不会让后台服务获得权限。"))
            setup.appendLog("")
            setup.appendLog(L("  若列表里已有一条 BLEUnlockCmd 且开关是打开的却仍无效，"))
            setup.appendLog(L("  请先用「−」删除它，再重新添加一次。"))
        }
        installer.openAccessibilitySettings()
        // 同时在 Finder 里定位该文件，方便用户直接拖拽
        NSWorkspace.shared.activateFileViewerSelecting([Const.serviceBin])

        // 轮询：每次让守护进程刷新状态，再读它自己的判定。
        // 绝不能问本 App 的子进程——那会因继承信任而假报已授权。
        accessibilityPollTimer?.invalidate()
        var waited = 0.0
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) {
            [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            waited += 2.5
            self.installer.requestDaemonRefresh()
            if self.installer.daemonAccessibility() == true {
                timer.invalidate()
                self.confirmAccessibilityOK()
            } else if waited >= 240 {
                timer.invalidate()
                self.setup.appendLog(L("✗ 等待超时，守护进程仍未获得权限"))
                self.setup.appendLog(L("  可重新打开本 App，它会再次引导并复查"))
            } else if Int(waited) % 30 == 0 {
                self.setup.appendLog(L("  仍在等待授权…（已等待 \(Int(waited)) 秒）"))
                self.setup.appendLog(L("  提示：授权对象是 BLEUnlockCmd，不是本设置 App"))
            }
        }
    }

    private func confirmAccessibilityOK() {
        didFinishAccessibility = true
        setup.appendLog(L("✓ 「辅助功能」权限已生效"))
        setup.setPrimaryTitle(L("完成"))
        setup.setSecondaryTitle(L("复制配对令牌"))
        setup.onPrimary = { [weak self] _ in NSApp.terminate(nil) }
        setup.showFinished(success: true, message: L("""
        全部就绪！现在可以用手机解锁这台 Mac 了。

        ───── 配对令牌 ─────
        \(pendingToken)
        ───────────────────

        在手机 App 里点「＋ 添加 Mac」粘贴令牌，然后点「解锁」。

        如果解锁没反应：
        • 确认 Mac 屏幕已锁定（未锁定时会返回 NOT_LOCKED）
        • 确认手机与 Mac 的蓝牙都已开启
        """))
    }
}
