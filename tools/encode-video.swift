// 把 PNG 序列编码成 H.264 MP4。
//
// 用 macOS 自带的 AVFoundation，不需要 ffmpeg。
//
// 实现注记（踩过的坑，别再走一遍）：
//   * VTCompressionSessionEncodeFrame 在本机（macOS 27 / CLT SDK）**必定段错误**，
//     连最小复现（320x240、默认参数、无回调）也会崩在函数内部，
//     与是否 Prepare、duration 是否 invalid、有无 hardware spec 都无关。
//     所以不要试图用 VTCompressionSession 换取更精细的码率控制。
//   * AVAssetWriter 会忽略 AVVideoAverageBitRateKey：无论请求 0.5 还是 8 Mbps，
//     实际输出都约 0.27 Mbps。想要更清晰的画面只能提高渲染分辨率，
//     不能靠加码率——参数留着但请知悉它不生效。
//
// 用法:
//   encode-video <帧目录> <输出.mp4> [--fps 30] [--bitrate 8]

import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(
        "用法: encode-video <帧目录> <输出.mp4> [--fps 30]\n".data(using: .utf8)!)
    exit(2)
}
let frameDir = args[1]
let outPath = args[2]

var fps = 30
var bitrateMbps = 8.0
var i = 3
while i < args.count {
    switch args[i] {
    case "--fps":
        i += 1; if i < args.count, let v = Int(args[i]) { fps = max(1, v) }
    case "--bitrate":
        i += 1; if i < args.count, let v = Double(args[i]) { bitrateMbps = max(0.5, v) }
    default: break
    }
    i += 1
}

// ---------------------------------------------------------------- 帧列表

let fm = FileManager.default
let files = ((try? fm.contentsOfDirectory(atPath: frameDir)) ?? [])
    .filter { $0.lowercased().hasSuffix(".png") }.sorted()
guard !files.isEmpty else {
    FileHandle.standardError.write("帧目录里没有 PNG: \(frameDir)\n".data(using: .utf8)!)
    exit(1)
}

func loadImage(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)
    else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

guard let first = loadImage(frameDir + "/" + files[0]) else {
    FileHandle.standardError.write("无法读取第一帧\n".data(using: .utf8)!)
    exit(1)
}
// H.264 的 4:2:0 色度采样要求宽高为偶数
var width = first.width
var height = first.height
if width % 2 != 0 { width -= 1 }
if height % 2 != 0 { height -= 1 }

// ---------------------------------------------------------------- 编码器

try? fm.removeItem(atPath: outPath)
guard let writer = try? AVAssetWriter(outputURL: URL(fileURLWithPath: outPath),
                                      fileType: .mp4) else {
    FileHandle.standardError.write("无法创建输出文件\n".data(using: .utf8)!)
    exit(1)
}

let videoSettings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: Int(bitrateMbps * 1_000_000),
        AVVideoMaxKeyFrameIntervalKey: fps * 2,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoAllowFrameReorderingKey: true,
    ],
]

let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
input.expectsMediaDataInRealTime = false

let attrs: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
]
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input, sourcePixelBufferAttributes: attrs)

guard writer.canAdd(input) else {
    FileHandle.standardError.write("无法添加视频轨\n".data(using: .utf8)!)
    exit(1)
}
writer.add(input)

guard writer.startWriting() else {
    FileHandle.standardError.write(
        "startWriting 失败: \(writer.error?.localizedDescription ?? "未知")\n"
            .data(using: .utf8)!)
    exit(1)
}
writer.startSession(atSourceTime: .zero)

// ---------------------------------------------------------------- 逐帧写入

guard let pool = adaptor.pixelBufferPool else {
    FileHandle.standardError.write("没有 pixelBufferPool\n".data(using: .utf8)!)
    exit(1)
}

var frameIndex = 0
var written = 0

func writeFrame(_ img: CGImage) -> Bool {
    var pb: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess,
          let buffer = pb else { return false }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }

    guard let ctx = CGContext(data: base, width: width, height: height,
                              bitsPerComponent: 8,
                              bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else {
        return false
    }
    ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))

    let t = CMTime(value: Int64(frameIndex), timescale: Int32(fps))
    return adaptor.append(buffer, withPresentationTime: t)
}

// AVAssetWriterInput 不是线程安全的，全部在这一个队列上串行写入
let allDone = DispatchSemaphore(value: 0)
let encodeQueue = DispatchQueue(label: "bleunlock.encode")

input.requestMediaDataWhenReady(on: encodeQueue) {
    while input.isReadyForMoreMediaData {
        if frameIndex >= files.count {
            input.markAsFinished()
            allDone.signal()
            return
        }
        let path = frameDir + "/" + files[frameIndex]
        if let img = loadImage(path) {
            if writeFrame(img) { written += 1 }
        } else {
            FileHandle.standardError.write("跳过无法读取的帧: \(path)\n".data(using: .utf8)!)
        }
        frameIndex += 1
        if frameIndex % 60 == 0 {
            FileHandle.standardError.write("  已编码 \(frameIndex)/\(files.count) 帧\r"
                .data(using: .utf8)!)
        }
    }
    // 编码器暂时不收，等它腾出空间后系统会再次回调
}

if allDone.wait(timeout: .now() + 600) == .timedOut {
    FileHandle.standardError.write("  ! 编码超时\n".data(using: .utf8)!)
}

let sem = DispatchSemaphore(value: 0)
writer.finishWriting { sem.signal() }
if sem.wait(timeout: .now() + 300) == .timedOut {
    FileHandle.standardError.write("  ! finishWriting 超时\n".data(using: .utf8)!)
}

if writer.status == .completed {
    let size = ((try? fm.attributesOfItem(atPath: outPath))?[.size] as? Int) ?? 0
    let mb = Double(size) / 1024 / 1024
    let secs = Double(written) / Double(fps)
    print(String(format: "  ✓ %@  %dx%d  %.1f 秒  %d 帧  %.1f MB",
                 outPath, width, height, secs, written, mb))
    exit(0)
} else {
    FileHandle.standardError.write(
        "编码失败: \(writer.error?.localizedDescription ?? "未知")\n".data(using: .utf8)!)
    exit(1)
}
