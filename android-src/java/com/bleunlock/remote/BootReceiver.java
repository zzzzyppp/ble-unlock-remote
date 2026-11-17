package com.bleunlock.remote;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.SharedPreferences;
import android.util.Log;

/**
 * 开机自恢复：如果用户在关机前保持「自动连接」，开机后把前台服务拉起来重新连接。
 *
 * Android 8+ 不允许后台直接 startService，必须用 startForegroundService()；
 * BleService 会在 onCreate 里立刻 startForeground()，满足 5s 限制。
 */
public class BootReceiver extends BroadcastReceiver {

    private static final String TAG = "BootReceiver";

    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent == null) return;
        String action = intent.getAction();
        if (!Intent.ACTION_BOOT_COMPLETED.equals(action)) return;

        SharedPreferences prefs = context.getSharedPreferences(
                MacEntryStore.PREFS, Context.MODE_PRIVATE);
        boolean want = prefs.getBoolean(BleService.KEY_WANT_CONNECTION, false);
        Log.i(TAG, "收到开机广播，wantConnection=" + want);
        if (!want) return;

        Intent service = new Intent(context, BleService.class);
        service.setAction(BleService.ACTION_START);
        try {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                context.startForegroundService(service);
            } else {
                context.startService(service);
            }
        } catch (Exception e) {
            // 部分机型（如小米）对开机自启有额外限制：BOOT_COMPLETED 期间直接拉起 FGS 会被
            // 拒绝（Background started FGS: Disallowed, uidState=RCVR）。此时改为让系统闹钟
            // 在几秒后拉起前台服务。注意：Android 12+ 的 FGS 启动豁免项是「精确闹钟」，
            // 普通 set() 闹钟不在清单里，所以下面优先用 setExactAndAllowWhileIdle。
            Log.w(TAG, "开机恢复连接失败，改由系统闹钟稍后重试", e);
            scheduleRetryViaAlarm(context);
        }
    }

    private void scheduleRetryViaAlarm(Context context) {
        try {
            Intent retry = new Intent(context, BleService.class);
            retry.setAction(BleService.ACTION_START);
            PendingIntent pi = PendingIntent.getForegroundService(context, 0, retry,
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
            AlarmManager am = (AlarmManager) context.getSystemService(Context.ALARM_SERVICE);
            if (am == null) return;
            // 精确闹钟属于 Android 12+ 的 FGS 后台启动豁免项；没有 SCHEDULE_EXACT_ALARM
            // 授权时会抛 SecurityException，此时退回普通闹钟（可能被系统延迟，但聊胜于无）。
            long triggerAt = System.currentTimeMillis() + 3000;
            try {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pi);
                Log.i(TAG, "已安排 3s 后精确闹钟重试启动前台服务");
            } catch (SecurityException se) {
                Log.w(TAG, "无精确闹钟权限，退回普通闹钟", se);
                am.set(AlarmManager.RTC_WAKEUP, triggerAt, pi);
            }
        } catch (Exception e) {
            Log.w(TAG, "安排闹钟重试失败", e);
        }
    }
}
