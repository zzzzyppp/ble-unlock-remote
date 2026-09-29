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

    /** 按协议拼出 30 字节待签名消息 */
    static byte[] buildMessage() {
        byte[] m = new byte[30];
        m[0] = 0x42;
        m[1] = 0x55;
        m[2] = 0x01;
        m[3] = CMD;
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
