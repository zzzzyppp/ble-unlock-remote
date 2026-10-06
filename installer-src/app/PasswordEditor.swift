// 密码管理窗口
//
// 一台设备可以保存多个登录密码（例如刚改过密码、或同时有多个账户）。
// 解锁时会按这里的顺序逐个尝试，直到屏幕解开。

import Cocoa

final class PasswordEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private let window: NSWindow
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let inputField = NSSecureTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let addButton = NSButton()
    private let removeButton = NSButton()
    private let saveButton = NSButton()
    private let closeButton = NSButton()

    /// 当前编辑中的密码（内存副本，点保存才写回钥匙串）
    private var passwords: [String] = []
    private let installer: Installer
    private var onClose: (() -> Void)?

    init(installer: Installer) {
        self.installer = installer
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = L("管理登录密码")
        window.center()
        super.init()
        passwords = installer.loadPasswords()
        buildUI()
    }

    // MARK: - 界面

    private func buildUI() {
        guard let content = window.contentView else { return }

        let title = NSTextField(labelWithString: L("登录密码（按顺序尝试）"))
        title.font = NSFont.boldSystemFont(ofSize: 15)
        title.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(wrappingLabelWithString:
            L("解锁时会从上到下逐个尝试，直到屏幕解开。")
            + L("如果刚改过密码，可以把新旧密码都留在列表里，避免某天忘记更新。"))
        hint.font = NSFont.systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        // 列表
        let colIndex = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("index"))
        colIndex.title = "#"
        colIndex.width = 34
        let colMask = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mask"))
        colMask.title = L("密码")
        colMask.width = 300
        let colLen = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("len"))
        colLen.title = L("长度")
        colLen.width = 60
        table.addTableColumn(colIndex)
        table.addTableColumn(colMask)
        table.addTableColumn(colLen)
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // 输入
        let addLabel = NSTextField(labelWithString: L("新增："))
        addLabel.translatesAutoresizingMaskIntoConstraints = false
        inputField.placeholderString = L("输入一个登录密码后点「添加」")
        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.target = self
        inputField.action = #selector(addPassword)

        addButton.title = L("添加")
        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addPassword)
        addButton.translatesAutoresizingMaskIntoConstraints = false

        removeButton.title = L("删除选中")
        removeButton.bezelStyle = .rounded
        removeButton.target = self
        removeButton.action = #selector(removeSelected)
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        saveButton.title = L("保存到钥匙串")
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        closeButton.title = L("关闭")
        closeButton.bezelStyle = .rounded
        closeButton.target = self
        closeButton.action = #selector(closeWindow)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        for v in [title, hint, scroll, addLabel, inputField, addButton,
                  removeButton, statusLabel, saveButton, closeButton] {
            content.addSubview(v)
        }

        let m: CGFloat = 20
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: m),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),

            hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),

            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),

            addLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 14),
            addLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            addLabel.widthAnchor.constraint(equalToConstant: 44),

            inputField.centerYAnchor.constraint(equalTo: addLabel.centerYAnchor),
            inputField.leadingAnchor.constraint(equalTo: addLabel.trailingAnchor, constant: 4),
            inputField.heightAnchor.constraint(equalToConstant: 24),

            addButton.centerYAnchor.constraint(equalTo: addLabel.centerYAnchor),
            addButton.leadingAnchor.constraint(equalTo: inputField.trailingAnchor, constant: 8),
            addButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
            addButton.widthAnchor.constraint(equalToConstant: 70),

            removeButton.topAnchor.constraint(equalTo: addButton.bottomAnchor, constant: 8),
            removeButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),

            statusLabel.centerYAnchor.constraint(equalTo: removeButton.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: removeButton.trailingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),

            closeButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -m),
            closeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
            closeButton.widthAnchor.constraint(equalToConstant: 90),

            saveButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            saveButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -10),
            saveButton.widthAnchor.constraint(equalToConstant: 130),

            removeButton.bottomAnchor.constraint(lessThanOrEqualTo: saveButton.topAnchor, constant: -12),
        ])
    }

    // MARK: - 表格数据

    func numberOfRows(in tableView: NSTableView) -> Int {
        passwords.count
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? ""
        let cell: NSTextField
        if let reused = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier(id),
                                           owner: self) as? NSTextField {
            cell = reused
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = NSUserInterfaceItemIdentifier(id)
        }
        switch id {
        case "index":
            cell.stringValue = "\(row + 1)"
            cell.textColor = .secondaryLabelColor
        case "len":
            cell.stringValue = "\(passwords[row].count)"
            cell.textColor = .secondaryLabelColor
        default:
            // 不回显明文，只显示掩码——避免旁人从屏幕上读到密码
            cell.stringValue = String(repeating: "•", count: max(passwords[row].count, 1))
            cell.textColor = .labelColor
        }
        return cell
    }

    private func refresh() {
        table.reloadData()
        removeButton.isEnabled = table.selectedRow >= 0 && !passwords.isEmpty
        statusLabel.stringValue = passwords.isEmpty
            ? L("尚未添加任何密码")
            : L("共 \(passwords.count) 个密码")
        if !passwords.isEmpty && table.selectedRow < 0 {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = table.selectedRow >= 0
    }

    // MARK: - 动作

    @objc private func addPassword() {
        let value = inputField.stringValue
        guard !value.isEmpty else {
            statusLabel.stringValue = L("密码不能为空")
            return
        }
        guard !value.contains("\n") && !value.contains("\r") else {
            statusLabel.stringValue = L("密码不能包含换行符")
            return
        }
        if passwords.contains(value) {
            statusLabel.stringValue = L("这个密码已经在列表里了")
            inputField.stringValue = ""
            return
        }
        passwords.append(value)
        inputField.stringValue = ""
        refresh()
        table.selectRowIndexes(IndexSet(integer: passwords.count - 1),
                               byExtendingSelection: false)
        table.scrollRowToVisible(passwords.count - 1)
        statusLabel.stringValue = L("已添加（尚未保存）")
        window.makeFirstResponder(inputField)
    }

    @objc private func removeSelected() {
        let row = table.selectedRow
        guard row >= 0 && row < passwords.count else { return }
        passwords.remove(at: row)
        refresh()
        statusLabel.stringValue = L("已删除（尚未保存）")
    }

    @objc private func save() {
        if passwords.isEmpty {
            let alert = NSAlert()
            alert.messageText = L("没有密码")
            alert.informativeText = L("至少要保留一个密码，否则解锁会失败。")
            alert.addButton(withTitle: L("好"))
            alert.runModal()
            return
        }
        if installer.savePasswords(passwords) {
            statusLabel.stringValue = L("已保存 \(passwords.count) 个密码到钥匙串 ✓")
            // 通知后台服务刷新（它会重新读钥匙串）
            installer.requestDaemonRefresh()
        } else {
            let alert = NSAlert()
            alert.messageText = L("保存失败")
            alert.informativeText = installer.lastPasswordError
            alert.alertStyle = .critical
            alert.addButton(withTitle: L("好"))
            alert.runModal()
        }
    }

    @objc private func closeWindow() {
        window.orderOut(nil)
        onClose?()
    }

    func present(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
        refresh()
        window.makeKeyAndOrderFront(nil)
        bringToFront()
        window.makeFirstResponder(inputField)
    }
}
