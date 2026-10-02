package com.coursehub.app.liveupdate

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Path
import android.graphics.RectF
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.core.graphics.drawable.IconCompat
import com.coursehub.app.MainActivity
import com.coursehub.app.R
import com.coursehub.app.widget.WidgetData
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale

/**
 * 课程实时提醒（安卓 16 实时活动 / Live Updates）
 *
 * 走 AOSP 统一通道：一条 ongoing + promoted-ongoing 的标准通知，由系统渲染成
 * 状态栏胶囊（小米超级岛 / OPPO 流体云 / vivo 原子通知同源），不需要任何厂商
 * 私有协议、白名单申请或服务端推送。
 *
 * 生命周期分三段，全部由 ClassLiveUpdateScheduler 的精确闹钟驱动：
 * 1. 上课前 leadMinutes 分钟：胶囊出现，倒计时数到上课
 * 2. 上课中：同一个形态继续挂着，倒计时数到下课，每分钟刷新一次
 * 3. 下课：取消通知，胶囊消失
 *
 * 展开态固定四行：课程名 / 老师 · 地点 / 还剩 N 分钟 · 时间段 / 下节课…；
 * 胶囊（缩小态）显示地点。
 *
 * 数据来源是 WidgetData.loadTodayDataAuto —— 原生侧自行按开学日期/星期/当前
 * 时间推算今日课程，因此 Flutter 进程不在也能完整跑完整个周期。
 *
 * 偏好读取自本模块私有的 coursehub_live_update 文件（不是直接读 Flutter 的
 * SharedPreferences）：Dart 侧每次写入都会经 configure 同步一份过来，避免
 * shared_preferences 存储格式变动导致后台路径静默失效。
 */
object ClassLiveUpdateManager {

    const val CHANNEL_ID = "class_live_update_channel"
    private const val CHANNEL_NAME = "课程实时提醒"
    private const val CHANNEL_DESC = "在状态栏以实时活动形式显示当前或即将开始的课程"

    const val NOTIFICATION_ID = 20001

    private const val PREFS_NAME = "coursehub_live_update"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_LEAD_MINUTES = "lead_minutes"
    private const val KEY_SKIP_COURSE = "skip_course_key"
    private const val KEY_SKIP_UNTIL = "skip_until_millis"
    private const val KEY_TEST_UNTIL = "test_until_millis"

    private const val DEFAULT_LEAD_MINUTES = 10

    /** 实时活动放行权限：常量在 android-36.1 扩展才加入，compileSdk 36 无符号 */
    private const val PERMISSION_POST_PROMOTED =
        "android.permission.POST_PROMOTED_NOTIFICATIONS"

    /** 测试示例胶囊的存活时长：到点后闹钟会把展示交还给真实课表 */
    const val TEST_DURATION_MINUTES = 10
    private const val MINUTES_PER_DAY = 24 * 60

    /** 当前应展示的阶段：本节课 + 是否课前窗口 + 下一节课（可空） */
    private data class Phase(
        val course: WidgetData.Course,
        val preClass: Boolean,
        val nextCourse: WidgetData.Course?,
        val isTest: Boolean = false,
    )

