package com.bleunlock.remote;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothGatt;
import android.bluetooth.BluetoothGattCallback;
import android.bluetooth.BluetoothGattCharacteristic;
import android.bluetooth.BluetoothGattDescriptor;
import android.bluetooth.BluetoothGattService;
import android.bluetooth.BluetoothManager;
import android.bluetooth.BluetoothProfile;
import android.bluetooth.le.BluetoothLeScanner;
import android.bluetooth.le.ScanCallback;
import android.bluetooth.le.ScanResult;
import android.bluetooth.le.ScanSettings;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Binder;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.util.Log;

import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.UUID;

import android.content.BroadcastReceiver;
import android.content.IntentFilter;
import android.os.ParcelUuid;

/**
 * 前台服务：维持与 Mac 的 BLE 连接，并负责发送解锁/锁定指令。
 * 用前台服务是为了在手机锁屏时依然保持连接，从而实现「拿起手机点一下就能解锁 Mac」。
 */
public class BleService extends Service {

    private static final String TAG = "BleService";

    public static final String ACTION_START = "com.bleunlock.remote.START";
    public static final String ACTION_STOP = "com.bleunlock.remote.STOP";
    public static final String ACTION_SEND = "com.bleunlock.remote.SEND";
    public static final String EXTRA_COMMAND = "command";

    public static final String BROADCAST_STATE = "com.bleunlock.remote.STATE";
    public static final String EXTRA_STATE = "state";
    public static final String EXTRA_DETAIL = "detail";

    public static final String STATE_SCANNING = "扫描中";
    public static final String STATE_CONNECTING = "连接中";
    public static final String STATE_CONNECTED = "已连接";
    public static final String STATE_DISCONNECTED = "未连接";
    public static final String STATE_SENT = "指令已发送";
    public static final String STATE_ERROR = "出错";

    private static final int NOTIFICATION_ID = 1001;
    private static final String CHANNEL_ID = "ble_unlock_status";
    private static final long RECONNECT_DELAY_MS = 3000L;

    // 当前连接状态，供界面读取
    private static volatile String currentState = STATE_DISCONNECTED;
    private static volatile String currentDetail = "";

    public static String getState() {
        return currentState;
    }

    public static String getDetail() {
        return currentDetail;
    }

    private final IBinder binder = new LocalBinder();
    private final Handler handler = new Handler(Looper.getMainLooper());

    private BluetoothAdapter adapter;
    private BluetoothLeScanner scanner;
    private BluetoothGatt gatt;
    private BluetoothGattCharacteristic commandChar;
    private BluetoothGattCharacteristic statusChar;

    private boolean wantConnection = false;
    private boolean scanning = false;
    private String targetAddress = null;
    private byte[] key = null;

    public class LocalBinder extends Binder {
        public BleService getService() {
            return BleService.this;
        }
    }

