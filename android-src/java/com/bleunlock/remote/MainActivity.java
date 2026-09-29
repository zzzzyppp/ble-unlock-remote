package com.bleunlock.remote;

import android.Manifest;
import android.app.Activity;
import android.bluetooth.BluetoothAdapter;
import android.content.BroadcastReceiver;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.ServiceConnection;
import android.content.SharedPreferences;
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
import android.view.Gravity;
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
 * 主界面：一个解锁按钮 + 配对令牌设置 + 连接状态。
 * 界面完全用代码构建，避免依赖 AppCompat 等第三方库。
 */
public class MainActivity extends Activity {

    public static final String PREFS = "ble_unlock_prefs";
    public static final String KEY_TOKEN = "token";

    private static final int REQ_PERMISSIONS = 2001;
    private static final int REQ_ENABLE_BT = 2002;

    private TextView statusView;
    private TextView detailView;
    private EditText tokenView;
    private Button unlockButton;
    private Button connectButton;

    private BleService service;
    private boolean bound = false;
    private SharedPreferences prefs;

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
        prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
        setContentView(buildUi());

        String token = prefs.getString(KEY_TOKEN, "");
        tokenView.setText(token);

        registerStateReceiver();
        bindToService();
    }

    @Override
    protected void onResume() {
        super.onResume();
        handler.post(uiRefresh);
        ensurePermissions();
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
        root.setBackgroundColor(Color.parseColor("#111418"));

        TextView title = new TextView(this);
        title.setText("BLE Unlock");
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 26);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        title.setTextColor(Color.parseColor("#FFFFFF"));
        root.addView(title);

        TextView subtitle = new TextView(this);
        subtitle.setText("点一下按钮即可解锁你的 Mac");
        subtitle.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        subtitle.setTextColor(Color.parseColor("#9AA4B2"));
        subtitle.setPadding(0, dp(4), 0, dp(18));
        root.addView(subtitle);

        // 状态卡片
        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setBackgroundColor(Color.parseColor("#1B2027"));
        card.setPadding(dp(16), dp(14), dp(16), dp(14));

        statusView = new TextView(this);
        statusView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 18);
        statusView.setTypeface(Typeface.DEFAULT_BOLD);
        statusView.setTextColor(Color.parseColor("#FFFFFF"));
        card.addView(statusView);

        detailView = new TextView(this);
        detailView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        detailView.setTextColor(Color.parseColor("#9AA4B2"));
        detailView.setPadding(0, dp(4), 0, 0);
        card.addView(detailView);

        root.addView(card);

        // 解锁按钮
        unlockButton = new Button(this);
        unlockButton.setText("解 锁");
        unlockButton.setTextSize(TypedValue.COMPLEX_UNIT_SP, 22);
        unlockButton.setTypeface(Typeface.DEFAULT_BOLD);
        unlockButton.setTextColor(Color.WHITE);
        unlockButton.setBackgroundColor(Color.parseColor("#2E7D32"));
        LinearLayout.LayoutParams unlockLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(96));
        unlockLp.topMargin = dp(18);
        unlockButton.setLayoutParams(unlockLp);
        unlockButton.setOnClickListener(v -> doSend(Protocol.CMD_UNLOCK));
        root.addView(unlockButton);

        // 次要按钮
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        LinearLayout.LayoutParams rowLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        rowLp.topMargin = dp(10);
        row.setLayoutParams(rowLp);

        connectButton = new Button(this);
        connectButton.setText("重新连接");
        connectButton.setTextColor(Color.WHITE);
        connectButton.setBackgroundColor(Color.parseColor("#37474F"));
        LinearLayout.LayoutParams half = new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        half.rightMargin = dp(5);
        connectButton.setLayoutParams(half);
        connectButton.setOnClickListener(v -> restartConnection());
        row.addView(connectButton);

        Button lockButton = new Button(this);
        lockButton.setText("锁定 Mac");
        lockButton.setTextColor(Color.WHITE);
        lockButton.setBackgroundColor(Color.parseColor("#5D4037"));
        LinearLayout.LayoutParams half2 = new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        half2.leftMargin = dp(5);
        lockButton.setLayoutParams(half2);
        lockButton.setOnClickListener(v -> doSend(Protocol.CMD_LOCK));
        row.addView(lockButton);

        root.addView(row);

        // 配对令牌
        TextView tokenLabel = new TextView(this);
        tokenLabel.setText("配对令牌（在 Mac 上运行 ./mac-ble-unlock.sh token 获取）");
        tokenLabel.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        tokenLabel.setTextColor(Color.parseColor("#9AA4B2"));
        tokenLabel.setPadding(0, dp(24), 0, dp(6));
        root.addView(tokenLabel);

        tokenView = new EditText(this);
        tokenView.setHint("32 字节密钥的 base64 或十六进制");
        tokenView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        tokenView.setTextColor(Color.parseColor("#FFFFFF"));
        tokenView.setHintTextColor(Color.parseColor("#5A6470"));
        tokenView.setInputType(InputType.TYPE_CLASS_TEXT
                | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        tokenView.setBackgroundColor(Color.parseColor("#1B2027"));
        tokenView.setPadding(dp(12), dp(12), dp(12), dp(12));
        root.addView(tokenView);

        Button saveToken = new Button(this);
        saveToken.setText("保存令牌并连接");
        saveToken.setTextColor(Color.WHITE);
        saveToken.setBackgroundColor(Color.parseColor("#1565C0"));
        LinearLayout.LayoutParams saveLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        saveLp.topMargin = dp(10);
        saveToken.setLayoutParams(saveLp);
        saveToken.setOnClickListener(v -> saveToken());
        root.addView(saveToken);

        TextView hint = new TextView(this);
        hint.setText("提示：Mac 端需要开启「辅助功能」权限，并把登录密码存入钥匙串。"
                + "首次使用请先运行安装脚本完成配置。");
        hint.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        hint.setTextColor(Color.parseColor("#6B7684"));
        hint.setPadding(0, dp(20), 0, 0);
        root.addView(hint);

        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(Color.parseColor("#111418"));
        scroll.addView(root, new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        return scroll;
    }

    private int dp(int value) {
        return (int) (value * getResources().getDisplayMetrics().density);
    }

    // ------------------------------------------------------------ 交互

    private void saveToken() {
        String raw = tokenView.getText().toString();
        byte[] key = Protocol.parseToken(raw);
        if (key == null) {
            Toast.makeText(this, "令牌格式不对：应为 32 字节的 base64 或 64 位十六进制",
                    Toast.LENGTH_LONG).show();
            return;
        }
        prefs.edit().putString(KEY_TOKEN, raw.trim()).apply();
        Toast.makeText(this, "已保存（指纹 " + Protocol.fingerprint(key) + "）",
                Toast.LENGTH_SHORT).show();
        restartConnection();
    }

    private void restartConnection() {
        Intent stop = new Intent(this, BleService.class);
        stop.setAction(BleService.ACTION_STOP);
        startService(stop);

        Intent start = new Intent(this, BleService.class);
        start.setAction(BleService.ACTION_START);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(start);
        } else {
            startService(start);
        }
        handler.postDelayed(this::bindToService, 300);
        Toast.makeText(this, "正在重新连接…", Toast.LENGTH_SHORT).show();
    }

    private void doSend(byte command) {
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
        String state = BleService.getState();
        String detail = BleService.getDetail();

        statusView.setText(state);
        detailView.setText(detail);

        if (BleService.STATE_CONNECTED.equals(state)) {
            statusView.setTextColor(Color.parseColor("#66BB6A"));
            unlockButton.setEnabled(true);
            unlockButton.setBackgroundColor(Color.parseColor("#2E7D32"));
        } else if (BleService.STATE_ERROR.equals(state)) {
            statusView.setTextColor(Color.parseColor("#EF5350"));
            unlockButton.setEnabled(true);
            unlockButton.setBackgroundColor(Color.parseColor("#37474F"));
        } else {
            statusView.setTextColor(Color.parseColor("#FFCA28"));
            unlockButton.setEnabled(true);
            unlockButton.setBackgroundColor(Color.parseColor("#37474F"));
        }
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
