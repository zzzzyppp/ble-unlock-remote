package org.json;

/** 测试用替身：对应 android.jar 中同为占位实现的 JSONArray。 */
public class JSONArray {

    private final java.util.List<Object> list = new java.util.ArrayList<>();

    public JSONArray() {
    }

    /** Android 语义：JSON 文本解析失败时抛 JSONException */
    public JSONArray(String json) throws JSONException {
        Object parsed = JsonCodec.parse(json);
        if (!(parsed instanceof JSONArray)) {
            throw new JSONException("不是 JSON 数组");
        }
        list.addAll(((JSONArray) parsed).list);
    }

    void putInternal(Object value) {
        list.add(value);
    }

    public JSONArray put(Object value) {
        list.add(value);
        return this;
    }

    public int length() {
        return list.size();
    }

    public Object opt(int index) {
        return index >= 0 && index < list.size() ? list.get(index) : null;
    }

    public JSONObject getJSONObject(int index) throws JSONException {
        Object v = opt(index);
        if (!(v instanceof JSONObject)) throw new JSONException("第 " + index + " 项不是 JSONObject");
        return (JSONObject) v;
    }

    public String optString(int index, String fallback) {
        Object v = opt(index);
        if (v == null) return fallback;
        return v instanceof String ? (String) v : String.valueOf(v);
    }

    @Override
    public String toString() {
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < list.size(); i++) {
            if (i > 0) sb.append(',');
            JsonCodec.encodeValue(sb, list.get(i));
        }
        return sb.append(']').toString();
    }
}
