// ble-test-client.swift — 模拟手机端，用于端到端验证 Mac 服务端
//
// 功能：扫描 BLEUnlockCmd 服务 -> 连接 -> 写入带 HMAC 签名的指令 -> 读回状态
//
// 用法: ble-test-client <base64密钥> [命令]
//        命令: unlock(默认) / lock / ping

import Foundation
import CoreBluetooth
import CryptoKit

let serviceUUID = CBUUID(string: "B1E0A100-0001-4A00-8000-00805F9B0001")
let commandUUID = CBUUID(string: "B1E0A100-0002-4A00-8000-00805F9B0002")
let statusUUID  = CBUUID(string: "B1E0A100-0003-4A00-8000-00805F9B0003")

let args = Array(CommandLine.arguments.dropFirst())
guard let keyBase64 = args.first, let keyData = Data(base64Encoded: keyBase64), keyData.count == 32 else {
    FileHandle.standardError.write("用法: ble-test-client <32字节base64密钥> [unlock|lock|ping]\n".data(using: .utf8)!)
    exit(2)
}
let commandName = args.count > 1 ? args[1] : "unlock"
let command: UInt8
switch commandName {
case "unlock": command = 0x01
case "lock":   command = 0x02
case "ping":   command = 0x03
default:
    FileHandle.standardError.write("未知命令 \(commandName)\n".data(using: .utf8)!)
    exit(2)
}

let key = SymmetricKey(data: keyData)

func say(_ s: String) {
    print(s)
    fflush(stdout)
}

func buildPacket(command: UInt8) -> Data {
    var message = Data()
    message.append(contentsOf: [0x42, 0x55, 0x01, command])
    var ts = UInt64(Date().timeIntervalSince1970).bigEndian
    withUnsafeBytes(of: &ts) { message.append(contentsOf: $0) }
    var nonce = [UInt8](repeating: 0, count: 16)
    for i in 0..<16 { nonce[i] = UInt8.random(in: 0...255) }
    message.append(contentsOf: nonce)
    message.append(contentsOf: [0x00, 0x00])
    let tag = Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
    return message + tag
}

final class Client: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var peripheral: CBPeripheral?
    var commandChar: CBCharacteristic?
    var statusChar: CBCharacteristic?
    var done = false
    var exitCode: Int32 = 1

    func start() {
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func finish(_ code: Int32, _ reason: String) {
        guard !done else { return }
        done = true
        exitCode = code
        say(reason)
        exit(code)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            say("蓝牙状态: \(central.state.rawValue)（等待 poweredOn）")
            if central.state == .unauthorized { finish(3, "蓝牙未授权") }
            return
        }
        say("蓝牙就绪，开始扫描…")
        central.scanForPeripherals(withServices: [serviceUUID], options: nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        say("发现设备 \(peripheral.name ?? "?") RSSI=\(RSSI)dBm，连接中…")
        self.peripheral = peripheral
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        say("已连接，发现服务…")
        peripheral.delegate = self
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finish(4, "连接失败: \(error?.localizedDescription ?? "未知")")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services, !services.isEmpty else {
            finish(4, "未发现目标服务")
            return
        }
        for service in services where service.uuid == serviceUUID {
            peripheral.discoverCharacteristics([commandUUID, statusUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            if c.uuid == commandUUID { commandChar = c }
            if c.uuid == statusUUID {
                statusChar = c
                peripheral.setNotifyValue(true, for: c)
                peripheral.readValue(for: c)
            }
        }
        guard let cmd = commandChar else {
            finish(4, "未找到指令特征")
            return
        }

        let packet = buildPacket(command: command)
        say("发送 \(commandName) 指令（\(packet.count) 字节）")
        // 优先使用带应答写，可靠性更高
        let writeType: CBCharacteristicWriteType =
            cmd.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(packet, for: cmd, type: writeType)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            finish(5, "写入失败: \(error.localizedDescription)")
        } else {
            say("写入成功，等待 Mac 的状态回报…")
            // 读一次状态
            if let s = statusChar { peripheral.readValue(for: s) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == statusUUID, let data = characteristic.value,
              let text = String(data: data, encoding: .utf8) else { return }
        say("Mac 状态: \(text)")

        if text == "OK" {
            finish(0, "✓ 端到端验证成功")
        } else if text.hasPrefix("ERR") {
            finish(6, "✗ Mac 返回错误: \(text)")
        }
    }
}

let client = Client()
client.start()

DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
    client.finish(7, "✗ 超时：25 秒内未完成")
}

RunLoop.main.run()
