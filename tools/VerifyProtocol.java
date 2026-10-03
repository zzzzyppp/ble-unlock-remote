import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HexFormat;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * 协议一致性验证工具。
 *
 * 作用：用一个"固定密钥 + 固定时间戳 + 固定 nonce"的测试向量，
 *       分别用 Java 实现和 Mac 端 Swift 二进制计算 HMAC，
 *       比对两者结果是否完全一致，从而证明两端协议实现没有偏差。
 *
 * 用法（由 verify-protocol.sh 调用，也可单独运行）:
 *   java VerifyProtocol <android.jar> <build-tools-dir> <swift二进制> <manifest>
 */
public class VerifyProtocol {

    // 测试向量（与 mac-src 中的布局定义保持一致）
    static final byte[] KEY = new byte[32];          // 全 0 密钥，便于跨语言复现
    static final long TS = 1700000000L;              // 固定时间戳 2023-11-14T22:13:20Z
    static final byte[] NONCE = new byte[16];        // 全 0 nonce
    static final byte CMD = 0x01;                    // UNLOCK

    static {
        for (int i = 0; i < 32; i++) KEY[i] = (byte) i;       // 0x00,0x01,...,0x1f
        for (int i = 0; i < 16; i++) NONCE[i] = (byte) (0xA0 + i);
    }

    static int failures = 0;

    static void check(String label, boolean condition, String detail) {
        if (condition) {
            System.out.println("  \u2713 " + label);
        } else {
            System.out.println("  \u2717 " + label + "  -> " + detail);
            failures++;
        }
    }

