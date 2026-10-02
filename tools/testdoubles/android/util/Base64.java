package android.util;

/**
 * 测试用替身：android.jar 里的 Base64 只是 `throw new RuntimeException("Stub!")` 占位，
 * 无法在 JVM 上验证 Protocol.parseToken 的真实行为。
 *
 * 这类只提供真实实现（API 语义与 Android 一致），仅用于本机测试，
 * 不参与 APK 构建。
 */
public final class Base64 {

    public static final int DEFAULT = 0;
    public static final int NO_PADDING = 1;
    public static final int NO_WRAP = 2;
    public static final int CRLF = 4;
    public static final int URL_SAFE = 8;
    public static final int NO_CLOSE = 16;

    private Base64() {
    }

    public static byte[] decode(String str, int flags) {
        if (str == null) return null;
        String s = str;
        if ((flags & URL_SAFE) != 0) {
            s = s.replace('-', '+').replace('_', '/');
        }
        // 去掉可能的换行（Android 在未指定 NO_WRAP 时容忍换行）
        s = s.replace("\n", "").replace("\r", "");
        // 补齐 padding
        int mod = s.length() % 4;
        if (mod == 2) s = s + "==";
        else if (mod == 3) s = s + "=";
        else if (mod == 1) throw new IllegalArgumentException("bad base-64");
        try {
            return java.util.Base64.getDecoder().decode(s);
        } catch (IllegalArgumentException e) {
            throw new IllegalArgumentException("bad base-64");
        }
    }

    public static byte[] decode(byte[] input, int flags) {
        return decode(new String(input, java.nio.charset.StandardCharsets.US_ASCII), flags);
    }

    public static String encodeToString(byte[] input, int flags) {
        if ((flags & URL_SAFE) != 0) {
            String s = java.util.Base64.getUrlEncoder().encodeToString(input);
            return (flags & NO_PADDING) != 0 ? s.replace("=", "") : s;
        }
        String s = java.util.Base64.getEncoder().encodeToString(input);
        return (flags & NO_PADDING) != 0 ? s.replace("=", "") : s;
    }

    public static String encodeToString(byte[] input, int offset, int len, int flags) {
        byte[] slice = new byte[len];
        System.arraycopy(input, offset, slice, 0, len);
        return encodeToString(slice, flags);
    }
}
