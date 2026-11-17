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
import android.bluetooth.le.ScanFilter;
import android.bluetooth.le.ScanRecord;
import android.bluetooth.le.ScanResult;
import android.bluetooth.le.ScanSettings;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.os.Binder;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.ParcelUuid;
import android.os.SystemClock;
import android.util.Log;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.UUID;

/**
 * 前台服务：维持与 Mac 的 BLE 连接，并负责发送解锁/锁定指令。
 * 用前台服务是为了在手机锁屏时依然保持连接，从而实现「拿起手机点一下就能解锁 Mac」。
 *
 * 1.4.1 连接流程（scan-first）：
 *   扫描（BLEUnlock 服务 UUID，缓存地址只作为 ScanFilter 提示）→ 命中后按
 *   「历史广播名 / 地址提示 / 信号」挑出目标 Mac → connectGatt → 150ms 后
 *   discoverServices → 校验 status → requestMtu(517)（等回调或 800ms 超时）→
 *   requestConnectionPriority(HIGH) → 读 INFO 校验身份 → 写 CCCD 并等
 *   onDescriptorWrite → 读 STATUS → 发布 READY/STATE_CONNECTED。
 *
 * 关键点：
 *   - 任何一次建链都有 7s 看门狗，失败会以 300ms/900ms/1800ms 重试，最多 3 次后
 *     发布可重试错误并进入 5s 冷却重扫；绝不会停在「连接中」。
 *   - 第一次成功连接后记住该 Mac 的广播名（写入本服务自己的 prefs），之后用
 *     「广播名 + 地址提示」交叉校验身份；连接后再读 INFO 特征做最终确认。
 *   - READY 只在 CCCD 写完并成功读到 STATUS 之后发布，因此「已连接」一定有
 *     新订阅/状态读取证据（日志里标 new-link）。
 */
public class BleService extends Service {

    private static final String TAG = "BleService";

    public static final String ACTION_START = "com.bleunlock.remote.START";
    public static final String ACTION_STOP = "com.bleunlock.remote.STOP";
    public static final String ACTION_SEND = "com.bleunlock.remote.SEND";
    /** 切换当前选中的 Mac（会断开重连） */
    public static final String ACTION_SELECT = "com.bleunlock.remote.SELECT";
    /**
     * 重新连接当前 Mac。
     * 替代旧版「先 STOP 再 START」的做法，避免 stopSelf 与随后的 START 竞态。
     */
    public static final String ACTION_RECONNECT = "com.bleunlock.remote.RECONNECT";
    public static final String EXTRA_COMMAND = "command";

    public static final String BROADCAST_STATE = "com.bleunlock.remote.STATE";
    public static final String EXTRA_STATE = "state";
    public static final String EXTRA_DETAIL = "detail";
    /** 当前正在连接/已连接的 Mac 备注名，供界面显示 */
    public static final String EXTRA_MAC_NAME = "mac_name";

    /** 持久化「用户希望保持连接」，START_STICKY / 开机后据此恢复 */
    public static final String KEY_WANT_CONNECTION = "want_connection_141";
    /** 每台 Mac 历史上广播过的设备名（用于多 Mac 场景交叉校验） */
    private static final String KEY_DEVICE_NAME_PREFIX = "dev_name_";
    /** 被证明不可达/身份不符的地址提示；只影响本服务的扫描策略 */
    private static final String KEY_STALE_ADDR_PREFIX = "stale_addr_";

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

    // ---- 时序常量（research.md §3 的建议值，单位 ms） ----
    /**
     * 单轮扫描上限：到点仍未命中就按失败重试。
     * 故意取较长窗口：Android 14+ 对「扫描启动次数」有限流（实测 30s 内超过 5 次
     * 就报 "App is scanning too frequently" 并静默 0 结果），长窗口 = 少启动。
     */
    private static final long SCAN_WINDOW_MS = 8000L;
    /** 没有任何身份线索（首次使用）时，先收集候选再选，避免「连第一台」 */
    private static final long SCAN_AMBIGUOUS_WINDOW_MS = 450L;
    /** 每次 connectGatt 的建链看门狗：6–8s 内必须落到 connected/failed */
    private static final long CONNECT_WATCHDOG_MS = 7000L;
    /** 建链成功后的握手窗口：discover+MTU+INFO+CCCD+STATUS 串行，慢设备合法耗时可能超过 7s */
    private static final long HANDSHAKE_WATCHDOG_MS = 15000L;
    private static final long DISCOVERY_TIMEOUT_MS = 3000L;
    private static final long MTU_TIMEOUT_MS = 800L;
    private static final long INFO_TIMEOUT_MS = 800L;
    private static final long CCCD_TIMEOUT_MS = 1500L;
    private static final long READ_TIMEOUT_MS = 1500L;
    /** closeGatt 之后稍等再 connectGatt，避免复用半死的 LE 链路 */
    private static final long GATT_SETTLE_MS = 80L;
    private static final int MTU_REQUEST = 517;
    private static final int MAX_ATTEMPTS = 3;
    private static final long[] RETRY_DELAYS_MS = {300L, 900L, 1800L};
    private static final long COOLDOWN_RETRY_MS = 6000L;
    /** 连续失败时的冷却上限：目标整夜不在场也不会一直低延迟扫描 */
    private static final long MAX_COOLDOWN_RETRY_MS = 120000L;
    private static final long SCAN_FAILURE_RETRY_MS = 1000L;
    /**
     * Android 14+ 对「App 扫描启动次数」限流：实测 30s 内超过 5 次就持续报
     * "App is scanning too frequently"（连 filtered 扫描都起不来，且没有 onScanFailed）。
     * 这里用 4 次/30s 的保守配额，并保证两次启动至少间隔 1s。
     */
    private static final int MAX_SCAN_STARTS_PER_WINDOW = 4;
    private static final long SCAN_START_WINDOW_MS = 30000L;
    private static final long MIN_SCAN_START_GAP_MS = 1000L;
    /**
     * filtered 扫描启动后 800ms 内仍没有任何原始结果 → 在同一 8s 窗口内改起一次 unfiltered。
     * 部分机型/控制器对 128-bit service UUID filter 做 offload 后可能静默 0 结果，
     * 或目标广播只出现在 scan response 里；unfiltered 回调仍按 UUID/广播名/地址提示匹配。
     */
    private static final long SCAN_FALLBACK_AFTER_MS = 800L;
    /** filtered 扫描在本机被证明静默无结果后写入 prefs，后续直接走无过滤扫描 */
    private static final String KEY_FILTERED_SCAN_BROKEN = "filtered_scan_broken";
    /** 旧版本写入过 filtered_scan_broken；现已废弃，读到就清掉，避免自锁死 */
    private static final boolean RESET_FILTERED_SCAN_BROKEN_ON_START = true;

    private static final UUID CCCD_DESCRIPTOR_UUID =
            UUID.fromString("00002902-0000-1000-8000-00805f9b34fb");

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
    private BluetoothGattCharacteristic infoChar;

    private SharedPreferences prefs;

    private boolean wantConnection = false;
    private boolean scanning = false;
    private boolean ready = false;
    private boolean connecting = false;

    private byte[] key = null;

    /** 当前选中的 Mac 记录（多密钥支持） */
    private MacEntryStore store;
    private MacEntryStore.Entry activeEntry;
    /** 兜底匹配：广播名以 "BLEUnlock-" 开头 */
    private String nameHint = "BLEUnlock";
    /** 该 Mac 历史上出现过的广播名（可被 INFO 特征校正） */
    private String expectedDeviceName = null;
    /** 来自 MacEntryStore 的地址提示；只用于 ScanFilter / 打分，绝不直接 connectGatt */
    private String addressHint = null;

    /** 本次建链实际尝试的地址/广播名，成功后写回提示 */
    private String attemptedAddress = null;
    /** 普通失败后被清除的地址提示；下一次重试允许再次作为 ScanFilter 提示（地址不是身份） */
    private String transientAddress = null;
    private String attemptedName = null;

