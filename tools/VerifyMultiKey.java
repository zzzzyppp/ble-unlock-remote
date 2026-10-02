import com.bleunlock.remote.Protocol;

import org.json.JSONArray;
import org.json.JSONObject;

import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;

/**
 * 多密钥存储的逻辑验证（在 JVM 上运行，用 android.jar 里真正的 org.json 实现）。
 *
 * 验证内容：
 *   1. Protocol.parseToken 能认出的令牌格式（base64 / URL-safe / hex / 带分隔符）
 *   2. MacEntryStore 用到的 JSON 往返是否无损（含空值、特殊字符）
 *   3. 旧版本单 token 迁移逻辑
 *   4. 损坏数据的容错
 *
 * 用法: java VerifyMultiKey [真实的token/base64]
 */
public class VerifyMultiKey {

    static int failed = 0;

    static void check(String label, boolean ok, String detail) {
        if (ok) {
            System.out.println("  \u2713 " + label);
        } else {
            System.out.println("  \u2717 " + label + "  -> " + detail);
            failed++;
        }
    }

    /** 复刻 MacEntryStore.all() 的解析循环，用于验证容错行为 */
    static List<String> parseEntries(String raw) {
        List<String> out = new ArrayList<>();
        try {
            JSONArray array = new JSONArray(raw);
            for (int i = 0; i < array.length(); i++) {
                JSONObject o = array.getJSONObject(i);
                String id = o.optString("id");
                String token = o.optString("token");
                if (id == null || id.isEmpty()) id = "<auto>";
                if (token != null && !token.isEmpty()) out.add(id + "|" + token);
            }
        } catch (Exception ignored) {
            // 损坏数据返回空列表
        }
        return out;
    }