    public static void main(String[] args) throws Exception {
        System.out.println("== 1. 报文结构自检 ==");

        byte[] message = buildMessage();
        check("消息长度为 30 字节", message.length == 30, "实际 " + message.length);

        HexFormat hex = HexFormat.of();
        String messageHex = hex.formatHex(message);
        System.out.println("     消息(hex): " + messageHex);

        check("魔数为 42 55", message[0] == 0x42 && message[1] == 0x55,
                "实际 " + hex.formatHex(new byte[]{message[0], message[1]}));
        check("版本为 01", message[2] == 0x01, "实际 " + message[2]);
        check("指令为 01", message[3] == 0x01, "实际 " + message[3]);

        ByteBuffer tsBuf = ByteBuffer.wrap(message, 4, 8).order(ByteOrder.BIG_ENDIAN);
        check("时间戳为大端 1700000000", tsBuf.getLong() == TS, "不匹配");

        boolean nonceOk = true;
        for (int i = 0; i < 16; i++) {
            if (message[12 + i] != NONCE[i]) nonceOk = false;
        }
        check("nonce 位于偏移 12..27", nonceOk, "不匹配");
        check("偏移 28..29 为保留字节且为 0",
                message[28] == 0 && message[29] == 0, "非 0");

        System.out.println();
        System.out.println("== 1b. 指定密码解锁（CMD_UNLOCK_FROM）==");
        // 手机选"用第几个密码"时，指令码变成 0x04，序号放在字节 28（HMAC 保护范围内）。
        for (int idx : new int[]{0, 1, 2, 7, 255}) {
            byte[] msg = buildMessage((byte) 0x04, idx);
            boolean cmdOk = msg[3] == 0x04;
            boolean idxOk = (msg[28] & 0xFF) == idx;
            boolean reservedOk = msg[29] == 0;
            check("序号 " + idx + " 编码正确（指令 0x04，字节28=" + idx + "）",
                  cmdOk && idxOk && reservedOk,
                  "cmd=" + msg[3] + " b28=" + (msg[28] & 0xFF) + " b29=" + msg[29]);
        }
        // 普通解锁不应带序号语义
        byte[] plain = buildMessage((byte) 0x01, -1);
        check("普通解锁字节 28 保持为 0", plain[28] == 0 && plain[29] == 0,
              "b28=" + plain[28] + " b29=" + plain[29]);

        System.out.println();
        System.out.println("== 1c. 跳过锁屏校验标志（字节 29）==");
        for (int idx : new int[]{0, 2, 255}) {
            for (boolean force : new boolean[]{false, true}) {
                byte[] msg = buildMessage((byte) 0x04, idx, force);
                boolean ok = msg[3] == 0x04
                        && (msg[28] & 0xFF) == idx
                        && (msg[29] != 0) == force;
                check("序号 " + idx + (force ? " +跳过校验" : " 常规") + " 编码正确", ok,
                      "b28=" + (msg[28] & 0xFF) + " b29=" + msg[29]);
            }
        }
        // 只要求跳过校验、不指定序号时，序号为 0（即第一个密码）
        byte[] forceOnly = buildMessage((byte) 0x04, 0, true);
        check("仅跳过校验（序号取 0）", forceOnly[28] == 0 && forceOnly[29] == 1,
              "b28=" + forceOnly[28] + " b29=" + forceOnly[29]);

        System.out.println();
        System.out.println("== 2. Java 端 HMAC-SHA256 ==");
        byte[] javaTag = hmac(KEY, message);
        String javaTagHex = hex.formatHex(javaTag);
        check("HMAC 长度为 32 字节", javaTag.length == 32, "实际 " + javaTag.length);
        System.out.println("     Java  HMAC: " + javaTagHex);

        // 用 RFC 4231 官方测试向量确认算法接线正确（比自造常量更可靠）
        //   Test Case 1: key = 20 字节 0x0b, data = "Hi There"
        byte[] rfcKey = new byte[20];
        for (int i = 0; i < rfcKey.length; i++) rfcKey[i] = 0x0b;
        String rfcActual = hex.formatHex(hmac(rfcKey, "Hi There".getBytes(StandardCharsets.US_ASCII)));
        String rfcExpected = "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7";
        check("RFC 4231 Test Case 1 向量匹配", rfcActual.equals(rfcExpected),
                "实际 " + rfcActual);

        // 本项目实际使用的密钥（0x00..0x1f）对空消息的结果，由独立实现(Python hmac)交叉确认
        String emptyHex = hex.formatHex(hmac(KEY, new byte[0]));
        String expectedEmpty = "d38b42096d80f45f826b44a9d5607de72496a415d3f4a1a8c88e3bb9da8dc1cb";
        check("测试密钥对空消息的 HMAC 正确", emptyHex.equals(expectedEmpty),
                "实际 " + emptyHex);

        System.out.println();
        System.out.println("== 3. 与 Mac 端 Swift 实现比对 ==");

        if (args.length >= 3) {
            String swiftBin = args[2];
            // 让 Swift 端对同样的 30 字节消息计算 HMAC
            ProcessBuilder pb = new ProcessBuilder(swiftBin, "--selftest", messageHex);
            pb.redirectErrorStream(false);
            Process proc = pb.start();
            String stdout = new String(proc.getInputStream().readAllBytes(), StandardCharsets.UTF_8).trim();
            String stderr = new String(proc.getErrorStream().readAllBytes(), StandardCharsets.UTF_8).trim();
            int code = proc.waitFor();

            if (code != 0) {
                check("Swift 自检程序可执行", false, "退出码 " + code + " stderr=" + stderr);
            } else {
                String swiftTagHex = stdout;
                System.out.println("     Swift HMAC: " + swiftTagHex);
                check("两端 HMAC 完全一致", javaTagHex.equalsIgnoreCase(swiftTagHex),
                        "Java=" + javaTagHex + " Swift=" + swiftTagHex);
            }
        } else {
            System.out.println("  （未提供 Swift 二进制，跳过跨语言比对）");
        }

        System.out.println();
        if (failures == 0) {
            System.out.println("结果: 全部通过 \u2713");
            System.exit(0);
        } else {
            System.out.println("结果: " + failures + " 项失败 \u2717");
            System.exit(1);
        }
    }

    /** 按协议拼出 30 字节待签名消息（默认指令） */
    static byte[] buildMessage() {
        return buildMessage(CMD, -1);
    }

    /**
     * 按协议拼出 30 字节待签名消息。
     *
     * @param command       指令码
     * @param passwordIndex 密码序号（0 基）；负数表示不指定，字节 28 保持 0
     */
    static byte[] buildMessage(byte command, int passwordIndex) {
        return buildMessage(command, passwordIndex, false);
    }

    /**
     * @param skipLockCheck 字节 29：是否跳过锁屏校验
     */
    static byte[] buildMessage(byte command, int passwordIndex, boolean skipLockCheck) {
        byte[] m = new byte[30];
        m[0] = 0x42;
        m[1] = 0x55;
        m[2] = 0x01;
        m[3] = command;
        if (passwordIndex >= 0) {
            m[28] = (byte) passwordIndex;
        }
        if (skipLockCheck) {
            m[29] = 1;
        }
        ByteBuffer ts = ByteBuffer.allocate(8).order(ByteOrder.BIG_ENDIAN);
        ts.putLong(TS);
        System.arraycopy(ts.array(), 0, m, 4, 8);
        System.arraycopy(NONCE, 0, m, 12, 16);
        return m;
    }

    static byte[] hmac(byte[] key, byte[] data) throws Exception {
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(key, "HmacSHA256"));
        return mac.doFinal(data);
    }
}