    /** 防止旧连接/旧定时器回调影响新连接 */
    private int generation = 0;
    /** SCAN=扫描，CONNECT=等 onConnectionStateChange，DISCOVERING/MTU/INFO/CCCD/STATUS=GATT 阶段 */
    private String stage = "idle";
    /** 单轮扫描开始时间（用于 [lat] elapsed） */
    private long t0 = 0L;
    private long connectStartedAt = 0L;

    private int attempt = 0;
    /** 连续「整轮失败」计数：用于把冷却间隔按 6s→12s→24s→48s→96s→120s 拉长 */
    private int failureStreak = 0;
    private int nameMissStreak = 0;
    private int scanFailStreak = 0;
    private boolean mtuDone = false;
    private boolean mtuRetried = false;
    private boolean cccdRetried = false;
    private boolean statusReadRetried = false;

    /** 本次扫描的候选 */
    private ScanResult bestCandidate = null;
    private int bestScore = Integer.MIN_VALUE;
    private String bestReason = "";
    private long firstCandidateAt = 0L;
    /** 本轮扫描收到的原始结果数（含非目标）：用于识别 filter offload 静默失败 */
    private int rawScanCount = 0;
    /** filtered / unfiltered：本轮扫描当前走哪条路径 */
    private String scanPass = "filtered";
    /** 上一次真正调用 scanner.startScan 的时间，以及 30s 窗口内的启动历史（用于限流） */
    private long lastScanStartAt = 0L;
    private final java.util.ArrayDeque<Long> scanStartTimes = new java.util.ArrayDeque<>();
    /** 本轮失败过/身份不符的地址，避免在同一个候选上反复打转 */
    private final Set<String> excludedAddresses = new HashSet<>();

    private Runnable scanTimeoutRunnable;
    private Runnable chooseRunnable;
    private Runnable connectWatchdogRunnable;
    private Runnable stageTimeoutRunnable;
    private Runnable retryRunnable;
    private Runnable scanFallbackRunnable;
    /** 扫描被限流时的延迟启动任务：必须可取消，否则旧任务会在新一轮扫描里再触发一次 */
    private Runnable scanRateRunnable;

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

        prefs = getSharedPreferences(MacEntryStore.PREFS, Context.MODE_PRIVATE);
        wantConnection = prefs.getBoolean(KEY_WANT_CONNECTION, false);

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
        String action = intent != null ? intent.getAction() : null;
        if (action == null) {
            // START_STICKY 重建（进程被杀/系统回收）时 intent 为 null，按持久化意愿恢复
            reloadActiveMac();
            wantConnection = prefs.getBoolean(KEY_WANT_CONNECTION, false);
            Log.i(TAG, "服务被系统重建，wantConnection=" + wantConnection);
            if (wantConnection && activeEntry != null && gatt == null && !scanning) {
                lat("restore", "sticky restart");
                startScan("sticky");
            }
            return START_STICKY;
        }

