// BLE Unlock 设置向导界面
//
// 用真实窗口承载流程，而不是连串弹窗：
// 每一步都有可见的状态与错误信息，用户能看清卡在哪里。

import Cocoa

final class SetupWindow: NSObject {

    enum Stage {
        case intro          // 欢迎，等待点「开始设置」
        case needPassword   // 等待输入登录密码
        case working        // 正在安装
        case finished       // 完成
    }

    let window: NSWindow
    private let titleLabel = NSTextField(labelWithString: "")
    private let descLabel = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let logView = NSTextView()
    private let passwordField = NSSecureTextField()
    private let passwordLabel = NSTextField(labelWithString: "登录密码：")
    private let primaryButton = NSButton()
    private let secondaryButton = NSButton()
    private let manageButton = NSButton()

    /// 点击主按钮时的回调，参数是当前阶段
    var onPrimary: ((Stage) -> Void)?
    var onSecondary: (() -> Void)?
    /// 点击「管理密码」
    var onManagePasswords: (() -> Void)?

    /// 由 AppDelegate 注入，便于界面直接触发安装动作
    var installer: Installer?

    /// 当前输入的密码
    var passwordValue: String { passwordField.stringValue }

    private(set) var stage: Stage = .intro
    private var startedAt = Date()

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "BLE Unlock 设置"
        window.center()
        super.init()
        buildUI()
    }

    // MARK: - 界面

    private func buildUI() {
        guard let content = window.contentView else { return }
        content.wantsLayer = true

        titleLabel.font = NSFont.boldSystemFont(ofSize: 20)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        descLabel.font = NSFont.systemFont(ofSize: 13)
        descLabel.textColor = .secondaryLabelColor
        descLabel.translatesAutoresizingMaskIntoConstraints = false
        descLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 5
        progress.doubleValue = 0
        progress.translatesAutoresizingMaskIntoConstraints = false

        // 日志区：让用户（和排查问题的我）能看到每一步结果
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        logView.isEditable = false
        logView.drawsBackground = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textContainerInset = NSSize(width: 6, height: 6)
        logView.autoresizingMask = [.width]
        scroll.documentView = logView

        passwordLabel.translatesAutoresizingMaskIntoConstraints = false
        passwordLabel.isHidden = true

        passwordField.translatesAutoresizingMaskIntoConstraints = false
        passwordField.placeholderString = "输入你的 Mac 登录密码"
        passwordField.isHidden = true
        passwordField.target = self
        passwordField.action = #selector(primaryClicked)

        primaryButton.bezelStyle = .rounded
        primaryButton.keyEquivalent = "\r"
        primaryButton.target = self
        primaryButton.action = #selector(primaryClicked)
        primaryButton.translatesAutoresizingMaskIntoConstraints = false

        secondaryButton.bezelStyle = .rounded
        secondaryButton.target = self
        secondaryButton.action = #selector(secondaryClicked)
        secondaryButton.translatesAutoresizingMaskIntoConstraints = false

        // 管理密码：任何时候都可用，方便用户随时增删多个密码
        manageButton.title = "管理密码（可添加多个）"
        manageButton.bezelStyle = .rounded
        manageButton.target = self
        manageButton.action = #selector(manageClicked)
        manageButton.translatesAutoresizingMaskIntoConstraints = false

        for v in [titleLabel, descLabel, progress, scroll, passwordLabel,
                  passwordField, primaryButton, secondaryButton, manageButton] {
            content.addSubview(v)
        }

        let m: CGFloat = 20
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: m),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),

            descLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            descLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            descLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),

            progress.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 14),
            progress.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            progress.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),

            scroll.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),

            passwordLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            passwordLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            passwordLabel.widthAnchor.constraint(equalToConstant: 76),

            passwordField.centerYAnchor.constraint(equalTo: passwordLabel.centerYAnchor),
            passwordField.leadingAnchor.constraint(equalTo: passwordLabel.trailingAnchor, constant: 6),
            passwordField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
            passwordField.heightAnchor.constraint(equalToConstant: 24),

            secondaryButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -m),
            secondaryButton.trailingAnchor.constraint(equalTo: primaryButton.leadingAnchor, constant: -10),
            secondaryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),

            primaryButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -m),
            primaryButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
            primaryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

            manageButton.centerYAnchor.constraint(equalTo: primaryButton.centerYAnchor),
            manageButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),

            scroll.bottomAnchor.constraint(equalTo: primaryButton.topAnchor, constant: -14),
        ])
    }

    // MARK: - 阶段控制

    func showIntro(alreadyInstalled: Bool) {
        stage = .intro
        startedAt = Date()
        titleLabel.stringValue = alreadyInstalled ? "更新 BLE Unlock" : "欢迎使用 BLE Unlock"
        descLabel.stringValue = alreadyInstalled
            ? "检测到已安装。继续操作会更新服务端，并保留你原有的配对密钥。"
            : "接下来会在这台 Mac 上完成以下配置，全程不需要终端："
        appendLog(alreadyInstalled ? "检测到已有安装" : "未检测到已有安装")
        appendLog("")
        appendLog(alreadyInstalled
            ? "1. 更新服务端程序\n2. 保留原有配对密钥\n3. 重新写入登录密码\n4. 设置开机自启"
            : "1. 安装服务端程序\n2. 生成你的专属配对密钥\n3. 把你的登录密码存入钥匙串\n4. 设置开机自启")
        progress.doubleValue = 0
        passwordLabel.isHidden = true
        passwordField.isHidden = true
        passwordField.stringValue = ""
        primaryButton.title = alreadyInstalled ? "开始更新" : "开始设置"
        primaryButton.isEnabled = true
        secondaryButton.title = "退出"
        secondaryButton.isHidden = false
        window.makeFirstResponder(primaryButton)
    }

    func showPassword(alreadyInstalled: Bool) {
        stage = .needPassword
        titleLabel.stringValue = "输入登录密码"
        descLabel.stringValue = """
        蓝牙解锁需要用你的登录密码来自动解锁屏幕。
        密码只存入 macOS 钥匙串，不写入任何文件，也不通过网络传输。
        """
        appendLog("")
        appendLog("等待输入登录密码…")
        passwordLabel.isHidden = false
        passwordField.isHidden = false
        primaryButton.title = "继续"
        secondaryButton.title = "取消"
        window.makeFirstResponder(passwordField)
    }

    func showProgress() {
        stage = .working
        primaryButton.isEnabled = false
        secondaryButton.isHidden = true
        passwordField.isEnabled = false
        primaryButton.title = "正在设置…"
    }

    func setStep(_ done: Double, total: Double) {
        progress.maxValue = total
        progress.doubleValue = done
    }

    func showFinished(success: Bool, message: String) {
        stage = .finished
        primaryButton.isEnabled = true
        secondaryButton.isHidden = false
        progress.doubleValue = progress.maxValue
        if success {
            titleLabel.stringValue = "设置完成"
            descLabel.stringValue = message
            primaryButton.title = "完成"
            secondaryButton.title = "复制配对令牌"
        } else {
            titleLabel.stringValue = "设置未完成"
            descLabel.stringValue = message
            primaryButton.title = "关闭"
            secondaryButton.title = "打开日志"
        }
        window.makeFirstResponder(primaryButton)
    }

    func appendLog(_ text: String) {
        let stamp: String
        if stage == .working {
            stamp = String(format: "  [%5.1fs] ", Date().timeIntervalSince(startedAt))
        } else {
            stamp = ""
        }
        let line = stamp.isEmpty ? text + "\n" : stamp + text + "\n"
        logView.textStorage?.append(NSAttributedString(
            string: line,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: text.hasPrefix("失败") || text.hasPrefix("✗")
                    ? NSColor.systemRed
                    : (text.hasPrefix("✓") ? NSColor.systemGreen : NSColor.labelColor),
            ]))
        logView.scrollToEndOfDocument(nil)
    }

    func shakePassword() {
        passwordField.stringValue = ""
        window.makeFirstResponder(passwordField)
    }

    /// 完成阶段允许 AppDelegate 调整按钮含义（例如改为「打开系统设置授权」）
    func setPrimaryTitle(_ title: String) {
        primaryButton.title = title
        primaryButton.isEnabled = true
    }

    func setSecondaryTitle(_ title: String) {
        secondaryButton.title = title
        secondaryButton.isHidden = false
    }

    /// 回到「等待授权」的可交互状态，但保留已有日志
    func enterWaitingForAccessibility(_ text: String) {
        stage = .finished
        descLabel.stringValue = text
        progress.isHidden = false
        passwordField.isHidden = true
        passwordLabel.isHidden = true
        secondaryButton.isHidden = false
    }

    // MARK: - 动作

    @objc private func primaryClicked() {
        onPrimary?(stage)
    }

    @objc private func secondaryClicked() {
        onSecondary?()
    }

    @objc private func manageClicked() {
        onManagePasswords?()
    }

    func setManageEnabled(_ enabled: Bool) {
        manageButton.isEnabled = enabled
    }

    func present() {
        window.makeKeyAndOrderFront(nil)
        bringToFront()
    }
}
