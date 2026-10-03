// BLE Unlock 安装器 — 程序入口
//
// 这里刻意不用 @main 属性：在只有 Command Line Tools 的 Swift 工具链下，
// @main 合成的入口不会正确驱动 AppKit，applicationDidFinishLaunching 不被调用，
// 表现为「进程在运行但没有窗口」。
//
// 改为显式创建 NSApplication 并手动挂上 delegate，行为可预期。
// 注意 delegate 必须被强引用，否则会被释放导致回调丢失。

import Cocoa

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
