package com.bleunlock.remote;

import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.UUID;

/**
 * 多台 Mac 的配对信息存储。
 *
 * 每条记录包含：备注名、配对令牌、以及可选的已连接设备地址（用于下次直连跳过扫描）。
 * 全部放在一个 SharedPreferences 的 JSON 数组里，不引入任何第三方依赖。
 *
 * 兼容旧版本：如果只存在单个 token（旧格式）且尚无列表，会自动迁移成一条记录。
 */
public class MacEntryStore {

    public static final String PREFS = "ble_unlock_prefs";

    /** 旧版本的单令牌键名，仅用于迁移 */
    public static final String LEGACY_KEY_TOKEN = "token";
    /** 旧版本的单 Mac 名 */
    private static final String LEGACY_KEY_NAME = "mac_name";

    private static final String KEY_ENTRIES = "mac_entries";
    private static final String KEY_SELECTED = "selected_entry";

    private final SharedPreferences prefs;

    public MacEntryStore(Context context) {
        this.prefs = context.getApplicationContext()
                .getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        migrateIfNeeded();
    }

    // ------------------------------------------------------------ 数据结构

    public static class Entry {
        public String id;
        public String name;
        /** 用户填写的原始令牌文本 */
        public String token;
        /** 上次成功连接的设备 MAC，可为空 */
        public String address;

        public Entry() {
        }

        public Entry(String id, String name, String token, String address) {
            this.id = id;
            this.name = name;
            this.token = token;
            this.address = address;
        }

        /** 解析出 32 字节密钥；无效时返回 null */
        public byte[] keyBytes() {
            return Protocol.parseToken(token);
        }

        public boolean isValid() {
            return keyBytes() != null;
        }

        /** 界面上显示的标题，名字为空时用密钥指纹兜底 */
        public String displayName() {
            if (name != null && !name.trim().isEmpty()) return name.trim();
            byte[] key = keyBytes();
            if (key != null) return "未命名 (" + Protocol.fingerprint(key) + ")";
            return "未命名";
        }
    }

    // ------------------------------------------------------------ 读写

    public List<Entry> all() {
        List<Entry> list = new ArrayList<>();
        String raw = prefs.getString(KEY_ENTRIES, "[]");
        try {
            JSONArray array = new JSONArray(raw);
            for (int i = 0; i < array.length(); i++) {
                JSONObject o = array.getJSONObject(i);
                Entry e = new Entry();
                e.id = o.optString("id");
                e.name = o.optString("name");
                e.token = o.optString("token");
                e.address = o.optString("address", "");
                if (e.id == null || e.id.isEmpty()) e.id = UUID.randomUUID().toString();
                if (e.token != null && !e.token.isEmpty()) list.add(e);
            }
        } catch (JSONException ignored) {
            // 数据损坏时返回空列表，避免崩溃
        }
        return list;
    }

    private void save(List<Entry> list, String selectedId) {
        JSONArray array = new JSONArray();
        for (Entry e : list) {
            JSONObject o = new JSONObject();
            try {
                o.put("id", e.id);
                o.put("name", e.name == null ? "" : e.name);
                o.put("token", e.token);
                o.put("address", e.address == null ? "" : e.address);
            } catch (JSONException ignored) {
            }
            array.put(o);
        }
        SharedPreferences.Editor editor = prefs.edit();
        editor.putString(KEY_ENTRIES, array.toString());
        if (selectedId != null) editor.putString(KEY_SELECTED, selectedId);
        editor.apply();
    }

    /** 新增一条记录，返回其 id */
    public String add(String name, String token) {
        List<Entry> list = all();
        Entry e = new Entry(UUID.randomUUID().toString(), name, token, "");
        list.add(e);
        String selected = selectedId();
        // 之前没有任何记录时，自动选中新增的这条
        save(list, (selected == null || find(selected) == null) ? e.id : selected);
        return e.id;
    }

    /** 更新一条记录的名字与令牌；改令牌会清掉旧的设备地址（因为换了 Mac） */
    public void update(String id, String name, String token) {
        List<Entry> list = all();
        for (Entry e : list) {
            if (e.id.equals(id)) {
                boolean tokenChanged = !token.equals(e.token);
                e.name = name;
                e.token = token;
                if (tokenChanged) e.address = "";
                break;
            }
        }
        save(list, selectedId());
    }

    public void delete(String id) {
        List<Entry> list = all();
        for (int i = 0; i < list.size(); i++) {
            if (list.get(i).id.equals(id)) {
                list.remove(i);
                break;
            }
        }
        String selected = selectedId();
        if (id.equals(selected)) {
            selected = list.isEmpty() ? null : list.get(0).id;
        }
        save(list, selected);
    }

    /** 记录某条 Mac 最近的设备地址，便于下次直连 */
    public void rememberAddress(String id, String address) {
        if (id == null || address == null || address.isEmpty()) return;
        List<Entry> list = all();
        boolean changed = false;
        for (Entry e : list) {
            if (e.id.equals(id) && !address.equals(e.address)) {
                e.address = address;
                changed = true;
                break;
            }
        }
        if (changed) save(list, selectedId());
    }

    // ------------------------------------------------------------ 选中项

    public String selectedId() {
        return prefs.getString(KEY_SELECTED, null);
    }

    public Entry selected() {
        String id = selectedId();
        if (id != null) {
            Entry e = find(id);
            if (e != null) return e;
        }
        List<Entry> list = all();
        if (list.isEmpty()) return null;
        // 选中的记录被删了，回落到第一条
        Entry first = list.get(0);
        prefs.edit().putString(KEY_SELECTED, first.id).apply();
        return first;
    }

    public void select(String id) {
        prefs.edit().putString(KEY_SELECTED, id).apply();
    }

    public Entry find(String id) {
        if (id == null) return null;
        for (Entry e : all()) {
            if (id.equals(e.id)) return e;
        }
        return null;
    }

    public boolean isEmpty() {
        return all().isEmpty();
    }

    public int count() {
        return all().size();
    }

    /** 当前选中项在列表中的序号（从 1 开始），用于界面展示 */
    public String positionLabel(String id) {
        List<Entry> list = all();
        for (int i = 0; i < list.size(); i++) {
            if (list.get(i).id.equals(id)) return (i + 1) + "/" + list.size();
        }
        return "";
    }

    // ------------------------------------------------------------ 旧数据迁移

    /** 把旧版本的单 token 迁移成一条记录 */
    private void migrateIfNeeded() {
        if (prefs.contains(KEY_ENTRIES)) return;

        String legacyToken = prefs.getString(LEGACY_KEY_TOKEN, null);
        if (legacyToken == null || legacyToken.trim().isEmpty()) {
            prefs.edit().putString(KEY_ENTRIES, "[]").apply();
            return;
        }

        String name = prefs.getString(LEGACY_KEY_NAME, null);
        if (name == null || name.trim().isEmpty()) name = "我的 Mac";

        Entry e = new Entry(UUID.randomUUID().toString(), name, legacyToken.trim(), "");
        List<Entry> list = Collections.singletonList(e);
        save(list, e.id);

        // 迁移完成后移除旧键，避免下次再迁移一遍
        prefs.edit().remove(LEGACY_KEY_TOKEN).remove(LEGACY_KEY_NAME).apply();
    }
}
