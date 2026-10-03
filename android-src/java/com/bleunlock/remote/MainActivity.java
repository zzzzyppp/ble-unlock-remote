package com.bleunlock.remote;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.bluetooth.BluetoothAdapter;
import android.content.BroadcastReceiver;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.ServiceConnection;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.Typeface;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.text.InputType;
import android.util.TypedValue;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.util.ArrayList;
import java.util.List;

/**
 * 主界面：解锁按钮 + 连接状态 + 多台 Mac 的密钥管理。
 *
 * 界面完全用代码构建，避免依赖 AppCompat 等第三方库。
 */
public class MainActivity extends Activity {

    private static final int REQ_PERMISSIONS = 2001;
    private static final int REQ_ENABLE_BT = 2002;

    private static final int COL_BG = 0xFF111418;
    private static final int COL_CARD = 0xFF1B2027;
    private static final int COL_TEXT = 0xFFFFFFFF;
    private static final int COL_MUTED = 0xFF9AA4B2;
    private static final int COL_GREEN = 0xFF2E7D32;
    private static final int COL_GREY = 0xFF37474F;
    private static final int COL_BLUE = 0xFF1565C0;
    private static final int COL_RED = 0xFFEF5350;
    private static final int COL_AMBER = 0xFFFFCA28;

    private TextView macNameView;
    private TextView statusView;
    private TextView detailView;
    private Button unlockButton;
    private Button connectButton;
    private Button fillPasswordButton;

    private MacEntryStore store;
    private BleService service;
    private boolean bound = false;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable uiRefresh = new Runnable() {
        @Override
        public void run() {
            renderState();
            handler.postDelayed(this, 700);
        }
    };

