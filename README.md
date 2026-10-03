# BLE Unlock

**用手机点一下，解锁你的 Mac。** 不用走过去按指纹，也不用输密码。

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: macOS 11+](https://img.shields.io/badge/macOS-11%2B-black.svg)](#系统要求)
[![Platform: Android 8+](https://img.shields.io/badge/Android-8.0%2B-3DDC84.svg)](#系统要求)
[![Release](https://img.shields.io/github/v/release/zzzzyppp/ble-unlock-remote)](https://github.com/zzzzyppp/ble-unlock-remote/releases/latest)

手机通过低功耗蓝牙（BLE）向 Mac 发送一条带 **HMAC-SHA256 签名**的指令，Mac 校验通过后
自动输入登录密码解锁屏幕。一台手机可以保存多台 Mac 的密钥，随时切换。

---

## 特性

- **一键解锁** —— 手机点一下，Mac 自动解锁，响应约 1 秒
- **每台设备可存多个密码** —— 解锁时逐个尝试；手机上可指定优先用哪一个，默认第一个
- **手机锁屏也能用** —— 前台服务保持 BLE 连接，不必先解锁手机
- **支持多台 Mac** —— 每台各自一个令牌，App 内切换
- **指令有签名** —— HMAC-SHA256 认证 + nonce 防重放 + 时间戳校验
- **密码不出本机** —— 存于 macOS 钥匙串，不经蓝牙传输，不写入配置文件
- **Mac 端零依赖** —— 单个自包含脚本，编译 + 配置 + 开机自启一次完成
- **无 Gradle、无第三方库** —— APK 直接调用 aapt2/javac/d8/apksigner 构建

---

## 下载

**从 [Releases](https://github.com/zzzzyppp/ble-unlock-remote/releases/latest) 下载**：

| 文件 | 适用 | 说明 |
|---|---|---|
| `BLEUnlock-*.dmg` | **推荐** | 拖到「应用程序」即安装，打开后在界面内完成配置。**不需要终端，也不需要 Xcode**。仅 Apple Silicon |
| `mac-ble-unlock.sh` | Intel Mac / 偏好命令行 | 自包含脚本。需要 Xcode Command Line Tools，会现场编译 |
| `BLEUnlockRemote.apk` | 手机端 | Android 安装包（已签名，可直接侧载） |
| `SHA256SUMS.txt` | — | 校验值 |

校验下载内容：

```bash
shasum -a 256 -c SHA256SUMS.txt
```

---

## 快速开始

### 1. Mac 端

#### 方式 A：拖拽安装（推荐）

1. 下载 DMG，双击打开
2. 把左边的 **BLE Unlock** 拖到右边的 **Applications**
3. 打开「应用程序」里的 **BLE Unlock**
4. **右键点击 App → 选择「打开」→ 再点「打开」**

   > 只需做一次。本项目没有 Apple 开发者签名证书，无法通过公证。

5. 按界面提示输入一次登录密码，其余全自动完成
6. 按引导授权「辅助功能」权限，并记下**配对令牌**

> 请从「应用程序」运行，不要直接在 DMG 里运行——DMG 是只读的，
> 且系统会给它分配随机路径，会导致权限无法保存。

再次打开本 App 即为重新配置/更新，**配对密钥会保留**，手机端无需改动。

#### 方式 B：命令行脚本

适合 Intel Mac，或偏好命令行的用户。需要先装编译工具：

```bash
xcode-select --install
```

然后：

```bash
chmod +x mac-ble-unlock.sh
./mac-ble-unlock.sh install
```

#### 装好后自检

```bash
./mac-ble-unlock.sh status     # 仅方式 B 有脚本；方式 A 用下面的命令
~/Library/Application\ Support/BLEUnlockCmd/BLEUnlockCmd.app/Contents/MacOS/BLEUnlockCmd --check
```

### 2. 手机端

1. 安装 `BLEUnlockRemote.apk`（需允许「安装未知来源应用」）
2. 打开 App，授予蓝牙权限（Android 12+ 会请求「附近的设备」）
3. 点「＋ 添加 Mac」，填备注名，粘贴 Mac 上打印的**配对令牌**
4. 点中间的大按钮「解锁」

### 3. 多台 Mac

每台 Mac 各自跑一次安装脚本、各自得到令牌，在 App 里「＋ 添加 Mac」逐台加入。
用「切换 Mac」切换，`●` 表示当前连接的那台。同一时刻只连接选中的那一台。

---

## 多密码

每台设备可以保存多个登录密码，解锁时**从上到下逐个尝试**，直到屏幕解开。

**用途**：刚改过登录密码、但还没在所有地方更新完时，把新旧密码都留在列表里，
避免某天手机解不开锁。也适用于同一台 Mac 上有多个账户的情况。

### 手机上选择用哪个密码

手机端新增「**填充密码**」按钮，可以从列表里选"用 Mac 上的第几个密码"解锁。
**默认使用第一个**。

- 手机**不保存密码本身**——密码始终只存在 Mac 的钥匙串里。
  手机记录的只是"位次"，以及你给该位次起的名字（如「当前密码」「旧密码」）
- 点「填充密码」→ 选一个位次；点「给位次起名」可以把「密码 2」改成有意义的称呼
- 发送解锁指令时带上该位次，Mac 会**优先试它**；万一它不对，
  会自动回退继续试其余密码，不会因为选错就解不开

> 位次是位置而非身份：如果你在 Mac 上增删或调换了密码顺序，
> 手机里选的位次所指的密码可能就变了，请重新确认。

### 管理方式（Mac 端）

- 图形安装器：打开 App，点「管理密码（可添加多个）」
- 命令行：

```bash
SVC=~/Library/Application\ Support/BLEUnlockCmd/BLEUnlockCmd.app/Contents/MacOS/BLEUnlockCmd

"$SVC" --passwords list              # 查看（打码显示）
"$SVC" --passwords list --json       # 只输出数量与各密码长度
printf 'pw\n' | "$SVC" --passwords add        # 追加一个
printf 'a\nb\n\n' | "$SVC" --passwords set   # 整体替换（空行结束）
"$SVC" --passwords remove --index 2  # 删除第 2 个
"$SVC" --passwords clear             # 清空
```

**实现要点**：

- 全部密码存在钥匙串里的**一个条目**中（JSON 数组），不落任何文件
- 顺序即尝试顺序；每个密码注入后等待约 1.2 秒确认屏幕是否已解开，无效才试下一个
- 尝试下一个之前会先发一次 Esc 清空输入框，避免上一个密码的残留内容混入
- 兼容旧格式：如果钥匙串里是单个明文密码（早期版本就是这么存的），会被当作一个密码
- **密码不能含换行符**：录入是按行的，含换行会被拆开，因此程序会明确拒绝并提示
- 非 ASCII 密码（中文、重音字母等）会被 macOS 钥匙串转成 NFD 分解形式存储，
  程序统一按 NFC 归一，保证存取与比较一致

---

## 必须授权的两项

| 权限 | 位置 | 不授权的后果 |
|---|---|---|
| 辅助功能 | 系统设置 → 隐私与安全性 → 辅助功能 | 无法注入密码，解锁静默失败 |
| 蓝牙 | 首次运行会弹窗 | 无法广播，手机找不到 Mac |

> 钥匙串若弹出访问请求，务必选**「始终允许」**——锁屏状态下没人能点确认。

---

## 工作原理

解锁机制与开源项目 [BLEUnlock](https://github.com/ts1/BLEUnlock) 相同：
读取钥匙串中的登录密码，用 `CGEvent` 合成键盘输入到锁屏界面。

```
┌──────────────┐                      ┌────────────────────────────┐
│  Android App │                      │  Mac (BLE 外设/GATT 服务端) │
│              │  1. 扫描服务 UUID    │                            │
│  BLE Central │ ───────────────────► │  CBPeripheralManager 广播   │
│              │  2. 写入 62 字节指令 │                            │
│              │ ───────────────────► │  校验 HMAC-SHA256          │
│              │                      │  校验时间戳 + nonce 防重放   │
│              │  3. 订阅状态推送      │                            │
│              │ ◄─────────────────── │  回 "OK" / "ERR_*"         │
└──────────────┘                      │            │               │
                                      │            ▼               │
                                      │  唤醒屏幕 → 确认锁屏        │
                                      │  → 从钥匙串取密码           │
                                      │  → CGEvent 注入密码+回车    │
                                      └────────────────────────────┘
```

### 数据包格式（62 字节）

| 偏移 | 长度 | 内容 |
|---|---|---|
| 0 | 2 | 魔数 `"BU"` (0x42 0x55) |
| 2 | 1 | 协议版本 `0x01` |
| 3 | 1 | 指令：`0x01` 解锁 / `0x02` 锁定 / `0x03` ping / `0x04` 指定密码解锁 |
| 4 | 8 | Unix 时间戳，大端 UInt64（秒） |
| 12 | 16 | 随机 nonce |
| 28 | 1 | 密码序号（0 基）。仅「指定密码解锁」指令使用；受 HMAC 保护 |
| 29 | 1 | 保留（0） |
| 30 | 32 | `HMAC-SHA256(前 30 字节)` |

服务 UUID `B1E0A100-0001-4A00-8000-00805F9B0001`；指令特征 `...-0002-...`；
状态特征 `...-0003-...`；信息特征 `...-0004-...`。

### 安全设计

- **认证**：HMAC-SHA256 + 32 字节预共享密钥。没有令牌无法伪造指令，
  也无法从空口抓包反推密钥。
- **防重放**：16 字节随机 nonce + 5 分钟缓存去重；时间戳偏差超过 ±120 秒直接拒绝。
- **常量时间比较** HMAC，避免时序侧信道。
- **密码只在本地**：存于 macOS 钥匙串，不经过蓝牙、不落配置文件。

---

## ⚠️ 安全须知

**本项目把"输入密码"这件事自动化了，请理解它的安全边界后再使用。**

### 1. 密钥推导：请勿公开分发你自己的构建产物

手机 App 内置了从 `mac-ble-unlock.sh` 推导密钥的算法。
**同时拿到「你自己构建的脚本」和「APK」的人，可以推算出你的配对密钥**，
进而伪造解锁指令。

- 从本仓库下载的官方文件**不含任何人的密钥**（密钥是每台 Mac 安装时在本机生成的）
- 但如果你把它**当作产品分发给别人**，等于把解锁能力一起给了对方

请把这两样东西当作密码保管。本项目的定位是**自用工具**。

### 2. 它无法抵御的攻击

- **能物理接触你 Mac 的攻击者**：本项目依赖 macOS 的辅助功能与钥匙串，
  不改变这些信任边界
- **BLE 嗅探者**：能看到"有一条解锁指令在传输"，但无法伪造或重放
  （指令真实性由 HMAC 保证；链路本身未加密，未做配对绑定）

### 3. 已知限制

- 仅支持**密码登录**，无法用 Touch ID / Apple Watch 解锁（合成按键无法替代生物识别）
- 服务端运行时会阻止**系统空闲休眠**，以保证蓝牙广播不被中断
  （显示器仍会正常息屏、锁定；屏保不受影响）
- Mac 真正休眠后蓝牙广播会停止，此时手机点解锁不会有反应

---

## 系统要求

| | |
|---|---|
| macOS | 11 及以上（服务端） |
| CPU | **Apple Silicon**（拖拽安装包）；Intel Mac 请用命令行脚本 |
| Android | 8.0 及以上（minSdk 26，targetSdk 34） |
| Swift | 仅方式 B 需要 Xcode Command Line Tools |

> **为什么安装包只有 Apple Silicon 版？**
> 本项目在只有 Command Line Tools（无完整 Xcode）的环境下构建，
> 而其 Swift 兼容库只包含 arm64（`libswiftCompatibility56.a` 为 arm64/arm64e），
> 无法交叉编译 x86_64。Intel Mac 请用命令行脚本方式，它会在本机现场编译。
>
> 如果你有完整 Xcode，可以用 `build-installer.sh` 自行构建：
> `ARCH=arm64` 或改用通用二进制目标。

---

## 已验证 / 未验证

### 已经验证通过

| 项目 | 方法 | 结果 |
|---|---|---|
| 两端协议一致性 | 同一测试向量下 Java 与 Swift 的 HMAC 逐字节比对 | 完全一致 |
| HMAC 算法正确性 | RFC 4231 官方向量 + 独立 Python 实现交叉验证 | 通过 |
| 报文校验 | 篡改 HMAC / 错误密钥 / 错魔数 / 过短包 / 过期时间戳 | 全部正确拒绝 |
| 防重放 | 同 nonce 二次发送 | 正确拒绝（`ERR_REPLAY`） |
| 令牌解析 | base64 / URL-safe / 大小写十六进制 / 带分隔符 / 各类非法输入 | 符合预期 |
| 多密钥存储 | 真实 `org.json` 语义下的往返、转义、损坏数据容错 | 通过 |
| 旧数据迁移 | 单令牌自动迁移为一条记录，令牌保持可用 | 通过 |
| 解锁流程 | dry-run 模式走完整链路 | 行为符合预期 |
| 真机闭环 | 手机 → BLE → Mac → 注入密码 → 解锁成功 | 成功（日志 `解锁结果: OK`） |
| GATT 注册与广播 | 实际运行 | 成功，无异常 |
| APK 构建与签名 | aapt2 + javac + d8 + apksigner | 通过 |

复现命令：

```bash
./verify-protocol.sh       # 跨语言协议一致性
./verify-multikey.sh       # 令牌解析 / 多密钥存储 / 迁移
./build/e2e/BLEUnlockCmd --selftest-protocol   # 协议与解锁流程自检
```

> `verify-multikey.sh` 需要一点技巧：`android.jar` 里的 `android.util.Base64` 与
> `org.json` 都是 `throw new RuntimeException("Stub!")` 占位实现，直接跑会抛异常。
> 因此 `tools/testdoubles/` 提供了语义一致的**真实替身实现**覆盖掉 Stub，
> 从而能在电脑上验证真正的生产代码逻辑。

### 尚未验证

- **多台 Mac 的界面点击流程**（列表切换、重命名、删除）：逻辑层已验证，
  界面交互需要真机确认
- **macOS 大版本升级后的兼容性**：使用了 `login.framework` 私有 API 锁屏
  （带屏保回退），大版本升级后建议重新验证

---

## 排查

### 手机 App 一直显示"扫描中"

1. 确认 Mac 服务端在跑：`./mac-ble-unlock.sh status`
2. 确认 Mac 蓝牙已开启（系统设置 → 蓝牙）
3. 确认日志里没有 `广播失败`
4. 点 App 里的「重新连接」，或重启服务端后重试
5. 安卓省电策略可能杀掉后台服务：设置 → 应用 → BLE Unlock → 电池 → 设为「不受限制」

### 显示"指令已送达 Mac"但 Mac 没解锁

按可能性排序：

1. **缺辅助功能权限** —— `./mac-ble-unlock.sh check`
2. **钥匙串里没密码** —— 同上；或运行 `set-password`
3. **Mac 屏幕本来就没锁** —— 会返回 `NOT_LOCKED`，属正常
4. **配对令牌不一致** —— 会返回 `ERR_HMAC`
5. **手机与 Mac 时间差太多** —— 会返回 `ERR_TIME`，校准手机时间
6. 直接看日志：`./mac-ble-unlock.sh log`

### 提示密码验证失败

改过登录密码后需重新写入：`./mac-ble-unlock.sh set-password`

---

## 从源码构建

```bash
# Mac 端（修改 mac-src/main.swift 后）
./build-mac.sh          # 重新生成自包含的 mac-ble-unlock.sh

# Android 端（修改 android-src/ 后）
export ANDROID_SDK_ROOT="$PWD/toolchain/android-sdk"
./build.sh              # 输出 dist/BLEUnlockRemote.apk
```

`build.sh` 不依赖 Gradle，直接调用 aapt2 / javac / d8 / apksigner，离线可构建。
需要 JDK 17+ 与 Android SDK（`platforms/android-34` + `build-tools` 34 或更高）。

> 已知问题：build-tools **34.0.0** 自带的 d8 处理本项目代码时会内部报错（R8 的 NPE），
> 因此 `build.sh` 会自动优先选用 35.0.0+。

### 安装包内部结构

服务端以「嵌套 app」形式打进设置 App，而不是散落的裸二进制：

```
BLE Unlock.app                          ← 拖进「应用程序」的设置 App
└── Contents/
    ├── MacOS/BLEUnlockSetup            ← 设置向导
    └── Resources/
        └── BLEUnlockCmd.app            ← 嵌套的服务端（安装时整体复制出去）
            └── Contents/
                ├── Info.plist          ← 含蓝牙用途说明，是弹授权框的前提
                ├── PkgInfo
                ├── MacOS/BLEUnlockCmd  ← 实际执行解锁的守护进程
                └── Resources/capabilities  ← 能力标记
```

签名由内向外：先签嵌套的服务端，再签外层设置 App；安装时用 `ditto`
整体复制，以保留嵌套代码的签名与扩展属性。

> 安装后服务端位于
> `~/Library/Application Support/BLEUnlockCmd/BLEUnlockCmd.app`。
> **「辅助功能」授权要授予这个位置的可执行文件**，而不是「应用程序」里的
> BLE Unlock —— 后者只是设置 App，授权给它不会让后台服务获得权限。

### APK 签名密钥

密钥**不在仓库里**。`build.sh` 按以下顺序查找：

1. 环境变量 `BLEUNLOCK_KEYSTORE_DIR`
2. `~/.config/ble-unlock/` ← 默认
3. 项目目录（兼容早期版本）

都找不到时自动新建并收紧权限（目录 700 / 文件 600）。
**密钥丢失后无法对已安装的 APK 做覆盖升级**，请自行备份。

---

## 目录结构

```
├── dist/BLEUnlockRemote.apk        ← 手机安装包
├── mac-ble-unlock.sh               ← Mac 一键安装脚本（自包含）
├── mac-src/main.swift              ← Mac 服务端源码
├── template.sh                     ← 生成上面那个 sh 的模板
├── build-mac.sh                    ← 生成自包含脚本
├── android-src/                    ← Android 源码
│   ├── AndroidManifest.xml
│   ├── java/com/bleunlock/remote/
│   │   ├── Protocol.java           ← 协议与令牌解析
│   │   ├── MacEntryStore.java      ← 多台 Mac 的密钥存储
│   │   ├── BleService.java         ← 前台服务，维持 BLE 连接
│   │   └── MainActivity.java       ← 界面
│   └── res/
├── build.sh                        ← 构建 APK
├── build-installer.sh              ← 构建拖拽安装包（.dmg）
├── installer-src/                  ← 安装 App 源码
│   ├── app/                        ← App 本体
│   │   ├── main.swift              ← 入口（显式 NSApplication）
│   │   ├── AppDelegate.swift       ← 流程编排
│   │   ├── SetupWindow.swift       ← 设置向导界面
│   │   ├── Installer.swift         ← 安装逻辑
│   │   └── BuildInfo.swift         ← 版本信息（构建时生成）
│   └── test/                       ← 安装逻辑的端到端测试
├── verify-protocol.sh              ← 跨语言协议一致性验证
├── verify-multikey.sh              ← 令牌解析 / 多密钥存储 / 迁移验证
└── tools/
    ├── VerifyProtocol.java         ← 协议验证工具
    ├── VerifyMultiKey.java         ← 多密钥验证工具
    ├── testdoubles/                ← android.jar Stub 的真实替身（仅测试用）
    ├── ble-test-client.swift       ← 模拟手机端的测试客户端
    └── make_icons.py               ← 生成启动图标
```

---

## 致谢

解锁机制（读取钥匙串密码 + `CGEvent` 合成键盘输入 + `login.framework` 锁屏）
参考自 Takeshi Sone 的 [BLEUnlock](https://github.com/ts1/BLEUnlock)（MIT 许可）。

本项目为**独立实现**，未复制其源代码；蓝牙 GATT 通信协议、配对认证（HMAC-SHA256）
与防重放设计均为本项目自有。

---

## 许可

[MIT](LICENSE)