        switch (action) {
            case ACTION_START: {
                reloadActiveMac();
                if (activeEntry == null) {
                    publish(STATE_ERROR, getString(R.string.s40));
                    break;
                }
                setWantConnection(true);
                if (ready && gatt != null) {
                    // 幂等：已在目标 Mac 上就绪，重复 START 不打断连接
                    publish(STATE_CONNECTED, getString(R.string.s45));
                    break;
                }
                if (scanning || gatt != null) {
                    Log.i(TAG, "已经在连接流程中，忽略重复 START");
                    break;
                }
                cancelRetry();
                resetAttemptCampaign(false);
                startScan("start");
                break;
            }
            case ACTION_SELECT: {
                reloadActiveMac();
                if (activeEntry == null) {
                    publish(STATE_ERROR, getString(R.string.s39));
                    break;
                }
                setWantConnection(true);
                resetConnection("select");
                attempt = 0;
                failureStreak = 0;
                excludedAddresses.clear();
                publish(STATE_SCANNING, getString(R.string.s42)
                        + activeEntry.displayName() + getString(R.string.s102));
                startScan("select");
                break;
            }
            case ACTION_RECONNECT: {
                reloadActiveMac();
                if (activeEntry == null) {
                    publish(STATE_ERROR, getString(R.string.s39));
                    break;
                }
                setWantConnection(true);
                resetConnection("reconnect");
                attempt = 0;
                failureStreak = 0;
                excludedAddresses.clear();
                startScan("reconnect");
                break;
            }
            case ACTION_STOP: {
                setWantConnection(false);
                resetConnection("stop");
                publish(STATE_DISCONNECTED, getString(R.string.s65));
                stopForeground(true);
                stopSelf();
                break;
            }
            case ACTION_SEND: {
                if (!ready && wantConnection && gatt == null && !scanning) {
                    startScan("send");
                }
                byte command = intent.getByteExtra(EXTRA_COMMAND, Protocol.CMD_UNLOCK);
                sendCommand(command);
                break;
            }
            default:
                break;
        }
        return START_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return binder;
    }

    @Override
    public void onDestroy() {
        Log.i(TAG, "服务销毁（不影响持久化的 wantConnection）");
        cancelTimers();
        stopScan();
        closeGatt();
        super.onDestroy();
    }

    // ---------------------------------------------------------------- 密钥与身份

    /** 重新读取选中的 Mac 记录；密钥、地址提示与历史广播名一并更新 */
    private void reloadActiveMac() {
        if (store == null) store = new MacEntryStore(this);
        if (prefs == null) {
            prefs = getSharedPreferences(MacEntryStore.PREFS, Context.MODE_PRIVATE);
        }
        activeEntry = store.selected();
        expectedDeviceName = null;
        addressHint = null;
        if (activeEntry == null) {
            key = null;
            return;
        }
        key = activeEntry.keyBytes();
        expectedDeviceName = prefs.getString(KEY_DEVICE_NAME_PREFIX + activeEntry.id, null);
        String stale = prefs.getString(KEY_STALE_ADDR_PREFIX + activeEntry.id, null);
        String storedAddr = activeEntry.address;
        if (storedAddr != null && !storedAddr.isEmpty()
                && (stale == null || !stale.equalsIgnoreCase(storedAddr))) {
            addressHint = storedAddr;
        }
        Log.i(TAG, "目标 Mac=" + activeEntry.displayName()
                + " addrHint=" + (addressHint == null ? "-" : addressHint)
                + " devName=" + (expectedDeviceName == null ? "-" : expectedDeviceName));
    }

    /** 供界面查询当前选中的备注名 */
    public String getActiveMacName() {
        return activeEntry == null ? null : activeEntry.displayName();
    }

    private boolean hasKey() {
        if (key == null) reloadActiveMac();
        return key != null;
    }

    private void setWantConnection(boolean want) {
        wantConnection = want;
        if (prefs != null) {
            prefs.edit().putBoolean(KEY_WANT_CONNECTION, want).apply();
        }
    }

    /** 缓存地址被证明不可达/身份不符：本服务不再把它当扫描提示，并排除该地址 */
    private void markAddressStale(String addr) {
        if (activeEntry == null || addr == null || addr.isEmpty()) return;
        if (prefs != null) {
            prefs.edit().putString(KEY_STALE_ADDR_PREFIX + activeEntry.id, addr).apply();
        }
        if (addressHint != null && addressHint.equalsIgnoreCase(addr)) {
            addressHint = null;
        }
        excludedAddresses.add(addr);
        Log.i(TAG, "缓存地址已失效，后续仅按广播名/服务 UUID 扫描: " + addr);
    }

    /**
     * 普通建链失败：清除缓存地址提示，但**不**把本次尝试的地址永久排除。
     * 唯一可达的 Mac 如果被排除，后续扫描即便看到也不会连，等于自锁死；
     * 只有「身份不符」才用 markAddressStale 排除。
     */
    private void clearAddressHint(String attempted) {
        if (activeEntry == null) return;
        String hint = addressHint;
        // 只清本轮的内存提示，不在 prefs 里落“永久失效”标记：冷启动后仍允许重试该地址。
        addressHint = null;
        transientAddress = (attempted != null && !attempted.isEmpty()) ? attempted
                : (hint != null && !hint.isEmpty() ? hint : null);
        // 不能把 attempted 从 excludedAddresses 里移除：身份不符时 markAddressStale()
        // 刚加入的正是该地址，移除会让排除集形同虚设，下一轮又把错误 Mac 当地址命中建链。
        Log.i(TAG, "清除缓存地址提示（仅本轮）: hint=" + (hint == null ? "-" : hint)
                + " attempted=" + (attempted == null ? "-" : attempted));
    }

    /** 连接成功：记住地址与广播名（多 Mac 交叉校验的依据） */
    private void rememberSuccessfulIdentity(String addr, String name) {
        if (activeEntry == null) return;
        if (addr != null && !addr.isEmpty()) {
            try {
                store.rememberAddress(activeEntry.id, addr);
            } catch (Exception e) {
                Log.w(TAG, "保存地址失败", e);
            }
            addressHint = addr;
            transientAddress = null;
        }
        SharedPreferences.Editor editor = prefs.edit();
        if (name != null && !name.isEmpty()) {
            expectedDeviceName = name;
            editor.putString(KEY_DEVICE_NAME_PREFIX + activeEntry.id, name);
        }
        editor.remove(KEY_STALE_ADDR_PREFIX + activeEntry.id);
        editor.apply();
    }

    // ---------------------------------------------------------------- 扫描

    private final ScanCallback scanCallback = new ScanCallback() {
        @Override
        public void onScanResult(int callbackType, ScanResult result) {
            noteRawScanResult(result);
            handleScanResult(result);
        }

        @Override
        public void onBatchScanResults(List<ScanResult> results) {
            if (results == null) return;
            for (ScanResult r : results) {
                noteRawScanResult(r);
                handleScanResult(r);
            }
        }

        @Override
        public void onScanFailed(int errorCode) {
            Log.w(TAG, "扫描失败 code=" + errorCode);
            if (errorCode == ScanCallback.SCAN_FAILED_ALREADY_STARTED) {
                // 系统认为扫描已在运行：保持 scanning=true，继续等结果
                return;
            }
            scanning = false;
            cancelScanTimeout();
            cancelChoose();
            cancelScanFallback();
            scanFailStreak++;
            if (scanFailStreak >= 3) {
                scanFailStreak = 0;
                publish(STATE_ERROR, getString(R.string.s53) + errorCode);
            }
            scheduleRetry(SCAN_FAILURE_RETRY_MS);
        }
    };

    private void handleScanResult(ScanResult result) {
        if (!scanning || result == null || gatt != null) return;
        BluetoothDevice device = result.getDevice();
        if (device == null) return;

        String addr = device.getAddress();
        String name = resultName(result);
        boolean hasService = hasTargetService(result);
        boolean namePrefix = name.startsWith(nameHint);
        // 133 等瞬态失败后地址提示会被清除，但重试时 transientAddress 仍是本轮唯一线索；
        // 这里允许它继续参与候选匹配（只影响候选发现，连接后仍由 INFO 特征校验身份）。
        String hintAddr = addressHint;
        if (hintAddr == null && attempt >= 1 && transientAddress != null
                && !excludedAddresses.contains(transientAddress)) {
            hintAddr = transientAddress;
        }
        boolean addressMatch = hintAddr != null && hintAddr.equalsIgnoreCase(addr);

        // 服务 UUID / 兜底名字前缀 / 缓存地址提示，三者其一即可进入候选；
        // 地址命中还会在连接后用 INFO 特征做身份交叉校验，不会仅凭地址判定身份。
        if (!hasService && !namePrefix && !addressMatch) return;

        boolean excluded = excludedAddresses.contains(addr);
        boolean nameExact = expectedDeviceName != null && namesEqual(expectedDeviceName, name);
        boolean nameTruncated = expectedDeviceName != null
                && !nameExact && nameMatchesTruncatedAdv(expectedDeviceName, name);
        boolean entryFuzzy = activeEntry != null && fuzzyNameMatch(activeEntry.displayName(), name);

        int score = (nameExact ? 1000 : 0) + (nameTruncated ? 400 : 0)
                + (addressMatch ? 600 : 0) + (entryFuzzy ? 100 : 0)
                + (hasService ? 30 : 0) + Math.max(-40, result.getRssi() / 3);
        String reason = nameExact ? "name" : nameTruncated ? "name-truncated"
                : addressMatch ? "address" : entryFuzzy ? "entry-name" : "service";

        Log.i(TAG, "扫描候选 " + (name.isEmpty() ? "(无名)" : name) + " " + addr
                + " rssi=" + result.getRssi() + " service=" + hasService
                + " addrHint=" + addressMatch + " name=" + nameExact
                + " truncated=" + nameTruncated + " score=" + score
                + (excluded ? " excluded=true" : ""));

        if (excluded) return;

        boolean eligible;
        if (expectedDeviceName != null) {
            eligible = nameExact || nameTruncated || addressMatch;
        } else {
            eligible = addressMatch || hasService || namePrefix;
        }
        if (!eligible) {
            Log.i(TAG, "候选不在本轮身份范围内，忽略: " + addr);
            return;
        }

        if (score > bestScore) {
            bestCandidate = result;
            bestScore = score;
            bestReason = reason;
        }

        // 决定性命中：历史广播名精确匹配，或缓存地址提示命中。
        // 地址只是提示：连接后还会读 INFO 特征交叉校验 deviceName，不一致会断开重扫，
        // 所以这里可以立即建链，省掉收集窗口的等待（冷启动的关键路径）。
        boolean decisive = nameExact || addressMatch;
        if (decisive) {
            selectCandidate("strong-" + reason);
            return;
        }

        // 其余候选先收集一小段时间，避免「谁先到就选谁」
        if (firstCandidateAt == 0L) {
            firstCandidateAt = SystemClock.elapsedRealtime();
            cancelChoose();
            chooseRunnable = () -> {
                chooseRunnable = null;
                Log.i(TAG, "[lat] collect_window_fire scanning=" + scanning
                        + " best=" + (bestCandidate == null ? "-" : bestCandidate.getDevice().getAddress()));
                if (scanning) selectCandidate("collect-window");
            };
            handler.postDelayed(chooseRunnable, SCAN_AMBIGUOUS_WINDOW_MS);
            Log.i(TAG, "[lat] collect_window_start after_first_candidate="
                    + SCAN_AMBIGUOUS_WINDOW_MS + "ms best=" + addr);
        }
    }

    private void startScan(String reason) {
        if (adapter == null || !adapter.isEnabled()) {
            publish(STATE_ERROR, getString(R.string.s81));
            scheduleRetry(COOLDOWN_RETRY_MS);
            return;
        }
        if (scanning) return;
        if (gatt != null) return; // 已有连接，无需扫描
        if ("connect-wait".equals(stage)) return; // stopScan→connectGatt 的 80ms 空档，别重复开扫

        if (activeEntry == null) {
            publish(STATE_ERROR, getString(R.string.s40));
            // 没有可连接的 Mac（用户已删光条目）：必须停掉前台服务并清「保持连接」，
            // 否则服务会带着已删除的条目一直空转扫描，并在每次开机时被 BootReceiver 拉起。
            setWantConnection(false);
            stopForeground(true);
            stopSelf();
            return;
        }

        scanner = adapter.getBluetoothLeScanner();
        if (scanner == null) {
            publish(STATE_ERROR, getString(R.string.s61));
            scheduleRetry(SCAN_FAILURE_RETRY_MS);
            return;
        }

        cancelScanTimeout();
        cancelChoose();
        cancelRetry();
        cancelScanFallback();
        bestCandidate = null;
        bestScore = Integer.MIN_VALUE;
        bestReason = "";
        firstCandidateAt = 0L;
        rawScanCount = 0;
        String hint = addressHint;
        if (hint == null && transientAddress != null && attempt >= 1
                && !excludedAddresses.contains(transientAddress)) {
            // 上一轮失败已清除提示；重试时允许再次作为“过滤提示”（不是盲连，更不是身份）。
            hint = transientAddress;
            Log.i(TAG, "[lat] hint_rearm attempt=" + attempt + " addr=" + hint
                    + "（仅扫描过滤提示，连接后仍由 INFO 校验身份）");
        }
        // 始终 filtered 优先：本机实测只有带 service UUID filter 的扫描能看到该 Mac 的广播。
        // 旧版本曾把「filtered 800ms 无结果」持久化成 filtered_scan_broken，导致之后的
        // 所有扫描都走看不到目标的 unfiltered 路径（自锁死）；这里清掉旧标记并恢复 filtered。
        if (RESET_FILTERED_SCAN_BROKEN_ON_START
                && prefs.getBoolean(KEY_FILTERED_SCAN_BROKEN, false)) {
            prefs.edit().remove(KEY_FILTERED_SCAN_BROKEN).apply();
            Log.i(TAG, "清除历史 filtered_scan_broken 标记，恢复 filtered 优先扫描");
        }
        final boolean filteredUsable = true;
        final String hintFinal = hint;
        scanPass = "filtered";
        t0 = SystemClock.elapsedRealtime();
        scanning = true;

        long rateDelay = scanRateDelay(t0);
        Log.i(TAG, "[lat] scan_start reason=" + reason
                + " elapsed=0ms addrHint=" + (hint == null ? "-" : hint)
                + " devName=" + (expectedDeviceName == null ? "-" : expectedDeviceName)
                + " path=" + scanPass
                + (rateDelay > 0 ? " rateDelay=" + rateDelay + "ms" : ""));
        publish(STATE_SCANNING, getString(R.string.s66) + activeEntry.displayName() + "…");

        if (rateDelay > 0L) {
            Log.w(TAG, "[lat] scan_rate_limited wait=" + rateDelay + "ms"
                    + "（系统限制扫描启动频率，避免 App is scanning too frequently）");
            final int rateGen = generation;
            scanRateRunnable = () -> {
                scanRateRunnable = null;
                if (rateGen == generation && scanning) {
                    launchScanPass(filteredUsable, hintFinal);
                }
            };
            handler.postDelayed(scanRateRunnable, rateDelay);
        } else {
            launchScanPass(filteredUsable, hintFinal);
        }

        scanTimeoutRunnable = () -> {
            scanTimeoutRunnable = null;
            if (!scanning) return;
            if (bestCandidate != null) {
                selectCandidate("scan-window-end");
                return;
            }
            Log.w(TAG, "[lat] scan_timeout elapsed=" + elapsedSince(t0) + "ms"
                    + " raw=" + rawScanCount + " pass=" + scanPass);
            stopScan();
            if (expectedDeviceName != null) {
                nameMissStreak++;
                Log.w(TAG, "历史广播名连续 " + nameMissStreak + " 轮未命中；"
                        + "不做身份放宽，继续按地址提示/INFO 校验重试，避免连到别的 Mac");
            }
            failAttempt("扫描超时未发现目标 Mac", false);
        };
        handler.postDelayed(scanTimeoutRunnable, rateDelay + SCAN_WINDOW_MS);
    }

    /**
     * 计算下一次扫描启动还需要等多久：30s 窗口内最多 MAX_SCAN_STARTS_PER_WINDOW 次，
     * 且两次启动至少间隔 MIN_SCAN_START_GAP_MS。正常「扫描 8s→失败→重试」不会被延迟，
     * 只有极短时间内的连续失败重试才会被动限速。
     */
    private long scanRateDelay(long now) {
        while (!scanStartTimes.isEmpty() && now - scanStartTimes.peekFirst() > SCAN_START_WINDOW_MS) {
            scanStartTimes.pollFirst();
        }
        long delay = 0L;
        if (scanStartTimes.size() >= MAX_SCAN_STARTS_PER_WINDOW) {
            delay = SCAN_START_WINDOW_MS - (now - scanStartTimes.peekFirst()) + 50L;
        }
        if (lastScanStartAt > 0L) {
            long sinceLast = now - lastScanStartAt;
            if (sinceLast >= 0 && sinceLast < MIN_SCAN_START_GAP_MS) {
                delay = Math.max(delay, MIN_SCAN_START_GAP_MS - sinceLast);
            }
        }
        return delay;
    }

    /** 按当前策略真正启动一次扫描：filtered 优先（本机唯一可见目标路径） */
    private void launchScanPass(boolean filteredUsable, String hint) {
        if (!scanning) return;
        lastScanStartAt = SystemClock.elapsedRealtime();
        scanStartTimes.addLast(lastScanStartAt);
        if (filteredUsable) {
            // filtered 优先；若 800ms 内一条原始结果都没有，再在同一 8s 窗口内回退一次
            // unfiltered（有界：计入 30s 启动配额，配额不足就放弃回退）。
            boolean started = startPlatformScan(buildScanFilters(hint), "filtered");
            if (started && scanning) scheduleScanFallback();
        } else {
            startPlatformScan(null, "unfiltered");
        }
    }

    /**
     * filtered 扫描 800ms 内没有任何原始结果时才回退到 unfiltered（同一 8s 窗口内，不额外延长）。
     * 每次扫描窗口最多额外多启动一次，并且计入 30s 启动配额；配额不足就放弃回退，
     * 让本轮 filtered 正常跑满 8s，避免 "App is scanning too frequently"。
     */
    private void scheduleScanFallback() {
        cancelScanFallback();
        scanFallbackRunnable = () -> {
            scanFallbackRunnable = null;
            if (!scanning || bestCandidate != null || rawScanCount != 0
                    || !"filtered".equals(scanPass)) {
                return;
            }
            long now = SystemClock.elapsedRealtime();
            long sinceStart = lastScanStartAt > 0 ? now - lastScanStartAt : SCAN_FALLBACK_AFTER_MS;
            if (scanStartsInWindow(now) >= MAX_SCAN_STARTS_PER_WINDOW) {
                Log.w(TAG, "[lat] scan_fallback_skip quota raw=0 elapsed=" + sinceStart
                        + "ms starts=" + scanStartsInWindow(now) + "/" + MAX_SCAN_STARTS_PER_WINDOW
                        + " pass=filtered");
                return;
            }
            Log.i(TAG, "[lat] scan_fallback raw=0 elapsed=" + sinceStart
                    + "ms action=stop_filtered_start_unfiltered");
            try {
                if (scanner != null) scanner.stopScan(scanCallback);
            } catch (SecurityException ignored) {
            }
            lastScanStartAt = now;
            scanStartTimes.addLast(now);
            startPlatformScan(null, "unfiltered");
        };
        handler.postDelayed(scanFallbackRunnable, SCAN_FALLBACK_AFTER_MS);
    }

    /** 30s 窗口内已启动的扫描次数（顺带清掉窗口外的历史） */
    private int scanStartsInWindow(long now) {
        while (!scanStartTimes.isEmpty() && now - scanStartTimes.peekFirst() > SCAN_START_WINDOW_MS) {
            scanStartTimes.pollFirst();
        }
        return scanStartTimes.size();
    }

    private void cancelScanFallback() {
        if (scanFallbackRunnable != null) {
            handler.removeCallbacks(scanFallbackRunnable);
            scanFallbackRunnable = null;
        }
    }

    /**
     * 启动一次平台扫描。返回 false 表示已经判失败（publish/retry 已处理），调用方直接返回。
     * filters=null 表示无过滤扫描。
     */
    private boolean startPlatformScan(List<ScanFilter> filters, String pass) {
        scanPass = pass;
        ScanSettings settings = new ScanSettings.Builder()
                .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                .setMatchMode(ScanSettings.MATCH_MODE_AGGRESSIVE)
                // 注意：本机实测 setLegacy(false) 会导致完全收不到结果（Xiaomi/HyperOS），
                // 因此保持默认 legacy 扫描；若广播走 extended advertising，需要额外验证
                .setReportDelay(0)
                .build();
        try {
            scanner.startScan(filters, settings, scanCallback);
            return true;
        } catch (SecurityException e) {
            Log.w(TAG, "扫描权限不足", e);
            scanning = false;
            publish(STATE_ERROR, getString(R.string.s79));
            scheduleRetry(SCAN_FAILURE_RETRY_MS);
            return false;
        } catch (IllegalArgumentException e) {
            // 极少数机型不接受某些 filter：退回无过滤扫描，由回调自行匹配
            Log.w(TAG, "扫描过滤器被拒绝，改用无过滤扫描", e);
            try {
                scanPass = "unfiltered";
                scanner.startScan(null, settings, scanCallback);
                return true;
            } catch (Exception e2) {
                Log.w(TAG, "无过滤扫描也启动失败", e2);
                scanning = false;
                publish(STATE_ERROR, getString(R.string.s53) + e2.getMessage());
                scheduleRetry(SCAN_FAILURE_RETRY_MS);
                return false;
            }
        }
    }

    /**
     * filtered 扫描 800ms 内一条原始结果都没有 → 停掉 filtered、改无过滤扫描。
     * 真机复现过：128-bit UUID filter 在部分机型上被 offload 后静默 0 结果，
     * 而系统未过滤扫描同一时间能看到大量设备。
     */
    private void noteRawScanResult(ScanResult result) {
        if (!scanning || result == null) return;
        rawScanCount++;
        BluetoothDevice d = result.getDevice();
        String addr = d == null ? "-" : d.getAddress();
        ScanRecord record = result.getScanRecord();
        List<ParcelUuid> uuids = record != null ? record.getServiceUuids() : null;
        boolean hasUuids = uuids != null && !uuids.isEmpty();
        boolean targetAddr = addressHint != null && addressHint.equalsIgnoreCase(addr);
        if (hasUuids || targetAddr || rawScanCount <= 5 || rawScanCount % 25 == 0) {
            Log.i(TAG, "[lat] raw_scan pass=" + scanPass + " count=" + rawScanCount
                    + " addr=" + addr + " name=" + resultName(result)
                    + " rssi=" + result.getRssi() + " uuids=" + (uuids == null ? 0 : uuids.size())
                    + (hasUuids ? " " + uuids : "") + (targetAddr ? " targetAddr=true" : ""));
        }
    }

    /** UUID-only 过滤器 +（可选）带地址提示的过滤器；多个 filter 之间是「或」 */
    private List<ScanFilter> buildScanFilters(String hint) {
        List<ScanFilter> filters = new ArrayList<>();
        // 主路径：按协议服务 UUID 过滤（Mac 守护进程正常广播时命中）
        filters.add(new ScanFilter.Builder()
                .setServiceUuid(new ParcelUuid(Protocol.SERVICE_UUID)).build());
        // 提示路径：缓存地址只作为扫描过滤提示（不是身份）。部分 Mac 上守护进程的
        // B1E0A100 广播可能没有真正上 air，但同一控制器的系统广告（Continuity）仍在，
        // 该地址仍是可达的 GATT 端点；连接后会用 INFO 特征交叉校验 deviceName。
        if (hint != null && !hint.isEmpty()) {
            try {
                filters.add(new ScanFilter.Builder()
                        .setDeviceAddress(hint)
                        .build());
                Log.i(TAG, "[lat] scan_filter hint_addr=" + hint);
            } catch (IllegalArgumentException e) {
                Log.w(TAG, "地址提示不合法，忽略: " + hint);
            }
        }
        return filters;
    }

    private void selectCandidate(String reason) {
        if (!scanning || bestCandidate == null) {
            Log.i(TAG, "[lat] select_skipped reason=" + reason + " scanning=" + scanning
                    + " best=" + (bestCandidate == null ? "-" : "set"));
            return;
        }
        ScanResult result = bestCandidate;
        BluetoothDevice device = result.getDevice();
        if (device == null) return;

        stopScan(); // 同时取消扫描/收集窗口定时器
        final String addr = device.getAddress();
        final String name = resultName(result);
        attemptedAddress = addr;
        attemptedName = name;

        Log.i(TAG, "发现目标设备 " + name + " " + addr);
        Log.i(TAG, "[lat] found reason=" + reason + " score=" + bestScore
                + " elapsed=" + elapsedSince(t0) + "ms rssi=" + result.getRssi());
        if (expectedDeviceName != null && !namesEqual(expectedDeviceName, name)) {
            Log.i(TAG, "候选广播名与历史记录不完全一致（可能被 adv 截断），"
                    + "连接后将读取 INFO 特征确认身份");
        }

        publish(STATE_CONNECTING, getString(R.string.s67)
                + activeEntry.displayName() + "…");

        final int gen = ++generation;
        stage = "connect-wait";
        handler.postDelayed(() -> {
            if (gen != generation) return;
            // 80ms 空档里可能又有人发 ACTION_START 重新开扫：建链前再停一次，避免扫描与连接并存。
            stopScan();
            connectGatt(device);
        }, GATT_SETTLE_MS);
    }

    private void stopScan() {
        cancelScanTimeout();
        cancelChoose();
        cancelScanFallback();
        cancelScanRate();
        if (!scanning) return;
        scanning = false;
        try {
            if (scanner != null) scanner.stopScan(scanCallback);
        } catch (SecurityException ignored) {
        }
    }

    // ---------------------------------------------------------------- 连接与 GATT

    private final BluetoothGattCallback gattCallback = new BluetoothGattCallback() {
        @Override
        public void onConnectionStateChange(BluetoothGatt g, int status, int newState) {
            if (g != gatt) {
                Log.w(TAG, "忽略过期 GATT 连接回调 g=" + g + " status=" + status);
                return;
            }
            if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                connecting = true;
                long dt = elapsedSince(connectStartedAt);
                boolean fast = dt < 250;
                Log.i(TAG, "已连接，开始发现服务 (elapsed=" + dt + "ms, "
                        + (fast ? "疑似复用旧链路，等待 CCCD 确认 new-link" : "new-link") + ")");
                Log.i(TAG, "[lat] connected elapsed=" + elapsedSince(t0)
                        + "ms since_connect=" + dt + "ms kind=" + (fast ? "reused?" : "new"));
                publish(STATE_CONNECTING, getString(R.string.s48));

                // 尽早请求高优先级（连接间隔 7.5–15ms），明显缩短服务发现/CCCD 往返耗时；
                // MTU 协商之后还会再请求一次（合同要求），重复请求是幂等的。
                try {
                    boolean early = g.requestConnectionPriority(
                            BluetoothGatt.CONNECTION_PRIORITY_HIGH);
                    Log.i(TAG, "[lat] connection_priority(HIGH) early queued=" + early);
                } catch (SecurityException e) {
                    Log.w(TAG, "提前请求连接优先级失败", e);
                }

                final int gen = generation;
                // 建链成功后再给握手阶段一个更宽的窗口：服务发现/MTU/INFO/CCCD/STATUS
                // 依次串行，慢设备合法耗时可能超过 7s；仍用 7s 看门狗会把正常连接打断重连。
                cancelWatchdog();
                connectWatchdogRunnable = () -> {
                    connectWatchdogRunnable = null;
                    if (gen == generation && gatt == g && !ready) {
                        Log.w(TAG, "[lat] handshake_watchdog timeout stage=" + stage
                                + " since_connect=" + elapsedSince(connectStartedAt) + "ms");
                        failAttempt("握手看门狗超时(15s)", true);
                    }
                };
                handler.postDelayed(connectWatchdogRunnable, HANDSHAKE_WATCHDOG_MS);
                handler.postDelayed(() -> {
                    if (gen != generation || gatt != g) return;
                    stage = "discovering";
                    Log.i(TAG, "[lat] discover_services elapsed=" + elapsedSince(connectStartedAt) + "ms");
                    cancelStageTimeout();
                    stageTimeoutRunnable = () -> {
                        stageTimeoutRunnable = null;
                        if (gen == generation && "discovering".equals(stage)) {
                            failAttempt("服务发现超时(3s)", true);
                        }
                    };
                    handler.postDelayed(stageTimeoutRunnable, DISCOVERY_TIMEOUT_MS);
                    try {
                        if (!g.discoverServices()) {
                            failAttempt("discoverServices 返回 false", true);
                        }
                    } catch (SecurityException e) {
                        failAttempt("缺少蓝牙连接权限", false);
                    }
                }, GATT_SETTLE_MS);
                return;
            }

            if (newState == BluetoothProfile.STATE_DISCONNECTED
                    || status != BluetoothGatt.GATT_SUCCESS) {
                Log.i(TAG, "连接断开 status=" + status + " state=" + newState);
                boolean stale = isEstablishFailure(status);
                failAttempt("连接断开 status=" + status, stale);
            }
        }

        @Override
        public void onServicesDiscovered(BluetoothGatt g, int status) {
            if (g != gatt) return;
            cancelStageTimeout();
            if (status != BluetoothGatt.GATT_SUCCESS) {
                failAttempt("服务发现失败 status=" + status, true);
                return;
            }
            BluetoothGattService service = g.getService(Protocol.SERVICE_UUID);
            if (service == null) {
                failAttempt("未找到目标服务", false);
                return;
            }
            commandChar = service.getCharacteristic(Protocol.CHAR_COMMAND_UUID);
            statusChar = service.getCharacteristic(Protocol.CHAR_STATUS_UUID);
            infoChar = service.getCharacteristic(Protocol.CHAR_INFO_UUID);
            if (commandChar == null || statusChar == null) {
                failAttempt("未找到指令/状态特征", false);
                return;
            }
            Log.i(TAG, "[lat] services_ok elapsed=" + elapsedSince(connectStartedAt)
                    + "ms infoChar=" + (infoChar != null));
            mtuDone = false;
            mtuRetried = false;
            cccdRetried = false;
            statusReadRetried = false;
            requestMtu(g);
        }

        @Override
        public void onMtuChanged(BluetoothGatt g, int mtu, int status) {
            if (g != gatt) return;
            mtuDone = true;
            cancelStageTimeout();
            Log.i(TAG, "[lat] mtu_changed mtu=" + mtu + " status=" + status
                    + " elapsed=" + elapsedSince(connectStartedAt) + "ms");
            if (status == BluetoothGatt.GATT_SUCCESS) {
                proceedAfterMtu(g);
            } else if (!mtuRetried) {
                mtuRetried = true;
                Log.w(TAG, "MTU 协商失败 status=" + status + "，重试一次");
                requestMtu(g);
            } else {
                Log.w(TAG, "MTU 协商仍失败，按默认 MTU 继续");
                proceedAfterMtu(g);
            }
        }

        @Override
        public void onCharacteristicRead(BluetoothGatt g, BluetoothGattCharacteristic c, int status) {
            if (g != gatt) return;
            byte[] value = c.getValue();
            if (Protocol.CHAR_INFO_UUID.equals(c.getUuid())) {
                handleInfoRead(status, value);
                return;
            }
            if (!Protocol.CHAR_STATUS_UUID.equals(c.getUuid())) return;

            cancelStageTimeout();
            if (status != BluetoothGatt.GATT_SUCCESS || value == null || value.length == 0) {
                if (!statusReadRetried) {
                    statusReadRetried = true;
                    Log.w(TAG, "[lat] status_read_failed status=" + status + "，重试一次");
                    final int gen = generation;
                    handler.postDelayed(() -> {
                        if (gen == generation && gatt == g) readStatus(g);
                    }, 150);
                } else {
                    failAttempt("状态读取失败 status=" + status, true);
                }
                return;
            }
            onReady(new String(value, StandardCharsets.UTF_8));
        }

        @Override
        public void onDescriptorWrite(BluetoothGatt g, BluetoothGattDescriptor descriptor, int status) {
            if (g != gatt || descriptor == null) return;
            if (!CCCD_DESCRIPTOR_UUID.equals(descriptor.getUuid())) return;
            cancelStageTimeout();
            if (status != BluetoothGatt.GATT_SUCCESS) {
                if (!cccdRetried) {
                    cccdRetried = true;
                    Log.w(TAG, "[lat] cccd_write_failed status=" + status + "，重试一次");
                    writeCccd(g);
                } else {
                    failAttempt("CCCD 写入失败 status=" + status, true);
                }
                return;
            }
            Log.i(TAG, "[lat] cccd_ok new-link 订阅确认 elapsed="
                    + elapsedSince(connectStartedAt) + "ms");
            readStatus(g);
        }

        @Override
        public void onCharacteristicChanged(BluetoothGatt g, BluetoothGattCharacteristic c) {
            if (g != gatt) return;
            if (Protocol.CHAR_STATUS_UUID.equals(c.getUuid()) && c.getValue() != null) {
                onStatusPayload(new String(c.getValue(), StandardCharsets.UTF_8));
            }
        }

        @Override
        public void onCharacteristicWrite(BluetoothGatt g, BluetoothGattCharacteristic c, int status) {
            if (g != gatt) return;
            if (status == BluetoothGatt.GATT_SUCCESS) {
                publish(STATE_SENT, getString(R.string.s56));
            } else {
                publish(STATE_ERROR, getString(R.string.s21) + status);
            }
        }
    };

    private void connectGatt(BluetoothDevice device) {
        if (!wantConnection || gatt != null || device == null) return;
        if (activeEntry == null) return;

        closeGatt(); // 保证 generation 递增，旧回调失效
        final int gen = generation;
        connectStartedAt = SystemClock.elapsedRealtime();
        stage = "connecting";
        connecting = true;
        ready = false;
        commandChar = null;
        statusChar = null;
        infoChar = null;

        publish(STATE_CONNECTING, getString(R.string.s67)
                + activeEntry.displayName() + "…");
        Log.i(TAG, "[lat] connect_gatt elapsed=" + elapsedSince(t0)
                + "ms addr=" + device.getAddress() + " attempt=" + (attempt + 1));

        try {
            gatt = device.connectGatt(this, false, gattCallback, BluetoothDevice.TRANSPORT_LE);
        } catch (SecurityException e) {
            publish(STATE_ERROR, getString(R.string.s80));
            gatt = null;
            scheduleRetry(SCAN_FAILURE_RETRY_MS);
            return;
        }
        if (gatt == null) {
            failAttempt("connectGatt 返回 null", true);
            return;
        }

        cancelWatchdog();
        connectWatchdogRunnable = () -> {
            connectWatchdogRunnable = null;
            if (gen == generation && gatt != null && !ready) {
                Log.w(TAG, "[lat] connect_watchdog timeout stage=" + stage);
                failAttempt("建链看门狗超时(7s)", true);
            }
        };
        handler.postDelayed(connectWatchdogRunnable, CONNECT_WATCHDOG_MS);
    }

    // ---- GATT 时序：discover → MTU(517) → priority(HIGH) → INFO 身份校验 → CCCD → STATUS

    private void requestMtu(BluetoothGatt g) {
        if (gatt != g) return;
        stage = "mtu";
        cancelStageTimeout();
        final int gen = generation;
        boolean queued;
        try {
            queued = g.requestMtu(MTU_REQUEST);
        } catch (SecurityException e) {
            queued = false;
        }
        Log.i(TAG, "[lat] request_mtu(517) queued=" + queued
                + " elapsed=" + elapsedSince(connectStartedAt) + "ms");

        if (!queued) {
            if (!mtuRetried) {
                mtuRetried = true;
                Log.w(TAG, "requestMtu 被拒绝，重试一次");
                handler.postDelayed(() -> {
                    if (gen == generation) requestMtu(g);
                }, 150);
                return;
            }
            Log.w(TAG, "requestMtu 两次被拒绝，按默认 MTU 继续");
            proceedAfterMtu(g);
            return;
        }

        stageTimeoutRunnable = () -> {
            stageTimeoutRunnable = null;
            if (gen != generation || gatt != g || mtuDone) return;
            if (!mtuRetried) {
                mtuRetried = true;
                Log.w(TAG, "[lat] mtu_timeout 800ms，重试一次");
                requestMtu(g);
            } else {
                // Android 14+ 首次 MTU 可能直接生效但不回调 onMtuChanged
                Log.w(TAG, "[lat] mtu_timeout 800ms，按默认 MTU 继续");
                mtuDone = true;
                proceedAfterMtu(g);
            }
        };
        handler.postDelayed(stageTimeoutRunnable, MTU_TIMEOUT_MS);
    }

    private void proceedAfterMtu(BluetoothGatt g) {
        if (gatt != g || !"mtu".equals(stage)) return;
        cancelStageTimeout();
        stage = "identity";
        try {
            boolean ok = g.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH);
            Log.i(TAG, "[lat] connection_priority(HIGH) queued=" + ok);
        } catch (SecurityException e) {
            Log.w(TAG, "无法设置连接优先级", e);
        }

        // 读 INFO 特征（"BLEUnlockCmd v1;<deviceName>"）做最终身份确认
        if (infoChar == null) {
            proceedToCccd(g);
            return;
        }
        final int gen = generation;
        stage = "info";
        boolean queued;
        try {
            queued = g.readCharacteristic(infoChar);
        } catch (SecurityException e) {
            queued = false;
        }
        Log.i(TAG, "[lat] info_read queued=" + queued);
        if (!queued) {
            proceedToCccd(g);
            return;
        }
        stageTimeoutRunnable = () -> {
            stageTimeoutRunnable = null;
            if (gen != generation || gatt != g || !"info".equals(stage)) return;
            Log.w(TAG, "[lat] info_timeout 800ms，跳过身份校验继续");
            proceedToCccd(g);
        };
        handler.postDelayed(stageTimeoutRunnable, INFO_TIMEOUT_MS);
    }

    private void handleInfoRead(int status, byte[] value) {
        cancelStageTimeout();
        if (!"info".equals(stage)) return;
        String raw = value == null ? "" : new String(value, StandardCharsets.UTF_8).trim();
        String devName = raw.startsWith("BLEUnlockCmd v1;")
                ? raw.substring("BLEUnlockCmd v1;".length()).trim() : raw;
        Log.i(TAG, "[lat] info_name status=" + status + " name=" + devName);

        if (status == BluetoothGatt.GATT_SUCCESS && !devName.isEmpty()) {
            attemptedName = devName;
            if (expectedDeviceName == null) {
                expectedDeviceName = devName;
                prefs.edit().putString(KEY_DEVICE_NAME_PREFIX + activeEntry.id, devName).apply();
                Log.i(TAG, "首次连接，记住该 Mac 的广播名: " + devName);
            } else if (!namesEqual(expectedDeviceName, devName)) {
                if (nameMatchesTruncatedAdv(devName, expectedDeviceName)
                        || nameMatchesTruncatedAdv(expectedDeviceName, devName)) {
                    // 之前记到的是被 adv 截断的名字，用 INFO 里的全名校正
                    expectedDeviceName = devName;
                    prefs.edit().putString(KEY_DEVICE_NAME_PREFIX + activeEntry.id, devName).apply();
                    Log.i(TAG, "用 INFO 特征校正广播名: " + devName);
                } else {
                    Log.w(TAG, "身份校验失败: 期望=" + expectedDeviceName + " 实际=" + devName);
                    markAddressStale(attemptedAddress);
                    failAttempt("设备身份不符（期望 " + expectedDeviceName + "）", true);
                    return;
                }
            }
        }
        if (gatt != null) proceedToCccd(gatt);
    }

    private void proceedToCccd(BluetoothGatt g) {
        if (gatt != g || !wantConnection) return;
        stage = "cccd";
        cancelStageTimeout();
        if (statusChar == null) {
            failAttempt("缺少状态特征", false);
            return;
        }
        if (!writeCccd(g)) return;

        final int gen = generation;
        stageTimeoutRunnable = () -> {
            stageTimeoutRunnable = null;
            if (gen != generation || gatt != g || !"cccd".equals(stage)) return;
            if (!cccdRetried) {
                cccdRetried = true;
                Log.w(TAG, "[lat] cccd_timeout 1500ms，重试一次");
                writeCccd(g);
            } else {
                failAttempt("CCCD 写入超时(1.5s)", true);
            }
        };
        handler.postDelayed(stageTimeoutRunnable, CCCD_TIMEOUT_MS);
    }

    private boolean writeCccd(BluetoothGatt g) {
        try {
            g.setCharacteristicNotification(statusChar, true);
            BluetoothGattDescriptor descriptor = statusChar.getDescriptor(CCCD_DESCRIPTOR_UUID);
            if (descriptor == null) {
                failAttempt("缺少 CCCD 描述符", false);
                return false;
            }
            boolean queued;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                // API 33+ 的 writeDescriptor(descriptor, value) 返回 int 状态码
                // （BluetoothStatusCodes.SUCCESS == 0），不引用新类以兼容 minSdk 26。
                int rc = g.writeDescriptor(descriptor,
                        BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE);
                queued = (rc == 0);
            } else {
                descriptor.setValue(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE);
                queued = g.writeDescriptor(descriptor);
            }
            Log.i(TAG, "[lat] cccd_write queued=" + queued
                    + " elapsed=" + elapsedSince(connectStartedAt) + "ms"
                    + (cccdRetried ? " (retry)" : ""));
            if (!queued) {
                if (!cccdRetried) {
                    cccdRetried = true;
                    Log.w(TAG, "CCCD 写请求被拒绝，重试一次");
                    final int gen = generation;
                    handler.postDelayed(() -> {
                        if (gen == generation) writeCccd(g);
                    }, 150);
                } else {
                    failAttempt("CCCD 写入请求被拒绝", true);
                }
                return false;
            }
            return true;
        } catch (SecurityException e) {
            failAttempt("缺少蓝牙连接权限", false);
            return false;
        }
    }

    private void readStatus(BluetoothGatt g) {
        if (gatt != g || statusChar == null) return;
        stage = "status";
        cancelStageTimeout();
        final int gen = generation;
        boolean queued;
        try {
            queued = g.readCharacteristic(statusChar);
        } catch (SecurityException e) {
            queued = false;
        }
        Log.i(TAG, "[lat] status_read queued=" + queued
                + " elapsed=" + elapsedSince(connectStartedAt) + "ms");
        if (!queued) {
            if (!statusReadRetried) {
                statusReadRetried = true;
                handler.postDelayed(() -> {
                    if (gen == generation) readStatus(g);
                }, 150);
            } else {
                failAttempt("状态读取请求被拒绝", true);
            }
            return;
        }
        stageTimeoutRunnable = () -> {
            stageTimeoutRunnable = null;
            if (gen != generation || gatt != g || !"status".equals(stage)) return;
            if (!statusReadRetried) {
                statusReadRetried = true;
                Log.w(TAG, "[lat] status_read_timeout 1500ms，重试一次");
                readStatus(g);
            } else {
                failAttempt("状态读取超时(1.5s)", true);
            }
        };
        handler.postDelayed(stageTimeoutRunnable, READ_TIMEOUT_MS);
    }

    private void onReady(String statusPayload) {
        cancelTimers();
        ready = true;
        connecting = false;
        stage = "ready";
        attempt = 0;
        failureStreak = 0;
        nameMissStreak = 0;
        long dt = elapsedSince(connectStartedAt);
        Log.i(TAG, "[lat] ready elapsed=" + elapsedSince(t0)
                + "ms since_connect=" + dt + "ms evidence=cccd+status_read new-link"
                + " addr=" + attemptedAddress);
        if (activeEntry != null) {
            rememberSuccessfulIdentity(attemptedAddress,
                    expectedDeviceName != null ? expectedDeviceName : attemptedName);
        }
        publish(STATE_CONNECTED, getString(R.string.s45));
        if (statusPayload != null) {
            onStatusPayload(statusPayload);
        }
    }

    private void failAttempt(String reason, boolean markAddressStale) {
        if (!wantConnection) {
            resetConnection("stop");
            return;
        }
        String addr = attemptedAddress;
        Log.w(TAG, "[lat] fail stage=" + stage + " attempt=" + (attempt + 1)
                + " reason=" + reason);
        ready = false;
        connecting = false;
        stage = "idle";
        cancelTimers();
        stopScan();
        closeGatt();
        if (markAddressStale && addr != null) {
            // 建链失败只清「缓存地址提示」，不排除该地址；排除会让唯一可达的 Mac 被永久跳过
            clearAddressHint(addr);
        }

        attempt++;
        if (attempt < MAX_ATTEMPTS) {
            long delay = RETRY_DELAYS_MS[Math.min(attempt - 1, RETRY_DELAYS_MS.length - 1)];
            publish(STATE_ERROR, getString(R.string.s104) + reason);
            scheduleRetry(delay);
        } else {
            // 单轮最多 3 次，之后进入指数退避冷却重扫（仍会自愈，但状态不会停在「连接中」）。
            // 冷却只按连续失败轮数增长：目标整夜不在场时扫描间隔 6s→…→2min，避免低延迟扫描
            // 8s/6s 永久循环耗电；注意不要在这里清 excludedAddresses，否则身份排除又会失效。
            publish(STATE_ERROR, getString(R.string.s105));
            attempt = 0;
            long delay = Math.min(COOLDOWN_RETRY_MS << Math.min(failureStreak, 4), MAX_COOLDOWN_RETRY_MS);
            failureStreak++;
            Log.w(TAG, "[lat] cooldown failure_streak=" + failureStreak + " delay=" + delay + "ms");
            scheduleRetry(delay);
        }
    }

    private void scheduleRetry(long delayMs) {
        cancelRetry();
        retryRunnable = () -> {
            retryRunnable = null;
            if (wantConnection) {
                startScan("retry");
            }
        };
        handler.postDelayed(retryRunnable, delayMs);
        Log.i(TAG, "[lat] retry_in " + delayMs + "ms");
    }

    private void resetConnection(String reason) {
        Log.i(TAG, "重置连接: " + reason);
        generation++;
        cancelTimers();
        stopScan();
        ready = false;
        connecting = false;
        stage = "idle";
        commandChar = null;
        statusChar = null;
        infoChar = null;
        closeGatt();
    }

    /** 清空本轮重试计数（保留 wantConnection） */
    private void resetAttemptCampaign(boolean clearExcluded) {
        attempt = 0;
        failureStreak = 0;
        nameMissStreak = 0;
        if (clearExcluded) excludedAddresses.clear();
    }

    private void closeGatt() {
        generation++;
        BluetoothGatt g = gatt;
        gatt = null;
        if (g != null) {
            try {
                g.disconnect();
            } catch (SecurityException ignored) {
            }
            try {
                g.close();
            } catch (SecurityException ignored) {
            }
        }
    }

    private static boolean isEstablishFailure(int status) {
        // 133=GATT_ERROR；8=连接超时；62=建立连接失败；19/22=对端/本端主动断开
        return status == 133 || status == 8 || status == 62 || status == 19 || status == 22;
    }

    // ---------------------------------------------------------------- 状态回调

    private void onStatusPayload(String payload) {
        if (payload == null) return;
        String text = payload.trim();
        if (text.isEmpty()) return;
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
        if (g == null || c == null || !ready) {
            // 连接还没完成 CCCD+STATUS 握手：给「正在连接」而不是误报「尚未连接」
            Log.i(TAG, "[lat] send_rejected not_ready");
            return getString(R.string.s103);
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

    // ---------------------------------------------------------------- 工具

    private void lat(String event, String extra) {
        long elapsed = t0 > 0 ? SystemClock.elapsedRealtime() - t0 : 0L;
        Log.i(TAG, "[lat] " + event + " elapsed=" + elapsed + "ms"
                + (extra == null || extra.isEmpty() ? "" : " " + extra));
    }

    private long elapsedSince(long startElapsedRealtime) {
        if (startElapsedRealtime <= 0) return 0L;
        return SystemClock.elapsedRealtime() - startElapsedRealtime;
    }

    private static String resultName(ScanResult result) {
        String name = null;
        if (result.getScanRecord() != null) {
            name = result.getScanRecord().getDeviceName();
        }
        if (name == null || name.isEmpty()) {
            try {
                BluetoothDevice device = result.getDevice();
                name = device != null ? device.getName() : null;
            } catch (SecurityException ignored) {
            }
        }
        return name == null ? "" : name.trim();
    }

    private static boolean hasTargetService(ScanResult result) {
        if (result.getScanRecord() == null) return false;
        List<ParcelUuid> uuids = result.getScanRecord().getServiceUuids();
        if (uuids == null) return false;
        for (ParcelUuid uuid : uuids) {
            if (Protocol.SERVICE_UUID.equals(uuid.getUuid())) return true;
        }
        return false;
    }

    private static String normalizeName(String value) {
        if (value == null) return "";
        return value.toLowerCase(Locale.ROOT)
                .replaceAll("[^0-9a-z\\u4e00-\\u9fa5]", "");
    }

    private static boolean namesEqual(String a, String b) {
        String x = normalizeName(a);
        String y = normalizeName(b);
        return !x.isEmpty() && x.equals(y);
    }

    /**
     * 广播包只有 31 字节，128 位服务 UUID 会挤掉大部分 localName，
     * 扫描结果里可能只剩 "BLEUnlock" 这类前缀；此时允许用前缀匹配，
     * 真正的身份由连接后的 INFO 特征确认。
     */
    private static boolean nameMatchesTruncatedAdv(String full, String candidate) {
        String x = normalizeName(full);
        String y = normalizeName(candidate);
        if (x.isEmpty() || y.length() < 8) return false;
        // 真机实测：Mac 广播出去的名字可能是 "yp的MacBook Air"，
        // 而 INFO 特征里的全名是 "BLEUnlock-yp的MacBook Air"（前缀被 adv 挤掉），
        // 所以既允许前缀截断，也允许「候选是全名的后缀/子串」。
        return x.startsWith(y) || y.startsWith(x) || x.contains(y) || y.contains(x);
    }

    private static boolean fuzzyNameMatch(String entryName, String scanName) {
        String a = normalizeName(entryName);
        String b = normalizeName(scanName);
        if (a.isEmpty() || b.isEmpty()) return false;
        return b.contains(a) || a.contains(b);
    }

    private void cancelScanTimeout() {
        if (scanTimeoutRunnable != null) {
            handler.removeCallbacks(scanTimeoutRunnable);
            scanTimeoutRunnable = null;
        }
    }

    private void cancelChoose() {
        if (chooseRunnable != null) {
            handler.removeCallbacks(chooseRunnable);
            chooseRunnable = null;
        }
    }

    private void cancelWatchdog() {
        if (connectWatchdogRunnable != null) {
            handler.removeCallbacks(connectWatchdogRunnable);
            connectWatchdogRunnable = null;
        }
    }

    private void cancelStageTimeout() {
        if (stageTimeoutRunnable != null) {
            handler.removeCallbacks(stageTimeoutRunnable);
            stageTimeoutRunnable = null;
        }
    }

    private void cancelRetry() {
        if (retryRunnable != null) {
            handler.removeCallbacks(retryRunnable);
            retryRunnable = null;
        }
    }

    private void cancelScanRate() {
        if (scanRateRunnable != null) {
            handler.removeCallbacks(scanRateRunnable);
            scanRateRunnable = null;
        }
    }

    private void cancelTimers() {
        cancelScanTimeout();
        cancelChoose();
        cancelScanFallback();
        cancelScanRate();
        cancelWatchdog();
        cancelStageTimeout();
        cancelRetry();
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

        Intent reconnectIntent = new Intent(this, BleService.class);
        reconnectIntent.setAction(ACTION_RECONNECT);
        PendingIntent reconnectPending = PendingIntent.getService(this, 2, reconnectIntent,
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
                .addAction(new Notification.Action.Builder(null, getString(R.string.s99), reconnectPending).build())
                .build();
    }

    private void updateNotification(String state) {
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (nm != null) nm.notify(NOTIFICATION_ID, buildNotification(state));
    }
}
