package org.json;

/**
 * 极简 JSON 编解码器（仅测试替身使用）。
 *
 * 覆盖 org.json 在本项目里用到的全部行为：
 * 字符串转义（含引号、反斜杠、中文、控制字符）与标准 JSON 解析。
 */
final class JsonCodec {

    private JsonCodec() {
    }

    // ------------------------------------------------------------ 编码

    static void encodeValue(StringBuilder sb, Object v) {
        if (v == null || v == JSONObject.NULL) {
            sb.append("null");
        } else if (v instanceof String) {
            encodeString(sb, (String) v);
        } else if (v instanceof JSONObject) {
            sb.append(v.toString());
        } else if (v instanceof JSONArray) {
            sb.append(v.toString());
        } else if (v instanceof Boolean) {
            sb.append(v.toString());
        } else if (v instanceof Number) {
            sb.append(v.toString());
        } else {
            encodeString(sb, String.valueOf(v));
        }
    }

    static void encodeString(StringBuilder sb, String s) {
        if (s == null) {
            sb.append("null");
            return;
        }
        sb.append('"');
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"':  sb.append("\\\""); break;
                case '\\': sb.append("\\\\"); break;
                case '\n': sb.append("\\n"); break;
                case '\r': sb.append("\\r"); break;
                case '\t': sb.append("\\t"); break;
                case '\b': sb.append("\\b"); break;
                case '\f': sb.append("\\f"); break;
                default:
                    if (c < 0x20) {
                        sb.append(String.format("\\u%04x", (int) c));
                    } else {
                        // 中文等非 ASCII 字符直接原样输出，与 org.json 一致
                        sb.append(c);
                    }
            }
        }
        sb.append('"');
    }

    // ------------------------------------------------------------ 解析

    static Object parse(String text) throws JSONException {
        Parser p = new Parser(text);
        p.skipWhitespace();
        Object value = p.parseValue();
        p.skipWhitespace();
        if (!p.atEnd()) throw new JSONException("JSON 结尾有多余内容");
        return value;
    }

    private static final class Parser {
        private final String src;
        private int pos;

        Parser(String src) {
            this.src = src;
        }

        boolean atEnd() {
            return pos >= src.length();
        }

        void skipWhitespace() {
            while (pos < src.length() && Character.isWhitespace(src.charAt(pos))) pos++;
        }

        char peek() throws JSONException {
            if (atEnd()) throw new JSONException("JSON 意外结束");
            return src.charAt(pos);
        }

        void expect(char c) throws JSONException {
            if (atEnd() || src.charAt(pos) != c) {
                throw new JSONException("期望 '" + c + "'，位置 " + pos);
            }
            pos++;
        }

        Object parseValue() throws JSONException {
            skipWhitespace();
            char c = peek();
            switch (c) {
                case '{': return parseObject();
                case '[': return parseArray();
                case '"': return parseString();
                case 't':
                    consume("true");
                    return Boolean.TRUE;
                case 'f':
                    consume("false");
                    return Boolean.FALSE;
                case 'n':
                    consume("null");
                    return JSONObject.NULL;
                default:
                    return parseNumber();
            }
        }

        private void consume(String word) throws JSONException {
            if (!src.startsWith(word, pos)) throw new JSONException("非法字面量，位置 " + pos);
            pos += word.length();
        }

        private JSONObject parseObject() throws JSONException {
            expect('{');
            java.util.LinkedHashMap<String, Object> map = new java.util.LinkedHashMap<>();
            skipWhitespace();
            if (!atEnd() && peek() == '}') {
                pos++;
                return new JSONObject(map);
            }
            while (true) {
                skipWhitespace();
                String key = parseString();
                skipWhitespace();
                expect(':');
                Object value = parseValue();
                map.put(key, value);
                skipWhitespace();
                char c = peek();
                if (c == ',') {
                    pos++;
                    continue;
                }
                if (c == '}') {
                    pos++;
                    return new JSONObject(map);
                }
                throw new JSONException("对象中出现非法字符 '" + c + "'，位置 " + pos);
            }
        }

        private JSONArray parseArray() throws JSONException {
            expect('[');
            JSONArray array = new JSONArray();
            skipWhitespace();
            if (!atEnd() && peek() == ']') {
                pos++;
                return array;
            }
            while (true) {
                array.putInternal(parseValue());
                skipWhitespace();
                char c = peek();
                if (c == ',') {
                    pos++;
                    continue;
                }
                if (c == ']') {
                    pos++;
                    return array;
                }
                throw new JSONException("数组中出现非法字符 '" + c + "'，位置 " + pos);
            }
        }

        private String parseString() throws JSONException {
            expect('"');
            StringBuilder sb = new StringBuilder();
            while (true) {
                if (atEnd()) throw new JSONException("字符串未闭合");
                char c = src.charAt(pos++);
                if (c == '"') return sb.toString();
                if (c != '\\') {
                    sb.append(c);
                    continue;
                }
                if (atEnd()) throw new JSONException("转义符后意外结束");
                char esc = src.charAt(pos++);
                switch (esc) {
                    case '"':  sb.append('"'); break;
                    case '\\': sb.append('\\'); break;
                    case '/':  sb.append('/'); break;
                    case 'n':  sb.append('\n'); break;
                    case 'r':  sb.append('\r'); break;
                    case 't':  sb.append('\t'); break;
                    case 'b':  sb.append('\b'); break;
                    case 'f':  sb.append('\f'); break;
                    case 'u':
                        if (pos + 4 > src.length()) throw new JSONException("\\u 转义不完整");
                        sb.append((char) Integer.parseInt(src.substring(pos, pos + 4), 16));
                        pos += 4;
                        break;
                    default:
                        throw new JSONException("未知转义 \\" + esc);
                }
            }
        }

        private Object parseNumber() throws JSONException {
            int start = pos;
            while (pos < src.length()
                    && "-+.eE0123456789".indexOf(src.charAt(pos)) >= 0) {
                pos++;
            }
            if (start == pos) throw new JSONException("非法字符，位置 " + pos);
            return src.substring(start, pos);
        }
    }
}