    // ===== 偏好读写 =====

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun isEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_ENABLED, false)

    fun leadMinutes(context: Context): Int =
        prefs(context).getInt(KEY_LEAD_MINUTES, DEFAULT_LEAD_MINUTES)

    /** Dart 侧写入开关/提前量后同步过来，并立即重算展示与闹钟 */
    fun configure(context: Context, enabled: Boolean, lead: Int) {
        prefs(context).edit()
            .putBoolean(KEY_ENABLED, enabled)
            .putInt(KEY_LEAD_MINUTES, lead.coerceIn(0, 180))
            .apply()
        refresh(context)
        ClassLiveUpdateScheduler.scheduleNext(context)
    }

    // ===== 展示 =====

    /** 按当前时间重算并投递/更新/取消实时活动 */
    fun refresh(context: Context) {
        ensureChannel(context)

        // 测试窗口内示例胶囊优先（闹钟到点前屏蔽真实课表），倒计时照常推进
        val phase = when {
            isTestActive(context) -> testPhase()
            isEnabled(context) -> pickPhase(context)
            else -> null
        }
        if (phase == null) {
            cancel(context)
            return
        }

        val manager = NotificationManagerCompat.from(context)
        try {
            manager.notify(NOTIFICATION_ID, buildNotification(context, phase))
        } catch (e: SecurityException) {
            // 通知权限被收回：静默放弃，下次启动再同步
        }
    }

    fun cancel(context: Context) {
        NotificationManagerCompat.from(context).cancel(NOTIFICATION_ID)
    }

    /** 只创建一次即可；importance 用 LOW（实时活动不允许 MIN 档通道） */
    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = CHANNEL_DESC
                setShowBadge(false)
                enableVibration(false)
            }
        )
    }

    /**
     * 选出当前该展示的课程与阶段。
     *
     * 今日已无未结束课程、课程时间未配置、处于课前窗口之前、或本次已被
     * 用户「取消本次提醒」时返回 null（调用方负责取消通知）。
     */
    private fun pickPhase(context: Context): Phase? {
        val data = WidgetData.loadTodayDataAuto(context)
        if (data.isHoliday) return null

        val nowMinutes = WidgetData.getCurrentMinutes()
        val course = data.nextCourse ?: return null
        if (course.startTime.isEmpty() || course.startTime == "00:00") return null
        if (course.endTime.isEmpty() || course.endTime == "00:00") return null

        if (isSkipped(context, course)) return null

        val startMin = WidgetData.timeToMinutes(course.startTime)
        val endMin = WidgetData.timeToMinutes(course.endTime)
        if (endMin <= startMin) return null

        return when {
            nowMinutes in startMin..endMin ->
                Phase(course, preClass = false, nextCourse = data.followingCourse)
            nowMinutes < startMin && (startMin - nowMinutes) <= leadMinutes(context) ->
                Phase(course, preClass = true, nextCourse = data.followingCourse)
            else -> null
        }
    }

    /** 「下节课：课名 · 地点 · 时间段」；今日没有下一节时给一句收尾 */
    private fun nextLine(next: WidgetData.Course?): String {
        if (next == null) return "没有其它课程了~"
        val parts = mutableListOf(next.name)
        if (next.location.isNotBlank()) parts.add(next.location)
        if (next.startTime.isNotBlank() && next.endTime.isNotBlank() &&
            next.startTime != "00:00" && next.endTime != "00:00"
        ) {
            parts.add("${next.startTime}-${next.endTime}")
        }
        return "下节课：${parts.joinToString(" · ")}"
    }

    private fun buildNotification(context: Context, phase: Phase): android.app.Notification {
        val course = phase.course
        val nowMinutes = WidgetData.getCurrentMinutes()
        val startMin = WidgetData.timeToMinutes(course.startTime)
        val endMin = WidgetData.timeToMinutes(course.endTime)
        val timeRange = "${course.startTime} - ${course.endTime}"

        // 第三行：课前数到上课，课中数到下课
        val remainLine = if (phase.preClass) {
            "还剩 ${(startMin - nowMinutes).coerceAtLeast(0)} 分钟上课 · $timeRange"
        } else {
            "还剩 ${(endMin - nowMinutes).coerceAtLeast(0)} 分钟 · $timeRange"
        }

        // 第二行：老师 · 地点（缺哪项就只显示另一项）
        val whoLine = listOf(course.teacher, course.location)
            .filter { it.isNotBlank() }
            .joinToString(" · ")

        val lines = buildString {
            if (whoLine.isNotBlank()) append(whoLine).append('\n')
            append(remainLine).append('\n')
            append(nextLine(phase.nextCourse))
        }

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(smallIcon(context))
            // 胶囊（缩小态）取的是 contentTitle，所以这里放地点；展开态第一行走
            // BigContentTitle，课程名不会丢
            .setContentTitle(course.location.ifBlank { course.name })
            .setContentText(remainLine)
            .setColor(course.color)
            .setColorized(false)
            .setOngoing(true)
            .setSilent(true)
            .setOnlyAlertOnce(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setContentIntent(openAppIntent(context))
            .setWhen(millisOfToday(course.startTime))
            .setShowWhen(true)
            // 请求推广为实时活动；Android 16 以下该标记被忽略，
            // 自动降级成一条普通常驻通知
            .setRequestPromotedOngoing(true)
            .setStyle(
                NotificationCompat.BigTextStyle()
                    .setBigContentTitle(course.name)
                    .bigText(lines)
            )

        if (phase.isTest) {
            // 示例胶囊只给「停止测试」，避免把假课写进「本次已取消」记录
            builder.addAction(0, "停止测试", stopTestIntent(context))
            builder.setDeleteIntent(stopTestIntent(context))
        } else {
            builder.addAction(
                0,
                "取消本次提醒",
                skipOnceIntent(context, courseKey(course), endMin)
            )
            builder.addAction(0, "打开课表", openAppIntent(context))
            builder.setDeleteIntent(skipOnceIntent(context, courseKey(course), endMin))
        }

        return builder.build()
    }

    // ===== 测试示例（自检用，走的是与真实提醒完全相同的渲染路径） =====

    fun isTestActive(context: Context): Boolean =
        prefs(context).getLong(KEY_TEST_UNTIL, 0L) > System.currentTimeMillis()

    fun testUntilMillis(context: Context): Long =
        prefs(context).getLong(KEY_TEST_UNTIL, 0L)

    /** 立即显示一条示例胶囊，TEST_DURATION_MINUTES 分钟后自动交还真实课表 */
    fun startTest(context: Context) {
        prefs(context).edit()
            .putLong(
                KEY_TEST_UNTIL,
                System.currentTimeMillis() + TEST_DURATION_MINUTES * 60_000L
            )
            .apply()
        refresh(context)
        ClassLiveUpdateScheduler.scheduleNext(context)
    }

    fun stopTest(context: Context) {
        prefs(context).edit().remove(KEY_TEST_UNTIL).apply()
        refresh(context)
        ClassLiveUpdateScheduler.scheduleNext(context)
    }

    /**
     * 构造一节"正在上"的假课：已上 12 分钟、共 45 分钟，进度条推进到约 1/4。
     * 起始分钟数向下取零、结束时刻不超过 23:59，避免跨零点时出现 24:xx 这种
     * 非法时间串（真机测试常在深夜进行）。
     */
    private fun testPhase(): Phase {
        val nowMinutes = WidgetData.getCurrentMinutes()
        val startMin = (nowMinutes - 12).coerceAtLeast(0)
        val endMin = (startMin + 45).coerceAtMost(MINUTES_PER_DAY - 1)
        val course = WidgetData.Course(
            name = "测试课程",
            teacher = "张老师",
            location = "教学楼 A101",
            color = 0xFF4A90E2.toInt(),
            startTime = minutesToHHmm(startMin),
            endTime = minutesToHHmm(endMin),
            periodStart = 0,
            periodEnd = 0,
        )
        // 造一节"下一节"，好把展开态最后一行的两种形态都验到
        val nextStart = (endMin + 10).coerceAtMost(MINUTES_PER_DAY - 6)
        val next = course.copy(
            name = "大学英语",
            teacher = "李老师",
            location = "实验楼 B305",
            startTime = minutesToHHmm(nextStart),
            endTime = minutesToHHmm(nextStart + 5),
        )
        return Phase(
            course = course,
            preClass = false,
            nextCourse = next,
            isTest = true,
        )
    }

    private fun minutesToHHmm(minutes: Int): String =
        String.format(Locale.getDefault(), "%02d:%02d", minutes / 60, minutes % 60)

    /**
     * 自检：把系统自己对"这条通知能不能被提升成实时活动"的判定原样吐回 Flutter。
     *
     * canPostPromoted=false → 系统/用户层面就没放行（多半是 targetSdk 门槛或
     *   设置里那个按 App 的实时活动开关），跟我们的代码无关；
     * canPostPromoted=true 且 promotable=true 却仍不上岛 → 澎湃的岛只认小米
     *   私有焦点通知协议，得往 extras 里写 miui.focus.param。
     */
    fun diagnose(context: Context): Map<String, Any?> {
        val compat = NotificationManagerCompat.from(context)
        val notification = buildNotification(context, testPhase())
        val importance: Int? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                .getNotificationChannel(CHANNEL_ID)?.importance
        } else {
            null
        }
        return mapOf(
            "canPostPromoted" to compat.canPostPromotedNotifications(),
            // 声明了 uses-permission 不代表拿得到：若这里是 ✗ 而放行也是 ✗，
            // 说明该权限是特权/签名级，第三方应用走不通这条标准通道
            "promotedPermission" to (ContextCompat.checkSelfPermission(
                context, PERMISSION_POST_PROMOTED
            ) == PackageManager.PERMISSION_GRANTED),
            "notificationsEnabled" to compat.areNotificationsEnabled(),
            "promotable" to NotificationCompat.hasPromotableCharacteristics(notification),
            "promotedFlag" to NotificationCompat.isRequestPromotedOngoing(notification),
            "channelImportance" to importance,
            "sdkInt" to Build.VERSION.SDK_INT,
            "targetSdk" to context.applicationInfo.targetSdkVersion,
        )
    }

    /**
     * 胶囊与展开卡片左侧那个图标取的是 smallIcon 原图：HyperOS 既不做圆角遮罩、
     * 也不按模板着色，而 drawable/ic_launcher_foreground 是无 alpha 通道的方块图
     * （直接贴出来就是个直角方块，还会被卡片二次裁成"白底+蓝环"）。
     */
    private var roundedIcon: Bitmap? = null

    /**
     * smallIcon 取图：圆角位图优先，任何异常都退回资源图标。
     *
     * 图标纯外观，绝不能因为它构造失败就让整条实时活动消失。
     */
    private fun smallIcon(context: Context): IconCompat = try {
        IconCompat.createWithBitmap(roundedAppIcon(context))
    } catch (e: Throwable) {
        IconCompat.createWithResource(context, R.mipmap.ic_launcher)
    }

    /**
     * 把 app 图标裁成 24% 圆角、四角透明的位图。
     *
     * 两个坑都踩过，这里锁死：
     * - 不能 decodeResource(R.mipmap.ic_launcher)：API 26+ 上该 mipmap 命中的是
     *   anydpi-v26 的 adaptive-icon XML，decodeResource 返回 null（曾把整条实时
     *   活动以 NPE 的形式搞崩）；
     * - 也不能用 PackageManager.getApplicationIcon 拿到的 adaptive drawable 直接
     *   画进 Canvas：它只画出背景色块（#4A90E2 蓝底），前景不出现。
     * 所以用 drawable-nodpi/ic_launcher_square.png —— 一份确定是位图的完整图标副本。
     */
    private fun roundedAppIcon(context: Context): Bitmap {
        roundedIcon?.let { return it }

        val src = BitmapFactory.decodeResource(context.resources, R.drawable.ic_launcher_square)
            ?: error("ic_launcher_square 解码失败")
        val side = minOf(src.width, src.height).toFloat()
        val out = Bitmap.createBitmap(side.toInt(), side.toInt(), Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        val clip = Path().apply {
            addRoundRect(
                RectF(0f, 0f, side, side),
                side * 0.24f,
                side * 0.24f,
                Path.Direction.CW,
            )
        }
        canvas.clipPath(clip)
        canvas.drawBitmap(src, 0f, 0f, null)
        src.recycle()

        roundedIcon = out
        return out
    }

    // ===== 「取消本次提醒」 =====

    /** 同一节课 + 同一天 视为同一次，记到下课时刻为止 */
    private fun courseKey(course: WidgetData.Course): String =
        "${todayDateString()}|${course.periodStart}|${course.name}"

    private fun isSkipped(context: Context, course: WidgetData.Course): Boolean {
        val stored = prefs(context).getString(KEY_SKIP_COURSE, null) ?: return false
        val until = prefs(context).getLong(KEY_SKIP_UNTIL, 0L)
        if (System.currentTimeMillis() >= until) return false
        return stored == courseKey(course)
    }

    /** 用户滑掉或点「取消本次提醒」：本次课不再展示，直到下课时刻 */
    fun skipOnce(context: Context, key: String, endMinutes: Int) {
        prefs(context).edit()
            .putString(KEY_SKIP_COURSE, key)
            .putLong(KEY_SKIP_UNTIL, millisOfMinutes(endMinutes))
            .apply()
        cancel(context)
        ClassLiveUpdateScheduler.scheduleNext(context)
    }

    // ===== PendingIntent =====

    private fun openAppIntent(context: Context): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        return PendingIntent.getActivity(
            context, 100, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun skipOnceIntent(context: Context, key: String, endMinutes: Int): PendingIntent {
        val intent = Intent(context, ClassLiveUpdateReceiver::class.java).apply {
            action = ClassLiveUpdateReceiver.ACTION_SKIP_ONCE
            putExtra(ClassLiveUpdateReceiver.EXTRA_COURSE_KEY, key)
            putExtra(ClassLiveUpdateReceiver.EXTRA_END_MINUTES, endMinutes)
        }
        return PendingIntent.getBroadcast(
            context, 101, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun stopTestIntent(context: Context): PendingIntent {
        val intent = Intent(context, ClassLiveUpdateReceiver::class.java).apply {
            action = ClassLiveUpdateReceiver.ACTION_STOP_TEST
        }
        return PendingIntent.getBroadcast(
            context, 102, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    // ===== 时刻换算 =====

    private fun todayDateString(): String =
        SimpleDateFormat("yyyy-MM-dd", Locale.getDefault()).format(Calendar.getInstance().time)

    /** 今日 HH:mm 对应的毫秒时间戳 */
    private fun millisOfMinutes(minutes: Int): Long {
        val cal = Calendar.getInstance()
        cal.set(Calendar.HOUR_OF_DAY, minutes / 60)
        cal.set(Calendar.MINUTE, minutes % 60)
        cal.set(Calendar.SECOND, 0)
        cal.set(Calendar.MILLISECOND, 0)
        return cal.timeInMillis
    }

    /** 供调度器复用：今日 HH:mm 的毫秒时间戳 */
    fun millisOfToday(startTime: String): Long =
        millisOfMinutes(WidgetData.timeToMinutes(startTime))

    /** 供调度器复用：今日某「一天内分钟数」的毫秒时间戳 */
    fun millisOfTodayMinutes(minutes: Int): Long = millisOfMinutes(minutes)

    /** AlarmManager 精确闹钟的统一封装（与小组件调度器同策略） */
    fun setExactAlarm(context: Context, triggerAtMillis: Long, pendingIntent: PendingIntent) {
        val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            !alarmManager.canScheduleExactAlarms()
        ) {
            alarmManager.setAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP, triggerAtMillis, pendingIntent
            )
        } else {
            alarmManager.setExactAndAllowWhileIdle(
                AlarmManager.RTC_WAKEUP, triggerAtMillis, pendingIntent
            )
        }
    }
}