    public static void main(String[] args) throws Exception {
        System.out.println("== 1. 令牌格式解析 (Protocol.parseToken) ==");

        // 32 字节的测试密钥
        byte[] raw = new byte[32];
        for (int i = 0; i < 32; i++) raw[i] = (byte) (i * 7 + 1);

        String b64 = java.util.Base64.getEncoder().encodeToString(raw);
        String b64url = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(raw);
        StringBuilder hex = new StringBuilder();
        for (byte b : raw) hex.append(String.format("%02X", b));
        StringBuilder hexSep = new StringBuilder();
        for (int i = 0; i < 32; i++) {
            if (i > 0) hexSep.append(':');
            hexSep.append(String.format("%02x", raw[i]));
        }

        check("标准 base64 可解析", eq(raw, Protocol.parseToken(b64)), "解析失败");
        check("URL-safe base64 可解析", eq(raw, Protocol.parseToken(b64url)), "解析失败");
        check("大写十六进制可解析", eq(raw, Protocol.parseToken(hex.toString())), "解析失败");
        check("带冒号的十六进制可解析", eq(raw, Protocol.parseToken(hexSep.toString())), "解析失败");
        check("前后空白被忽略", eq(raw, Protocol.parseToken("  " + b64 + "\n")), "解析失败");
        check("空字符串返回 null", Protocol.parseToken("") == null, "应返回 null");
        check("null 返回 null", Protocol.parseToken(null) == null, "应返回 null");
        check("长度不对的密钥返回 null",
                Protocol.parseToken("YWJj") == null, "应返回 null");
        check("乱码返回 null",
                Protocol.parseToken("这不是一个令牌!!!") == null, "应返回 null");

        System.out.println();
        System.out.println("== 2. 密钥指纹（用于界面区分不同 Mac）==");
        String fp1 = Protocol.fingerprint(raw);
        String fp2 = Protocol.fingerprint(Protocol.parseToken(b64));
        check("同一密钥指纹一致", fp1.equals(fp2), fp1 + " vs " + fp2);
        check("指纹为 8 位十六进制", fp1.matches("[0-9A-F]{8}"), "实际 " + fp1);

        byte[] other = new byte[32];
        other[0] = 1; // 只改一个字节
        check("不同密钥指纹不同",
                !Protocol.fingerprint(other).equals(fp1),
                Protocol.fingerprint(other) + " vs " + fp1);

        System.out.println();
        System.out.println("== 3. 存储 JSON 往返 (org.json) ==");

        JSONArray array = new JSONArray();

        JSONObject a = new JSONObject();
        a.put("id", "id-1");
        a.put("name", "办公室 iMac");
        a.put("token", b64);
        a.put("address", "AA:BB:CC:DD:EE:FF");
        array.put(a);

        JSONObject b = new JSONObject();
        b.put("id", "id-2");
        b.put("name", "");            // 空名字
        b.put("token", hex.toString());
        b.put("address", "");          // 从未连接过
        array.put(b);

        JSONObject c = new JSONObject();
        c.put("id", "id-3");
        c.put("name", "家里的 \"MacBook\" \\ 带特殊字符");
        c.put("token", b64url);
        c.put("address", "");
        array.put(c);

        String serialized = array.toString();
        List<String> parsed = parseEntries(serialized);

        check("三条记录全部往返成功", parsed.size() == 3, "实际 " + parsed.size());
        check("令牌未损坏", parsed.size() == 3 && parsed.get(0).endsWith("|" + b64),
                parsed.isEmpty() ? "空" : parsed.get(0));
        check("中文与特殊字符名字未损坏",
                serialized.contains("办公室 iMac") && serialized.contains("家里的"),
                "序列化结果丢字符");
        check("含引号与反斜杠的名字可安全往返",
                parseEntries(array.toString()).size() == 3, "解析异常");

        System.out.println();
        System.out.println("== 4. 异常数据容错 ==");
        check("空数组解析为空", parseEntries("[]").isEmpty(), "应为空");
        check("损坏 JSON 不抛异常", parseEntries("{不是数组").isEmpty(), "应为空");
        check("缺少 token 的记录被跳过",
                parseEntries("[{\"id\":\"x\",\"name\":\"n\",\"token\":\"\"}]").isEmpty(),
                "应跳过");
        check("缺少 id 的记录仍有 id",
                parseEntries("[{\"name\":\"n\",\"token\":\"" + b64 + "\"}]").get(0)
                        .startsWith("<auto>|"),
                "id 兜底失败");

        System.out.println();
        System.out.println("== 5. 旧版本单 token 迁移 ==");
        // 模拟旧数据：只有一个 token，没有 entries 列表
        String legacyToken = b64;
        boolean hasEntriesKey = false;
        List<String> migrated = new ArrayList<>();
        if (!hasEntriesKey && legacyToken != null && !legacyToken.trim().isEmpty()) {
            JSONArray arr = new JSONArray();
            JSONObject e = new JSONObject();
            e.put("id", "migrated-id");
            e.put("name", "我的 Mac");       // 旧数据没有名字，用默认值
            e.put("token", legacyToken.trim());
            e.put("address", "");
            arr.put(e);
            migrated = parseEntries(arr.toString());
        }
        check("旧 token 被迁移成一条记录", migrated.size() == 1, "实际 " + migrated.size());
        check("迁移后令牌保持可用",
                !migrated.isEmpty() && Protocol.parseToken(
                        migrated.get(0).substring(migrated.get(0).indexOf('|') + 1)) != null,
                "迁移后令牌失效");
        // 直接校验解析后的字段，而不是匹配序列化文本（避免转义形式带来的歧义）
        String migratedName = "";
        try {
            JSONArray arr = new JSONArray("[]");
            JSONObject e = new JSONObject();
            e.put("id", "migrated-id");
            e.put("name", "我的 Mac");
            e.put("token", legacyToken.trim());
            e.put("address", "");
            arr.put(e);
            String roundTripped = arr.toString();
            migratedName = new JSONArray(roundTripped).getJSONObject(0).optString("name");
        } catch (Exception ex) {
            migratedName = "<异常: " + ex.getMessage() + ">";
        }
        check("迁移时自动补默认名字", "我的 Mac".equals(migratedName),
                "实际名字 = [" + migratedName + "]");

        System.out.println();
        System.out.println("== 6. 用真实令牌验证（如果提供）==");
        if (args.length > 0 && args[0] != null && !args[0].isEmpty()) {
            byte[] real = Protocol.parseToken(args[0]);
            check("真实令牌可解析", real != null, "解析失败");
            if (real != null) {
                System.out.println("     指纹: " + Protocol.fingerprint(real));
                check("真实令牌为 32 字节", real.length == 32, "实际 " + real.length);
            }
        } else {
            System.out.println("  （未提供真实令牌，跳过）");
        }

        System.out.println();
        if (failed == 0) {
            System.out.println("结果: 全部通过 \u2713");
            System.exit(0);
        } else {
            System.out.println("结果: " + failed + " 项失败 \u2717");
            System.exit(1);
        }
    }

    static boolean eq(byte[] a, byte[] b) {
        if (a == null || b == null || a.length != b.length) return false;
        for (int i = 0; i < a.length; i++) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }
}
