package org.json;

/**
 * 测试用替身：android.jar 里的 org.json 只是 `throw new RuntimeException("Stub!")` 占位。
 *
 * 这个实现提供与 Android 一致的 JSONObject 语义（含 optString / getJSONObject 的容错行为），
 * 仅用于在本机验证 MacEntryStore 的存储逻辑，不参与 APK 构建。
 */
public class JSONObject {

    /** 与 Android 一致：表示 JSON null 的哨兵对象 */
    public static final Object NULL = new Object() {
        @Override
        public boolean equals(Object o) {
            return o == this || o == null;
        }

        @Override
        public String toString() {
            return "null";
        }
    };

    private final java.util.LinkedHashMap<String, Object> map = new java.util.LinkedHashMap<>();

    public JSONObject() {
    }

    @SuppressWarnings("unchecked")
    JSONObject(java.util.Map<String, Object> source) {
        map.putAll(source);
    }

    public JSONObject put(String key, Object value) throws JSONException {
        map.put(key, value);
        return this;
    }

    public boolean has(String key) {
        return map.containsKey(key) && map.get(key) != null;
    }

    public Object opt(String key) {
        return map.get(key);
    }

    /** Android 语义：键不存在 → default；键存在但值为 null → ""（JSONObject.NULL 除外） */
    public String optString(String key, String fallback) {
        Object v = map.get(key);
        if (v == null) return fallback;
        if (v instanceof String) return (String) v;
        return String.valueOf(v);
    }

    public String optString(String key) {
        return optString(key, "");
    }

    public JSONObject getJSONObject(String key) throws JSONException {
        Object v = map.get(key);
        if (!(v instanceof JSONObject)) {
            throw new JSONException("不是 JSONObject: " + key);
        }
        return (JSONObject) v;
    }

    public JSONArray getJSONArray(String key) throws JSONException {
        Object v = map.get(key);
        if (!(v instanceof JSONArray)) {
            throw new JSONException("不是 JSONArray: " + key);
        }
        return (JSONArray) v;
    }

    public String getString(String key) throws JSONException {
        Object v = map.get(key);
        if (!(v instanceof String)) throw new JSONException("不是字符串: " + key);
        return (String) v;
    }

    @Override
    public String toString() {
        StringBuilder sb = new StringBuilder("{");
        boolean first = true;
        for (java.util.Map.Entry<String, Object> e : map.entrySet()) {
            if (!first) sb.append(',');
            first = false;
            JsonCodec.encodeString(sb, e.getKey());
            sb.append(':');
            JsonCodec.encodeValue(sb, e.getValue());
        }
        return sb.append('}').toString();
    }

    public static String quote(String s) {
        StringBuilder sb = new StringBuilder();
        JsonCodec.encodeString(sb, s);
        return sb.toString();
    }

    /** 供 JSONArray.toString 使用 */
    void writeTo(StringBuilder sb) {
        sb.append(toString());
    }
}
