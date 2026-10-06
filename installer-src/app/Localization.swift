// 本地化
//
// 单构建双语：跟随系统语言自动选择中文或英文。
// 资源位于 BLE Unlock.app/Contents/Resources/{zh-Hans,en}.lproj/Localizable.strings，
// 由 build-installer.sh 从 installer-src/strings/ 复制进去。

import Foundation

/// 取本地化字符串。
///
/// - Important: 务必将结果赋给一个具名变量再用。
///   `NSLocalizedString` 依赖调用处的 `#file`/`#line` 做 key 回退，
///   直接把裸字符串传进来会让回退失效（拿不到原文）。
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// 带格式参数的本地化字符串
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: Bundle.main.localizedString(forKey: key, value: key, table: nil),
           arguments: args)
}