    @Override
    public void onCreate() {
        super.onCreate();
        createNotificationChannel();
        startForeground(NOTIFICATION_ID, buildNotification(STATE_DISCONNECTED));

        BluetoothManager manager = (BluetoothManager) getSystemService(Context.BLUETOOTH_SERVICE);
        adapter = manager != null ? manager.getAdapter() : null;
        if (adapter != null) {
            scanner = adapter.getBluetoothLeScanner();
        }
        reloadKey();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && intent.getAction() != null) {
            switch (intent.getAction()) {
                case ACTION_START:
                    reloadKey();
                    wantConnection = true;
                    startScan();
                    break;
                case ACTION_STOP:
                    wantConnection = false;
                    stopScan();
                    closeGatt();
                    stopForeground(true);
                    stopSelf();
                    break;
                case ACTION_SEND:
                    byte command = intent.getByteExtra(EXTRA_COMMAND, Protocol.CMD_UNLOCK);
                    sendCommand(command);
                    break;
                default:
                    break;
            }
        }
        return START_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return binder;
    }

    @Override
    public void onDestroy() {
        wantConnection = false;
        stopScan();
        closeGatt();
        super.onDestroy();
    }

    // ---------------------------------------------------------------- 密钥

    private void reloadKey() {
        SharedPreferences prefs = getSharedPreferences(MainActivity.PREFS, MODE_PRIVATE);
        String token = prefs.getString(MainActivity.KEY_TOKEN, "");
        key = Protocol.parseToken(token);
    }

    private boolean hasKey() {
        if (key == null) reloadKey();
        return key != null;
    }

    // ---------------------------------------------------------------- 扫描

    private final ScanCallback scanCallback = new ScanCallback() {
        @Override
        public void onScanResult(int callbackType, ScanResult result) {
            BluetoothDevice device = result.getDevice();
            if (device == null) return;

            // 优先用服务 UUID 匹配；部分设备广播包被截断时退回按名字匹配
            boolean matches = false;
            List<ParcelUuid> uuids = result.getScanRecord() != null
                    ? result.getScanRecord().getServiceUuids() : null;
            if (uuids != null) {
                for (ParcelUuid u : uuids) {
                    if (Protocol.SERVICE_UUID.equals(u.getUuid())) {
                        matches = true;
                        break;
                    }
                }
            }
            String name = result.getScanRecord() != null ? result.getScanRecord().getDeviceName() : null;
            if (name == null) {
                try {
                    name = device.getName();
                } catch (SecurityException ignored) {
                }
            }
            if (!matches && name != null && name.startsWith("BLEUnlock")) {
                matches = true;
            }
            if (!matches) return;

            Log.i(TAG, "发现目标设备 " + name + " " + device.getAddress());
            targetAddress = device.getAddress();
            stopScan();
            connectTo(device);
        }

        @Override
        public void onScanFailed(int errorCode) {
            Log.w(TAG, "扫描失败 code=" + errorCode);
            publish(STATE_ERROR, "扫描失败，错误码 " + errorCode);
        }
    };

    private void startScan() {
        if (adapter == null || !adapter.isEnabled()) {
            publish(STATE_ERROR, "蓝牙未开启");
            return;
        }
        if (scanning) return;
        if (gatt != null) return; // 已有连接，无需扫描

        scanner = adapter.getBluetoothLeScanner();
        if (scanner == null) {
            publish(STATE_ERROR, "无法获取蓝牙扫描器");
            return;
        }
        try {
            ScanSettings settings = new ScanSettings.Builder()
                    .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                    .build();
            scanner.startScan(null, settings, scanCallback);
            scanning = true;
            publish(STATE_SCANNING, "正在搜索 Mac…");
        } catch (SecurityException e) {
            publish(STATE_ERROR, "缺少蓝牙扫描权限");
        }
    }

    private void stopScan() {
        if (!scanning) return;
        scanning = false;
        try {
            if (scanner != null) scanner.stopScan(scanCallback);
        } catch (SecurityException ignored) {
        }
    }

    // ---------------------------------------------------------------- 连接

    private final BluetoothGattCallback gattCallback = new BluetoothGattCallback() {
        @Override
        public void onConnectionStateChange(BluetoothGatt g, int status, int newState) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                Log.i(TAG, "已连接，开始发现服务");
                publish(STATE_CONNECTING, "已连接，正在发现服务…");
                try {
                    g.discoverServices();
                } catch (SecurityException e) {
                    publish(STATE_ERROR, "缺少蓝牙连接权限");
                }
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                Log.i(TAG, "连接断开 status=" + status);
                commandChar = null;
                statusChar = null;
                closeGatt();
                publish(STATE_DISCONNECTED, "连接已断开");
                scheduleReconnect();
            }
        }

        @Override
        public void onServicesDiscovered(BluetoothGatt g, int status) {
            BluetoothGattService service = g.getService(Protocol.SERVICE_UUID);
            if (service == null) {
                publish(STATE_ERROR, "未找到目标服务，请确认 Mac 端已启动");
                closeGatt();
                scheduleReconnect();
                return;
            }
            commandChar = service.getCharacteristic(Protocol.CHAR_COMMAND_UUID);
            statusChar = service.getCharacteristic(Protocol.CHAR_STATUS_UUID);
            if (commandChar == null) {
                publish(STATE_ERROR, "未找到指令特征");
                closeGatt();
                scheduleReconnect();
                return;
            }

            // 订阅状态特征，Mac 可以直接把执行结果推过来
            if (statusChar != null) {
                try {
                    g.setCharacteristicNotification(statusChar, true);
                    BluetoothGattDescriptor desc = statusChar.getDescriptor(
                            UUID.fromString("00002902-0000-1000-8000-00805f9b34fb"));
                    if (desc != null) {
                        desc.setValue(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE);
                        g.writeDescriptor(desc);
                    }
                } catch (SecurityException ignored) {
                }
            }

            // 读一次当前状态
            if (statusChar != null) {
                try {
                    g.readCharacteristic(statusChar);
                } catch (SecurityException ignored) {
                }
            }

            publish(STATE_CONNECTED, "已就绪，可以解锁");
        }

        @Override
        public void onCharacteristicChanged(BluetoothGatt g, BluetoothGattCharacteristic c) {
            if (c.getValue() != null) {
                onStatusPayload(new String(c.getValue(), StandardCharsets.UTF_8));
            }
        }

        @Override
        public void onCharacteristicRead(BluetoothGatt g, BluetoothGattCharacteristic c, int status) {
            if (c.getValue() != null) {
                onStatusPayload(new String(c.getValue(), StandardCharsets.UTF_8));
            }
        }

        @Override
        public void onCharacteristicWrite(BluetoothGatt g, BluetoothGattCharacteristic c, int status) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                publish(STATE_SENT, "指令已送达 Mac");
            } else {
                publish(STATE_ERROR, "写入失败，状态码 " + status);
            }
        }
    };

    private void onStatusPayload(String payload) {
        if (payload == null) return;
        String text = payload.trim();
        Log.i(TAG, "Mac 状态: " + text);
        switch (text) {
            case "OK":
                publish(STATE_CONNECTED, "✅ Mac 已解锁");
                break;
            case "UNLOCKING":
                publish(STATE_CONNECTED, "Mac 正在解锁…");
                break;
            case "LOCKING":
                publish(STATE_CONNECTED, "Mac 正在锁定…");
                break;
            case "PONG":
                publish(STATE_CONNECTED, "连接正常 (PONG)");
                break;
            case "READY":
            case "CONNECTED":
                break;
            case "BUSY":
                publish(STATE_ERROR, "Mac 正在处理上一条指令");
                break;
            case "NOT_LOCKED":
                publish(STATE_ERROR, "Mac 屏幕当前未锁定");
                break;
            case "ERR_NO_AX":
                publish(STATE_ERROR, "Mac 缺少「辅助功能」权限");
                break;
            case "ERR_NO_PW":
                publish(STATE_ERROR, "Mac 钥匙串中没有密码");
                break;
            case "ERR_HMAC":
                publish(STATE_ERROR, "配对密钥错误");
                break;
            case "ERR_REPLAY":
                publish(STATE_ERROR, "指令被拒绝（重放）");
                break;
            case "ERR_TIME":
                publish(STATE_ERROR, "手机与 Mac 时间相差过大，请校准时间");
                break;
            default:
                publish(STATE_CONNECTED, "Mac: " + text);
                break;
        }
    }

    private void connectTo(BluetoothDevice device) {
        closeGatt();
        publish(STATE_CONNECTING, "正在连接 " + device.getAddress());
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                gatt = device.connectGatt(this, false, gattCallback,
                        BluetoothDevice.TRANSPORT_LE);
            } else {
                gatt = device.connectGatt(this, false, gattCallback);
            }
        } catch (SecurityException e) {
            publish(STATE_ERROR, "缺少蓝牙连接权限");
        }
    }

    private void scheduleReconnect() {
        if (!wantConnection) return;
        handler.removeCallbacksAndMessages(null);
        handler.postDelayed(this::startScan, RECONNECT_DELAY_MS);
    }

    private void closeGatt() {
        BluetoothGatt g = gatt;
        gatt = null;
        if (g != null) {
            try {
                g.close();
            } catch (SecurityException ignored) {
            }
            g.close();
        }
    }

    // ---------------------------------------------------------------- 发送指令

    /** 供界面直接调用。返回 null 表示成功，否则返回错误说明。 */
    public String sendCommand(byte command) {
        if (!hasKey()) {
            publish(STATE_ERROR, "请先填写配对令牌");
            return "请先填写配对令牌";
        }
        BluetoothGatt g = gatt;
        BluetoothGattCharacteristic c = commandChar;
        if (g == null || c == null) {
            publish(STATE_ERROR, "尚未连接到 Mac");
            return "尚未连接到 Mac";
        }

        try {
            byte[] packet = Protocol.buildPacket(command, key);
            c.setWriteType(BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT);
            c.setValue(packet);
            boolean ok = g.writeCharacteristic(c);
            if (!ok) {
                publish(STATE_ERROR, "写入请求被系统拒绝");
                return "写入请求被系统拒绝";
            }
            publish(STATE_SENT, "指令已发出");
            return null;
        } catch (Exception e) {
            Log.e(TAG, "发送失败", e);
            publish(STATE_ERROR, "发送失败: " + e.getMessage());
            return "发送失败: " + e.getMessage();
        }
    }

    private void publish(String state, String detail) {
        currentState = state;
        currentDetail = detail;
        updateNotification(state);

        Intent intent = new Intent(BROADCAST_STATE);
        intent.setPackage(getPackageName());
        intent.putExtra(EXTRA_STATE, state);
        intent.putExtra(EXTRA_DETAIL, detail);
        sendBroadcast(intent);
    }

    // ---------------------------------------------------------------- 通知

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return;
        NotificationManager nm = getSystemService(NotificationManager.class);
        if (nm == null) return;
        NotificationChannel channel = new NotificationChannel(CHANNEL_ID,
                getString(R.string.channel_name), NotificationManager.IMPORTANCE_LOW);
        channel.setDescription(getString(R.string.channel_desc));
        channel.setShowBadge(false);
        nm.createNotificationChannel(channel);
    }

    private Notification buildNotification(String state) {
        Intent open = new Intent(this, MainActivity.class);
        PendingIntent pending = PendingIntent.getActivity(this, 0, open,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        Intent unlockIntent = new Intent(this, BleService.class);
        unlockIntent.setAction(ACTION_SEND);
        unlockIntent.putExtra(EXTRA_COMMAND, Protocol.CMD_UNLOCK);
        PendingIntent unlockPending = PendingIntent.getService(this, 1, unlockIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        Notification.Builder builder = (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);

        return builder
                .setContentTitle("BLE Unlock")
                .setContentText(state)
                .setSmallIcon(android.R.drawable.ic_lock_idle_lock)
                .setContentIntent(pending)
                .setOngoing(true)
                .addAction(new Notification.Action.Builder(null, "解锁 Mac", unlockPending).build())
                .build();
    }

    private void updateNotification(String state) {
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (nm != null) nm.notify(NOTIFICATION_ID, buildNotification(state));
    }
}