    private final BroadcastReceiver stateReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            renderState();
        }
    };

    private final ServiceConnection connection = new ServiceConnection() {
        @Override
        public void onServiceConnected(ComponentName name, IBinder binder) {
            service = ((BleService.LocalBinder) binder).getService();
            bound = true;
            renderState();
        }

        @Override
        public void onServiceDisconnected(ComponentName name) {
            service = null;
            bound = false;
            renderState();
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        store = new MacEntryStore(this);
        setContentView(buildUi());
        registerStateReceiver();
        bindToService();
        ensureServiceRunning();
    }

    @Override
    protected void onResume() {
        super.onResume();
        handler.post(uiRefresh);
        ensurePermissions();
        renderState();
    }

    @Override
    protected void onPause() {
        handler.removeCallbacks(uiRefresh);
        super.onPause();
    }

    @Override
    protected void onDestroy() {
        unregisterStateReceiver();
        if (bound) {
            try {
                unbindService(connection);
            } catch (IllegalArgumentException ignored) {
            }
            bound = false;
        }
        super.onDestroy();
    }

    // ------------------------------------------------------------ 界面构建

    private View buildUi() {
        int pad = dp(20);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(pad, pad, pad, pad);
        root.setBackgroundColor(COL_BG);

        TextView title = new TextView(this);
        title.setText("BLE Unlock");
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 26);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        title.setTextColor(COL_TEXT);
        root.addView(title);

        TextView subtitle = new TextView(this);
        subtitle.setText("点一下按钮即可解锁你的 Mac");
        subtitle.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        subtitle.setTextColor(COL_MUTED);
        subtitle.setPadding(0, dp(4), 0, dp(18));
        root.addView(subtitle);

        // ---- 状态卡片 ----
        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setBackgroundColor(COL_CARD);
        card.setPadding(dp(16), dp(14), dp(16), dp(14));

        macNameView = new TextView(this);
        macNameView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        macNameView.setTypeface(Typeface.DEFAULT_BOLD);
        macNameView.setTextColor(COL_TEXT);
        card.addView(macNameView);

        statusView = new TextView(this);
        statusView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 17);
        statusView.setPadding(0, dp(6), 0, 0);
        card.addView(statusView);

        detailView = new TextView(this);
        detailView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        detailView.setTextColor(COL_MUTED);
        detailView.setPadding(0, dp(4), 0, 0);
        card.addView(detailView);

        root.addView(card);

        // ---- 解锁按钮 ----
        unlockButton = new Button(this);
        unlockButton.setText("解 锁");
        unlockButton.setTextSize(TypedValue.COMPLEX_UNIT_SP, 22);
        unlockButton.setTypeface(Typeface.DEFAULT_BOLD);
        unlockButton.setTextColor(Color.WHITE);
        unlockButton.setBackgroundColor(COL_GREEN);
        LinearLayout.LayoutParams unlockLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(96));
        unlockLp.topMargin = dp(18);
        unlockButton.setLayoutParams(unlockLp);
        unlockButton.setOnClickListener(v -> doSend(Protocol.CMD_UNLOCK));
        root.addView(unlockButton);

        // ---- 填充密码：选择用 Mac 上的第几个密码解锁 ----
        fillPasswordButton = new Button(this);
        fillPasswordButton.setText("填充密码");
        fillPasswordButton.setTextColor(Color.WHITE);
        fillPasswordButton.setBackgroundColor(COL_GREY);
        LinearLayout.LayoutParams fillLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        fillLp.topMargin = dp(10);
        fillPasswordButton.setLayoutParams(fillLp);
        fillPasswordButton.setOnClickListener(v -> showPasswordPicker());
        root.addView(fillPasswordButton);

        // ---- 次要按钮 ----
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        LinearLayout.LayoutParams rowLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        rowLp.topMargin = dp(10);
        row.setLayoutParams(rowLp);

        connectButton = new Button(this);
        connectButton.setText("重新连接");
        connectButton.setTextColor(Color.WHITE);
        connectButton.setBackgroundColor(COL_GREY);
        LinearLayout.LayoutParams half = new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        half.rightMargin = dp(5);
        connectButton.setLayoutParams(half);
        connectButton.setOnClickListener(v -> restartConnection());
        row.addView(connectButton);

        Button lockButton = new Button(this);
        lockButton.setText("锁定 Mac");
        lockButton.setTextColor(Color.WHITE);
        lockButton.setBackgroundColor(0xFF5D4037);
        LinearLayout.LayoutParams half2 = new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        half2.leftMargin = dp(5);
        lockButton.setLayoutParams(half2);
        lockButton.setOnClickListener(v -> doSend(Protocol.CMD_LOCK));
        row.addView(lockButton);

        root.addView(row);

        // ---- Mac 密钥管理 ----
        Button switchButton = new Button(this);
        switchButton.setText("切换 Mac");
        switchButton.setTextColor(Color.WHITE);
        switchButton.setBackgroundColor(COL_BLUE);
        LinearLayout.LayoutParams switchLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        switchLp.topMargin = dp(10);
        switchButton.setLayoutParams(switchLp);
        switchButton.setOnClickListener(v -> showMacPicker());
        root.addView(switchButton);

        Button addButton = new Button(this);
        addButton.setText("＋ 添加 Mac");
        addButton.setTextColor(Color.WHITE);
        addButton.setBackgroundColor(COL_GREY);
        LinearLayout.LayoutParams addLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        addLp.topMargin = dp(8);
        addButton.setLayoutParams(addLp);
        addButton.setOnClickListener(v -> showEditDialog(null));
        root.addView(addButton);

        TextView hint = new TextView(this);
        hint.setText("每台 Mac 在安装时都会生成自己的配对令牌，"
                + "在 Mac 上运行 ./mac-ble-unlock.sh token 可查看。"
                + "这里可以保存多台 Mac，随时切换。");
        hint.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        hint.setTextColor(0xFF6B7684);
        hint.setPadding(0, dp(18), 0, 0);
        root.addView(hint);

        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(COL_BG);
        scroll.addView(root, new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        return scroll;
    }

    private int dp(int value) {
        return (int) (value * getResources().getDisplayMetrics().density);
    }

    // ------------------------------------------------------------ Mac 密钥管理

    /** 列出所有已保存的 Mac，点击即切换 */
    /**
     * 选择用 Mac 上的第几个密码解锁。
     *
     * 手机不保存密码本身——密码只在 Mac 的钥匙串里。这里选择的是"位次"，
     * 名字只是给用户看的标签，方便区分哪个位次对应哪个密码。
     */
    private void showPasswordPicker() {
        final MacEntryStore.Entry active = store.selected();
        if (active == null) {
            Toast.makeText(this, "请先添加 Mac", Toast.LENGTH_SHORT).show();
            return;
        }

        // 至少展示若干位次，若已配置过更多则按已配置的数量
        final int slots = Math.max(3, Math.max(active.passwordLabels.size(),
                active.preferredPassword + 1));
        active.ensureLabels(slots);

        String[] labels = new String[slots];
        for (int i = 0; i < slots; i++) {
            String mark = (i == active.preferredPassword) ? "● " : "○ ";
            labels[i] = mark + active.labelFor(i) + "   （Mac 上第 " + (i + 1) + " 个）";
        }

        new AlertDialog.Builder(this)
                .setTitle("用哪个密码解锁")
                .setItems(labels, (dialog, which) -> {
                    store.setPasswordPreference(active.id, which, active.passwordLabels);
                    renderState();
                    Toast.makeText(this,
                            "解锁时将优先使用「" + active.labelFor(which) + "」",
                            Toast.LENGTH_SHORT).show();
                })
                .setNeutralButton("给位次起名", (dialog, which) -> showLabelEditor(active, slots))
                .setNegativeButton("取消", null)
                .show();
    }

    /** 给各密码位起名，便于在列表里区分 */
    private void showLabelEditor(final MacEntryStore.Entry active, final int slots) {
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(20);
        box.setPadding(pad, dp(8), pad, 0);

        TextView hint = new TextView(this);
        hint.setText("这些名字只显示在手机上，用于区分 Mac 上保存的第几个密码。"
                + "密码本身不会保存到手机。");
        hint.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        hint.setTextColor(COL_MUTED);
        hint.setPadding(0, 0, 0, dp(10));
        box.addView(hint);

        final EditText[] inputs = new EditText[slots];
        for (int i = 0; i < slots; i++) {
            TextView l = new TextView(this);
            l.setText("Mac 上第 " + (i + 1) + " 个密码，叫：");
            l.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
            l.setTextColor(COL_MUTED);
            l.setPadding(0, dp(8), 0, 0);
            box.addView(l);

            EditText e = new EditText(this);
            e.setSingleLine(true);
            e.setHint("例如：当前密码 / 旧密码");
            e.setText(active.labelFor(i).startsWith("密码 ") ? "" : active.labelFor(i));
            box.addView(e);
            inputs[i] = e;
        }

        new AlertDialog.Builder(this)
                .setTitle("给密码位起名")
                .setView(box)
                .setPositiveButton("保存", (dialog, which) -> {
                    List<String> names = new ArrayList<>();
                    for (EditText e : inputs) names.add(e.getText().toString().trim());
                    store.setPasswordPreference(active.id, active.preferredPassword, names);
                    renderState();
                    Toast.makeText(this, "已保存", Toast.LENGTH_SHORT).show();
                })
                .setNegativeButton("取消", null)
                .show();
    }

    private void showMacPicker() {
        final List<MacEntryStore.Entry> list = store.all();
        if (list.isEmpty()) {
            showEditDialog(null);
            return;
        }

        String selectedId = store.selectedId();
        String[] labels = new String[list.size()];
        for (int i = 0; i < list.size(); i++) {
            MacEntryStore.Entry e = list.get(i);
            byte[] k = e.keyBytes();
            String mark = e.id.equals(selectedId) ? "● " : "○ ";
            String fp = k != null ? Protocol.fingerprint(k) : "令牌无效";
            labels[i] = mark + e.displayName() + "   [" + fp + "]";
        }

        new AlertDialog.Builder(this)
                .setTitle("选择要连接的 Mac")
                .setItems(labels, (dialog, which) -> selectMac(list.get(which).id))
                .setNeutralButton("管理 / 删除", (dialog, which) -> showManageDialog())
                .setNegativeButton("取消", null)
                .show();
    }

    private void showManageDialog() {
        final List<MacEntryStore.Entry> list = store.all();
        if (list.isEmpty()) {
            Toast.makeText(this, "还没有保存任何 Mac", Toast.LENGTH_SHORT).show();
            return;
        }
        String[] labels = new String[list.size()];
        for (int i = 0; i < list.size(); i++) {
            labels[i] = list.get(i).displayName();
        }
        new AlertDialog.Builder(this)
                .setTitle("管理已保存的 Mac")
                .setItems(labels, (dialog, which) -> showEntryActions(list.get(which)))
                .setNegativeButton("返回", null)
                .show();
    }

    private void showEntryActions(final MacEntryStore.Entry entry) {
        String[] actions = {"重命名 / 修改令牌", "删除"};
        new AlertDialog.Builder(this)
                .setTitle(entry.displayName())
                .setItems(actions, (dialog, which) -> {
                    if (which == 0) {
                        showEditDialog(entry);
                    } else {
                        confirmDelete(entry);
                    }
                })
                .setNegativeButton("取消", null)
                .show();
    }

    private void confirmDelete(final MacEntryStore.Entry entry) {
        new AlertDialog.Builder(this)
                .setTitle("删除 " + entry.displayName() + "？")
                .setMessage("只从手机里移除这条配对信息，不会影响那台 Mac 本身。")
                .setPositiveButton("删除", (dialog, which) -> {
                    boolean wasSelected = entry.id.equals(store.selectedId());
                    store.delete(entry.id);
                    Toast.makeText(this, "已删除", Toast.LENGTH_SHORT).show();
                    if (wasSelected) {
                        MacEntryStore.Entry next = store.selected();
                        if (next != null) selectMac(next.id);
                    }
                    renderState();
                })
                .setNegativeButton("取消", null)
                .show();
    }

    /** 新增（entry 为 null）或编辑已有的 Mac */
    private void showEditDialog(final MacEntryStore.Entry entry) {
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(20);
        box.setPadding(pad, dp(8), pad, 0);

        TextView nameLabel = new TextView(this);
        nameLabel.setText("备注名（随便起，用于区分多台 Mac）");
        nameLabel.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        nameLabel.setTextColor(COL_MUTED);
        box.addView(nameLabel);

        final EditText nameInput = new EditText(this);
        nameInput.setHint("例如：办公室 iMac");
        nameInput.setSingleLine(true);
        nameInput.setText(entry != null ? entry.name : "");
        box.addView(nameInput);

        TextView tokenLabel = new TextView(this);
        tokenLabel.setText("配对令牌（在 Mac 上运行 ./mac-ble-unlock.sh token 获取）");
        tokenLabel.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        tokenLabel.setTextColor(COL_MUTED);
        tokenLabel.setPadding(0, dp(14), 0, 0);
        box.addView(tokenLabel);

        final EditText tokenInput = new EditText(this);
        tokenInput.setHint("32 字节密钥的 base64 或十六进制");
        tokenInput.setSingleLine(true);
        tokenInput.setInputType(InputType.TYPE_CLASS_TEXT
                | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        tokenInput.setText(entry != null ? entry.token : "");
        box.addView(tokenInput);

        new AlertDialog.Builder(this)
                .setTitle(entry == null ? "添加 Mac" : "编辑 Mac")
                .setView(box)
                .setPositiveButton("保存", (dialog, which) -> {
                    String name = nameInput.getText().toString().trim();
                    String token = tokenInput.getText().toString().trim();
                    byte[] key = Protocol.parseToken(token);
                    if (key == null) {
                        Toast.makeText(this,
                                "令牌格式不对：应为 32 字节的 base64 或 64 位十六进制",
                                Toast.LENGTH_LONG).show();
                        return;
                    }
                    if (name.isEmpty()) {
                        name = "Mac " + Protocol.fingerprint(key);
                    }
                    if (entry == null) {
                        String id = store.add(name, token);
                        Toast.makeText(this, "已添加 " + name, Toast.LENGTH_SHORT).show();
                        selectMac(id);
                    } else {
                        store.update(entry.id, name, token);
                        Toast.makeText(this, "已保存", Toast.LENGTH_SHORT).show();
                        if (entry.id.equals(store.selectedId())) {
                            restartConnection();
                        }
                        renderState();
                    }
                })
                .setNegativeButton("取消", null)
                .show();
    }

    private void selectMac(String id) {
        store.select(id);
        MacEntryStore.Entry e = store.find(id);
        if (e != null) {
            Toast.makeText(this, "已切换到 " + e.displayName(), Toast.LENGTH_SHORT).show();
        }
        Intent intent = new Intent(this, BleService.class);
        intent.setAction(BleService.ACTION_SELECT);
        startServiceSafely(intent);
        renderState();
    }

    // ------------------------------------------------------------ 交互

    private void restartConnection() {
        if (store.isEmpty()) {
            showEditDialog(null);
            return;
        }
        Intent stop = new Intent(this, BleService.class);
        stop.setAction(BleService.ACTION_STOP);
        startService(stop);

        Intent start = new Intent(this, BleService.class);
        start.setAction(BleService.ACTION_START);
        startServiceSafely(start);

        handler.postDelayed(this::bindToService, 300);
        Toast.makeText(this, "正在重新连接…", Toast.LENGTH_SHORT).show();
    }

    private void ensureServiceRunning() {
        if (store.isEmpty()) return;
        Intent start = new Intent(this, BleService.class);
        start.setAction(BleService.ACTION_START);
        startServiceSafely(start);
    }

    private void startServiceSafely(Intent intent) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent);
            } else {
                startService(intent);
            }
        } catch (IllegalStateException e) {
            Toast.makeText(this, "无法启动后台服务：" + e.getMessage(),
                    Toast.LENGTH_LONG).show();
        }
    }

    private void doSend(byte command) {
        if (store.isEmpty()) {
            showEditDialog(null);
            return;
        }
        if (service == null) {
            Toast.makeText(this, "服务尚未就绪，请稍候", Toast.LENGTH_SHORT).show();
            return;
        }
        String error = service.sendCommand(command);
        if (error != null) {
            Toast.makeText(this, error, Toast.LENGTH_LONG).show();
        } else if (command == Protocol.CMD_UNLOCK) {
            Toast.makeText(this, "解锁指令已送达 Mac", Toast.LENGTH_SHORT).show();
        }
    }

    // ------------------------------------------------------------ 服务绑定与广播

    private void bindToService() {
        if (bound) return;
        Intent intent = new Intent(this, BleService.class);
        bindService(intent, connection, Context.BIND_AUTO_CREATE);
    }

    private void registerStateReceiver() {
        IntentFilter filter = new IntentFilter(BleService.BROADCAST_STATE);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(stateReceiver, filter, Context.RECEIVER_NOT_EXPORTED);
        } else {
            registerReceiver(stateReceiver, filter);
        }
    }

    private void unregisterStateReceiver() {
        try {
            unregisterReceiver(stateReceiver);
        } catch (IllegalArgumentException ignored) {
        }
    }

    private void renderState() {
        MacEntryStore.Entry active = store.selected();

        if (active == null) {
            macNameView.setText("尚未配置 Mac");
            macNameView.setTextColor(COL_AMBER);
            statusView.setText("点下方「＋ 添加 Mac」开始");
            statusView.setTextColor(COL_MUTED);
            detailView.setText("");
            unlockButton.setEnabled(false);
            unlockButton.setBackgroundColor(COL_GREY);
            connectButton.setText("重新连接");
            fillPasswordButton.setText("填充密码");
            fillPasswordButton.setEnabled(false);
            return;
        }

        String pos = store.positionLabel(active.id);
        macNameView.setText("当前：" + active.displayName()
                + (pos.isEmpty() ? "" : "   (" + pos + ")"));
        macNameView.setTextColor(COL_TEXT);

        // 显示当前用哪个密码位（密码本身不在手机上，这里只是位次与名字）
        fillPasswordButton.setText("填充密码：" + active.labelFor(active.preferredPassword));

        String state = BleService.getState();
        statusView.setText(state);
        detailView.setText(BleService.getDetail());

        if (BleService.STATE_CONNECTED.equals(state)) {
            statusView.setTextColor(0xFF66BB6A);
            unlockButton.setBackgroundColor(COL_GREEN);
        } else if (BleService.STATE_ERROR.equals(state)) {
            statusView.setTextColor(COL_RED);
            unlockButton.setBackgroundColor(COL_GREY);
        } else {
            statusView.setTextColor(COL_AMBER);
            unlockButton.setBackgroundColor(COL_GREY);
        }
        unlockButton.setEnabled(true);
        fillPasswordButton.setEnabled(true);
        connectButton.setText(BleService.STATE_SCANNING.equals(state) ? "搜索中…" : "重新连接");
    }

    // ------------------------------------------------------------ 权限

    private void ensurePermissions() {
        List<String> needed = new ArrayList<>();

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            if (checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN)
                    != PackageManager.PERMISSION_GRANTED) {
                needed.add(Manifest.permission.BLUETOOTH_SCAN);
            }
            if (checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT)
                    != PackageManager.PERMISSION_GRANTED) {
                needed.add(Manifest.permission.BLUETOOTH_CONNECT);
            }
        } else {
            if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)
                    != PackageManager.PERMISSION_GRANTED) {
                needed.add(Manifest.permission.ACCESS_FINE_LOCATION);
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
                && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
            needed.add(Manifest.permission.POST_NOTIFICATIONS);
        }

        if (!needed.isEmpty()) {
            requestPermissions(needed.toArray(new String[0]), REQ_PERMISSIONS);
            return;
        }

        BluetoothAdapter adapter = BluetoothAdapter.getDefaultAdapter();
        if (adapter != null && !adapter.isEnabled()) {
            Intent enable = new Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE);
            try {
                startActivityForResult(enable, REQ_ENABLE_BT);
            } catch (SecurityException ignored) {
            }
        }
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(requestCode, permissions, results);
        if (requestCode != REQ_PERMISSIONS) return;

        boolean allGranted = true;
        for (int result : results) {
            if (result != PackageManager.PERMISSION_GRANTED) allGranted = false;
        }
        if (allGranted) {
            restartConnection();
        } else {
            Toast.makeText(this, "没有蓝牙权限就无法连接 Mac", Toast.LENGTH_LONG).show();
        }
    }
}
