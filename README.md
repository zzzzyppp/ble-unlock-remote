# BLE Unlock — 用手机点一下解锁 Mac

手机 App 通过低功耗蓝牙（BLE）发一条带签名的指令给 Mac，Mac 校验通过后自动输入登录密码解锁屏幕。

解锁机制与开源项目 [BLEUnlock](https://github.com/ts1/BLEUnlock) 相同：读取钥匙串里的登录密码，用 `CGEvent` 合成键盘输入到锁屏界面。因此 **Mac 端必须获得「辅助功能」权限**，且**只适用于密码登录**（无法用 Touch ID）。

> 蓝牙通信协议、配对认证（HMAC-SHA256）与防重放设计为本项目自有实现，
> 详见 [LICENSE](LICENSE) 的致谢部分。

---

## 交付物

| 文件 | 说明 |
|---|---|
| `dist/BLEUnlockRemote.apk` | 手机端安装包（已签名，可直接侧载安装） |
| `mac-ble-unlock.sh` | Mac 端一键安装脚本（自包含，内嵌 Swift 源码，无需其他文件） |
| `keystore.jks` | APK 签名密钥，**请勿删除**，否则以后无法覆盖安装升级 |

源码与构建脚本也都在本目录，可随时修改重新构建。

---

## 一、Mac 端

### 安装

```bash
./mac-ble-unlock.sh install
```

脚本会依次完成：

1. 编译 Swift 服务端，打包成 `~/Library/Application Support/BLEUnlockCmd/BLEUnlockCmd.app`
2. 生成 32 字节配对密钥（写入 `config.json`，权限 600）
3. 提示输入登录密码并存入**钥匙串**（服务名 `ble-unlock-cmd`）
4. 引导你授予「辅助功能」权限
5. 注册 LaunchAgent 实现开机自启

安装结束会打印**配对令牌**，手机 App 需要填这个值。

### 常用命令

```bash
./mac-ble-unlock.sh token        # 再次显示配对令牌
./mac-ble-unlock.sh status       # 查看运行状态、权限、最近日志
./mac-ble-unlock.sh check        # 自检（权限 / 密码 / 锁屏状态）
./mac-ble-unlock.sh log          # 实时日志
./mac-ble-unlock.sh restart      # 重启服务
./mac-ble-unlock.sh set-password # 改了登录密码后重新写入钥匙串
./mac-ble-unlock.sh uninstall    # 卸载
```

### 需要授权的两项

| 权限 | 位置 | 不授权的后果 |
|---|---|---|
| 辅助功能 | 系统设置 → 隐私与安全性 → 辅助功能 | 无法注入密码，解锁静默失败 |
| 蓝牙 | 首次运行会弹窗 | 无法广播，手机找不到 Mac |

> 若钥匙串弹出访问请求，务必选**「始终允许」**——锁屏状态下没人能点确认。

### 关于休眠

服务端运行时会创建一个"防空闲休眠"断言，防止系统休眠导致蓝牙广播停止（**显示器仍会正常息屏，屏保和锁定不受影响**）。这是可用的前提：Mac 一旦真正休眠，BLE 广播就停了，手机不可能唤醒它。

如果希望允许系统休眠，可编辑 LaunchAgent 后自行调整；代价是休眠后手机点解锁没有反应。

---

## 二、手机端

1. 把 `dist/BLEUnlockRemote.apk` 传到手机安装（需允许「安装未知来源应用」）
2. 打开 App，授予蓝牙权限（Android 12+ 会请求「附近的设备」）
3. 把 Mac 上打印的**配对令牌**粘贴进输入框，点「保存令牌并连接」
4. 连上后点中间的大按钮**「解锁」**即可

App 使用前台服务保持连接，所以手机锁屏时也能直接解锁 Mac——不用先解锁手机。

### APK 信息

- 包名 `com.bleunlock.remote`，versionCode 1
- minSdk 26（Android 8.0），targetSdk 34
- 无第三方依赖，纯系统 API

---

## 三、工作原理

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
| 3 | 1 | 指令：`0x01` 解锁 / `0x02` 锁定 / `0x03` ping |
| 4 | 8 | Unix 时间戳，大端 UInt64（秒） |
| 12 | 16 | 随机 nonce |
| 28 | 2 | 保留（0） |
| 30 | 32 | `HMAC-SHA256(前 30 字节)` |

服务 UUID `B1E0A100-0001-4A00-8000-00805F9B0001`；指令特征 `...-0002-...`；状态特征 `...-0003-...`；信息特征 `...-0004-...`。

### 安全设计

- **认证**：HMAC-SHA256 + 32 字节预共享密钥。没有令牌无法伪造指令，且无法从空口抓包反推密钥。
- **防重放**：16 字节随机 nonce + 5 分钟缓存去重；时间戳偏差超过 ±120 秒直接拒绝。
- **常量时间比较** HMAC，避免时序侧信道。
- **密码只在本地**：存于 macOS 钥匙串，不经过蓝牙、不落配置文件。

> 注意：BLE 链路本身未加密（未做配对绑定），但指令的**真实性**由 HMAC 保证。攻击者能嗅探到"有一条解锁指令在传输"这个事实，但无法伪造或重放。

---

## 四、已验证 / 未验证

### 已经在本机验证通过

| 项目 | 方法 | 结果 |
|---|---|---|
| Mac 端编译 | `swiftc -O` | 通过 |
| Android 端编译 | aapt2 + javac + d8 + apksigner | 通过，APK 已签名 |
| 两端协议一致性 | 同一测试向量下 Java 与 Swift 的 HMAC 逐字节比对 | 完全一致 |
| HMAC 算法正确性 | RFC 4231 官方向量 + 独立 Python 实现交叉验证 | 通过 |
| 报文校验 | 篡改 HMAC / 错误密钥 / 错魔数 / 过短包 / 过期时间戳 | 全部正确拒绝 |
| 防重放 | 同 nonce 二次发送 | 正确拒绝（ERR_REPLAY） |
| 解锁流程 | dry-run 模式走完整链路 | 行为符合预期 |
| GATT 服务注册与广播 | 实际运行 | 成功，无异常 |
| 自包含脚本 | 在无源码目录下解出内嵌源码并独立编译 | 源码一致、编译通过 |
| 脚本健壮性 | 修复了 zh_CN locale 下 bash 把全角括号并入变量名的解析缺陷（11 处） | 已修复 |

复现命令：

```bash
./verify-protocol.sh                    # 跨语言协议一致性
./build/e2e/BLEUnlockCmd --selftest-protocol   # 协议与解锁流程自检
```

### 尚未验证（需要真机）

**手机与 Mac 之间的实际蓝牙链路**。原因是 macOS 不会把自己发出的广播回报给本机的扫描器，所以同一台 Mac 无法自我验证"手机能否扫描到并连上"。

服务端已确认在正常广播（`正在广播，等待手机连接`），但**扫描 → 连接 → 写入 → 收到 OK** 这最后一段需要你用真机确认。

如果手机搜不到 Mac，见下节排查。

---

## 五、排查

### 手机 App 一直显示"扫描中"

1. 确认 Mac 服务端在跑：`./mac-ble-unlock.sh status`
2. 确认 Mac 蓝牙已开启（系统设置 → 蓝牙）
3. 确认没在 `log` 里看到 `广播失败`
4. 看 App 里的「重新连接」，或重启服务端后重试
5. 安卓的省电策略可能杀掉后台服务：在 设置 → 应用 → BLE Unlock → 电池 里设为「不受限制」

### 显示"指令已送达 Mac"但 Mac 没解锁

按可能性排序：

1. **缺辅助功能权限** —— `./mac-ble-unlock.sh check` 看这一项
2. **钥匙串里没密码** —— 同上；或运行 `set-password`
3. **Mac 屏幕本来就没锁** —— 会返回 `NOT_LOCKED`，这是正常的
4. **配对令牌不一致** —— 会返回 `ERR_HMAC`
5. **手机与 Mac 时间差太多** —— 会返回 `ERR_TIME`，校准手机时间
6. 直接看日志：`./mac-ble-unlock.sh log`

### 提示密码验证失败

登录密码改过之后需要重新写入：`./mac-ble-unlock.sh set-password`

---

## 六、从源码重新构建

```bash
# Mac 端（修改 mac-src/main.swift 后）
./build-mac.sh          # 重新生成自包含的 mac-ble-unlock.sh

# Android 端（修改 android-src/ 后）
export ANDROID_SDK_ROOT="$PWD/toolchain/android-sdk"
./build.sh              # 输出 dist/BLEUnlockRemote.apk
```

`build.sh` 不依赖 Gradle，直接调用 aapt2 / javac / d8 / apksigner，离线可构建。
工具链（JDK、Android SDK）在 `toolchain/` 下，可随时删除，删除后用系统或环境变量里的工具链也能构建。

> 已知问题：build-tools **34.0.0** 自带的 d8 处理本项目代码时会内部报错（R8 的 NPE），
> 因此 `build.sh` 会自动优先选用 35.0.0+。

---

## 七、目录结构

```
ble-unlock/
├── dist/BLEUnlockRemote.apk        ← 手机安装包
├── mac-ble-unlock.sh               ← Mac 一键安装脚本（自包含）
├── mac-src/main.swift              ← Mac 服务端源码
├── template.sh                     ← 生成上面那个 sh 的模板
├── build-mac.sh                    ← 生成自包含脚本
├── android-src/                    ← Android 源码
│   ├── AndroidManifest.xml
│   ├── java/com/bleunlock/remote/{Protocol,BleService,MainActivity}.java
│   └── res/
├── build.sh                        ← 构建 APK
├── verify-protocol.sh              ← 跨语言协议一致性验证
├── tools/
│   ├── VerifyProtocol.java         ← 协议验证工具
│   ├── ble-test-client.swift       ← 模拟手机端的测试客户端
│   └── make_icons.py               ← 生成启动图标
├── keystore.jks                    ← APK 签名密钥（勿删）
└── toolchain/                      ← 便携 JDK 与 Android SDK（可删）
```
