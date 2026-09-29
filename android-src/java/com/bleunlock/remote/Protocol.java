package com.bleunlock.remote;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.UUID;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * 与 Mac 端共用的协议定义。
 *
 * 数据包（62 字节，小端/大端无关，按字节序显式拼接）：
 *   偏移  长度  内容
 *   0     2     魔数 "BU" (0x42 0x55)
 *   2     1     协议版本 0x01
 *   3     1     指令：0x01 解锁 / 0x02 锁定 / 0x03 ping
 *   4     8     时间戳，大端 UInt64（秒）
 *   12    16    nonce，随机字节
 *   28    2     保留（0x0000）
 *   30    32    HMAC-SHA256(前 30 字节)
 *
 * 注意：HMAC 覆盖前 30 字节（0..29），因此消息缓冲区固定为 30 字节。
 */
public final class Protocol {

    public static final UUID SERVICE_UUID =
            UUID.fromString("B1E0A100-0001-4A00-8000-00805F9B0001");
    public static final UUID CHAR_COMMAND_UUID =
            UUID.fromString("B1E0A100-0002-4A00-8000-00805F9B0002");
    public static final UUID CHAR_STATUS_UUID =
            UUID.fromString("B1E0A100-0003-4A00-8000-00805F9B0003");
    public static final UUID CHAR_INFO_UUID =
            UUID.fromString("B1E0A100-0004-4A00-8000-00805F9B0004");

    public static final byte CMD_UNLOCK = 0x01;
    public static final byte CMD_LOCK = 0x02;
    public static final byte CMD_PING = 0x03;

    public static final int MESSAGE_LEN = 30;
    public static final int HMAC_LEN = 32;
    public static final int PACKET_LEN = MESSAGE_LEN + HMAC_LEN; // 62

    private static final SecureRandom RANDOM = new SecureRandom();

    private Protocol() {
    }

    /** 生成一条带签名的完整指令包。key 为 32 字节预共享密钥。 */
    public static byte[] buildPacket(byte command, byte[] key) throws Exception {
        if (key == null || key.length != 32) {
            throw new IllegalArgumentException("配对密钥必须是 32 字节");
        }

        byte[] message = new byte[MESSAGE_LEN];
        message[0] = 0x42; // 'B'
        message[1] = 0x55; // 'U'
        message[2] = 0x01; // 版本
        message[3] = command;

        long timestamp = System.currentTimeMillis() / 1000L;
        ByteBuffer tsBuf = ByteBuffer.allocate(8).order(ByteOrder.BIG_ENDIAN);
        tsBuf.putLong(timestamp);
        System.arraycopy(tsBuf.array(), 0, message, 4, 8);

        byte[] nonce = new byte[16];
        RANDOM.nextBytes(nonce);
        System.arraycopy(nonce, 0, message, 12, 16);

        // 偏移 28..29 为保留字节，保持 0

        byte[] tag = hmacSha256(key, message);
        byte[] packet = new byte[PACKET_LEN];
        System.arraycopy(message, 0, packet, 0, MESSAGE_LEN);
        System.arraycopy(tag, 0, packet, MESSAGE_LEN, HMAC_LEN);
        return packet;
    }

    public static byte[] hmacSha256(byte[] key, byte[] data) throws Exception {
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(key, "HmacSHA256"));
        return mac.doFinal(data);
    }

    /**
     * 解析用户在界面上填写的配对令牌。
     * 支持：标准 base64、URL-safe base64、带空格的十六进制。
     */
    public static byte[] parseToken(String raw) {
        if (raw == null) return null;
        String s = raw.trim();
        if (s.isEmpty()) return null;

        // 去掉可能的连字符分组
        String compact = s.replace("-", "").replace(" ", "").replace(":", "");

        // 先试十六进制：去掉分隔符后正好 64 个 hex 字符
        if (compact.matches("(?i)[0-9a-f]{64}")) {
            byte[] out = new byte[32];
            for (int i = 0; i < 32; i++) {
                out[i] = (byte) Integer.parseInt(compact.substring(i * 2, i * 2 + 2), 16);
            }
            return out;
        }

        // 再试 base64（标准与 URL-safe）
        for (String candidate : new String[]{s, compact}) {
            try {
                byte[] decoded = android.util.Base64.decode(candidate,
                        android.util.Base64.DEFAULT | android.util.Base64.NO_WRAP
                                | android.util.Base64.URL_SAFE);
                if (decoded != null && decoded.length == 32) return decoded;
            } catch (Exception ignored) {
                // 继续尝试下一种
            }
            try {
                byte[] decoded = android.util.Base64.decode(candidate,
                        android.util.Base64.DEFAULT | android.util.Base64.NO_WRAP);
                if (decoded != null && decoded.length == 32) return decoded;
            } catch (Exception ignored) {
                // 继续
            }
        }
        return null;
    }

    /** 把 32 字节密钥格式化成便于人工核对的十六进制串。 */
    public static String fingerprint(byte[] key) {
        if (key == null || key.length < 32) return "?";
        byte[] head = Arrays.copyOfRange(key, 0, 4);
        StringBuilder sb = new StringBuilder();
        for (byte b : head) sb.append(String.format("%02X", b));
        return sb.toString();
    }
}
