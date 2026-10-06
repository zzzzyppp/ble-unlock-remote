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
    /** 切换当前选中的 Mac（会断开重连） */
    public static final String ACTION_SELECT = "com.bleunlock.remote.SELECT";
    public static final String EXTRA_COMMAND = "command";

    public static final String BROADCAST_STATE = "com.bleunlock.remote.STATE";
    public static final String EXTRA_STATE = "state";
    public static final String EXTRA_DETAIL = "detail";
    /** 当前正在连接/已连接的 Mac 备注名，供界面显示 */
    public static final String EXTRA_MAC_NAME = "mac_name";

    // 状态用资源 id 表示，而不是在静态初始化时取字符串——
    // 静态上下文里拿不到 getString()，而且界面需要按当前语言实时显示。
    public static final int STATE_SCANNING = R.string.s52;
    public static final int STATE_CONNECTING = R.string.s91;
    public static final int STATE_CONNECTED = R.string.s47;
    public static final int STATE_DISCONNECTED = R.string.s65;
    public static final int STATE_SENT = R.string.s55;
    public static final int STATE_ERROR = R.string.s23;

    private static final int NOTIFICATION_ID = 1001;
    private static final String CHANNEL_ID = "ble_unlock_status";
    private static final long RECONNECT_DELAY_MS = 3000L;

    // 当前连接状态，供界面读取
    private static volatile int currentState = STATE_DISCONNECTED;
    private static volatile String currentDetail = "";

    /** 当前状态对应的字符串资源 id，由界面自行按语言解析 */
    public static int getStateRes() {
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

    /** 当前选中的 Mac 记录（多密钥支持） */
    private MacEntryStore store;
    private MacEntryStore.Entry activeEntry;
    /** 设备名提示：服务端广播以 "BLEUnlock-" 开头，用于 UUID 匹配失败时兜底 */
    private String nameHint = null;

    public class LocalBinder extends Binder {
        public BleService getService() {
            return BleService.this;
        }
    }

    @Override
    public void onCreate() {
        super.onCreate();
        createNotificationChannel();
        startForeground(NOTIFICATION_ID, buildNotification(getString(STATE_DISCONNECTED)));

        BluetoothManager manager = (BluetoothManager) getSystemService(Context.BLUETOOTH_SERVICE);
        adapter = manager != null ? manager.getAdapter() : null;
        if (adapter != null) {
            scanner = adapter.getBluetoothLeScanner();
        }
        store = new MacEntryStore(this);
        reloadActiveMac();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && intent.getAction() != null) {
            switch (intent.getAction()) {
                case ACTION_START:
                    reloadActiveMac();
                    wantConnection = true;
                    startScan();
                    break;
                case ACTION_SELECT:
                    // 切换目标 Mac：断开当前连接后重新开始
                    reloadActiveMac();
                    if (activeEntry == null) {
                        publish(STATE_ERROR, getString(R.string.s39));
                        break;
                    }
                    wantConnection = true;
                    stopScan();
                    closeGatt();
                    publish(STATE_SCANNING, getString(R.string.s42) + activeEntry.displayName() + getString(R.string.s102));
                    handler.postDelayed(this::startScan, 500);
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

    /** 重新读取选中的 Mac 记录；密钥与设备名提示一并更新 */
    private void reloadActiveMac() {
        if (store == null) store = new MacEntryStore(this);
        activeEntry = store.selected();
        if (activeEntry == null) {
            key = null;
            nameHint = null;
            return;
        }
        key = activeEntry.keyBytes();
        // 广播名形如 "BLEUnlock-xxx"，这里只取前缀做兜底匹配
        nameHint = "BLEUnlock";
    }

    /** 供界面查询当前选中的备注名 */
    public String getActiveMacName() {
        return activeEntry == null ? null : activeEntry.displayName();
    }

    private boolean hasKey() {
        if (key == null) reloadActiveMac();
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
            if (!matches && nameHint != null && name != null && name.startsWith(nameHint)) {
                matches = true;
            }
            if (!matches) return;

            Log.i(TAG, "发现目标设备 " + name + " " + device.getAddress());
            targetAddress = device.getAddress();
            if (store != null && activeEntry != null) {
                store.rememberAddress(activeEntry.id, targetAddress);
            }
            stopScan();
            connectTo(device);
        }

        @Override
        public void onScanFailed(int errorCode) {
            Log.w(TAG, "扫描失败 code=" + errorCode);
            publish(STATE_ERROR, getString(R.string.s53) + errorCode);
        }
    };

    private void startScan() {
        if (adapter == null || !adapter.isEnabled()) {
            publish(STATE_ERROR, getString(R.string.s81));
            return;
        }
        if (scanning) return;
        if (gatt != null) return; // 已有连接，无需扫描

        if (activeEntry == null) {
            publish(STATE_ERROR, getString(R.string.s40));
            return;
        }

        // 曾经连过就直接连，省掉一轮扫描（明显更快）
        if (activeEntry.address != null && !activeEntry.address.isEmpty()) {
            try {
                BluetoothDevice known = adapter.getRemoteDevice(activeEntry.address);
                publish(STATE_CONNECTING, getString(R.string.s67) + activeEntry.displayName() + "…");
                connectTo(known);
                return;
            } catch (IllegalArgumentException e) {
                // 地址非法（例如换机后残留），清掉后走扫描
                store.rememberAddress(activeEntry.id, "");
            }
        }

        scanner = adapter.getBluetoothLeScanner();
        if (scanner == null) {
            publish(STATE_ERROR, getString(R.string.s61));
            return;
        }
        try {
            ScanSettings settings = new ScanSettings.Builder()
                    .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                    .build();
            scanner.startScan(null, settings, scanCallback);
            scanning = true;
            publish(STATE_SCANNING, getString(R.string.s66) + activeEntry.displayName() + "…");
        } catch (SecurityException e) {
            publish(STATE_ERROR, getString(R.string.s79));
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
                publish(STATE_CONNECTING, getString(R.string.s48));
                try {
                    g.discoverServices();
                } catch (SecurityException e) {
                    publish(STATE_ERROR, getString(R.string.s80));
                }
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                Log.i(TAG, "连接断开 status=" + status);
                commandChar = null;
                statusChar = null;
                closeGatt();
                publish(STATE_DISCONNECTED, getString(R.string.s92));
                scheduleReconnect();
            }
        }

        @Override
        public void onServicesDiscovered(BluetoothGatt g, int status) {
            BluetoothGattService service = g.getService(Protocol.SERVICE_UUID);
            if (service == null) {
                publish(STATE_ERROR, getString(R.string.s64));
                closeGatt();
                scheduleReconnect();
                return;
            }
            commandChar = service.getCharacteristic(Protocol.CHAR_COMMAND_UUID);
            statusChar = service.getCharacteristic(Protocol.CHAR_STATUS_UUID);
            if (commandChar == null) {
                publish(STATE_ERROR, getString(R.string.s63));
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

            publish(STATE_CONNECTED, getString(R.string.s45));
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
                publish(STATE_SENT, getString(R.string.s56));
            } else {
                publish(STATE_ERROR, getString(R.string.s21) + status);
            }
        }
    };

    private void onStatusPayload(String payload) {
        if (payload == null) return;
        String text = payload.trim();
        Log.i(TAG, "Mac 状态: " + text);
        switch (text) {
            case "OK":
                publish(STATE_CONNECTED, getString(R.string.s14));
                break;
            case "UNLOCKING":
                publish(STATE_CONNECTED, getString(R.string.s10));
                break;
            case "LOCKING":
                publish(STATE_CONNECTED, getString(R.string.s11));
                break;
            case "PONG":
                publish(STATE_CONNECTED, getString(R.string.s93));
                break;
            case "READY":
            case "CONNECTED":
                break;
            case "BUSY":
                publish(STATE_ERROR, getString(R.string.s9));
                break;
            case "NOT_LOCKED":
                publish(STATE_ERROR, getString(R.string.s8));
                break;
            case "ERR_NO_AX":
                publish(STATE_ERROR, getString(R.string.s12));
                break;
            case "ERR_NO_PW":
                publish(STATE_ERROR, getString(R.string.s13));
                break;
            case "ERR_ALL_PW":
                publish(STATE_ERROR, getString(R.string.s6));
                break;
            case "ERR_INDEX":
                publish(STATE_ERROR, getString(R.string.s58));
                break;
            case "ERR_HMAC":
                publish(STATE_ERROR, getString(R.string.s97));
                break;
            case "ERR_REPLAY":
                publish(STATE_ERROR, getString(R.string.s57));
                break;
            case "ERR_TIME":
                publish(STATE_ERROR, getString(R.string.s51));
                break;
            default:
                publish(STATE_CONNECTED, "Mac: " + text);
                break;
        }
    }

    private void connectTo(BluetoothDevice device) {
        closeGatt();
        publish(STATE_CONNECTING, getString(R.string.s67) + device.getAddress());
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                gatt = device.connectGatt(this, false, gattCallback,
                        BluetoothDevice.TRANSPORT_LE);
            } else {
                gatt = device.connectGatt(this, false, gattCallback);
            }
        } catch (SecurityException e) {
            publish(STATE_ERROR, getString(R.string.s80));
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
        }
    }

    // ---------------------------------------------------------------- 发送指令

    /** 供界面直接调用。返回 null 表示成功，否则返回错误说明。 */
    public String sendCommand(byte command) {
        return sendCommand(command, false);
    }

    /**
     * 发送指令。
     *
     * @param skipLockCheck 仅对解锁有意义：让 Mac 跳过"锁屏校验"直接注入。
     *                      对应手机端「填充密码」按钮——人工明确要求现在填充，
     *                      不必再判断屏幕是否锁定。
     */
    public String sendCommand(byte command, boolean skipLockCheck) {
        if (activeEntry == null) {
            publish(STATE_ERROR, getString(R.string.s40));
            return getString(R.string.s39);
        }
        if (!hasKey()) {
            publish(STATE_ERROR, activeEntry.displayName() + getString(R.string.s4));
            return getString(R.string.s16);
        }
        BluetoothGatt g = gatt;
        BluetoothGattCharacteristic c = commandChar;
        if (g == null || c == null) {
            publish(STATE_ERROR, getString(R.string.s37));
            return getString(R.string.s37);
        }

        try {
            // 解锁时带上"用第几个密码"。手机不保存密码本身，
            // 只告诉 Mac 优先试哪一个；Mac 上该密码不对时会自动回退试其余。
            int pwIndex = -1;
            if (command == Protocol.CMD_UNLOCK && activeEntry != null) {
                pwIndex = Math.max(0, activeEntry.preferredPassword);
            }
            byte[] packet = Protocol.buildPacket(command, key, pwIndex, skipLockCheck);
            c.setWriteType(BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT);
            c.setValue(packet);
            boolean ok = g.writeCharacteristic(c);
            if (!ok) {
                publish(STATE_ERROR, getString(R.string.s22));
                return getString(R.string.s22);
            }
            publish(STATE_SENT, skipLockCheck ? getString(R.string.s33) : getString(R.string.s54));
            return null;
        } catch (Exception e) {
            Log.e(TAG, "发送失败", e);
            publish(STATE_ERROR, getString(R.string.s27) + e.getMessage());
            return getString(R.string.s27) + e.getMessage();
        }
    }

    private void publish(int stateRes, String detail) {
        currentState = stateRes;
        currentDetail = detail;
        updateNotification(getString(stateRes));

        Intent intent = new Intent(BROADCAST_STATE);
        intent.setPackage(getPackageName());
        intent.putExtra(EXTRA_STATE, stateRes);
        intent.putExtra(EXTRA_DETAIL, detail);
        intent.putExtra(EXTRA_MAC_NAME, getActiveMacName());
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
                .setContentTitle(getString(R.string.app_name))
                .setContentText(state)
                .setSmallIcon(android.R.drawable.ic_lock_idle_lock)
                .setContentIntent(pending)
                .setOngoing(true)
                .addAction(new Notification.Action.Builder(null, getString(R.string.s83), unlockPending).build())
                .build();
    }

    private void updateNotification(String state) {
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (nm != null) nm.notify(NOTIFICATION_ID, buildNotification(state));
    }
}
