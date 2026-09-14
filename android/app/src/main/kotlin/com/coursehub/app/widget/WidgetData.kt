package com.coursehub.app.widget

import android.content.Context
import android.graphics.Color
import es.antonborri.home_widget.HomeWidgetGlanceState
import org.json.JSONObject
import java.util.Calendar

/**
 * 小组件数据模型与解析工具
 *
 * Flutter 侧通过 home_widget 的 saveWidgetData 保存两组 JSON：
 * - "widget_today_data": 今日课程数据（用于 2x2 / 4x2 / 4x4今日）
 * - "widget_week_data":  本周课程数据（用于 4x4本周）
 *
 * 注意：数据存在 "HomeWidgetPreferences" SharedPreferences 中。
 * 每个小组件直接从 SharedPreferences 读取自己的 key，不依赖 Glance state 缓存。
 */
object WidgetData {

    private const val PREFS_NAME = "HomeWidgetPreferences"
    private const val KEY_TODAY = "widget_today_data"
    private const val KEY_WEEK = "widget_week_data"
    private const val DAY_MILLIS = 24L * 60 * 60 * 1000

    /** 单节课信息 */
    data class Course(
        val name: String,
        val teacher: String,
        val location: String,
        val color: Int,
        val startTime: String,
        val endTime: String,
        val periodStart: Int,
        val periodEnd: Int,
        val day: Int = -1,         // 仅本周课表使用，0=周一
        val weeks: String = "",    // 上课周次串（如 "1-16"、"1,3,5"），空=每周都上
        val isCurrent: Boolean = false
    )

    /** 今日课程数据 */
    data class TodayData(
        val label: String,
        val isHoliday: Boolean,
        val courses: List<Course>,
        val nextCourse: Course?,
        val followingCourse: Course?,
        val hasFinished: Boolean = false,
        val tomorrowLabel: String = "",
        val tomorrowCourses: List<Course> = emptyList()
    )

    /** 时间槽 */
    data class TimeSlot(
        val start: String,
        val end: String
    )

    /** 本周课表数据 */
    data class WeekData(
        val label: String,
        val isHoliday: Boolean,
        val dailyPeriods: Int,
        val currentWeek: Int = 1,
        val semesterWeeks: Int = 20,
        val semesterStartMillis: Long = 0L, // 开学日期时间戳；>0 时原生可重算当前周次
        val courses: List<Course>,
        val timeSlots: List<TimeSlot>
    )

    // ===== 直接从 Context 读取（推荐，不依赖 Glance state） =====

    /** 直接从 SharedPreferences 读取今日数据 */
    fun loadTodayData(context: Context): TodayData {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val json = prefs.getString(KEY_TODAY, null)
        return parseTodayJson(json)
    }

    /** 直接从 SharedPreferences 读取本周数据 */
    fun loadWeekData(context: Context): WeekData {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val json = prefs.getString(KEY_WEEK, null)
        return parseWeekJson(json)
    }

    /**
     * 读取今日数据并根据当前时间过滤已结束的课程
     *
     * Flutter 侧保存的是全部今日课程，此方法在原生侧根据当前时间实时过滤，
     * 使小组件能在 app 未运行时自动递推课程状态。
     * 同时重新计算 nextCourse / followingCourse / hasFinished。
     */
    fun loadTodayDataFiltered(context: Context): TodayData {
        val raw = loadTodayData(context)
        if (raw.isHoliday || raw.courses.isEmpty()) return raw

        val nowMinutes = getCurrentMinutes()

        // 过滤出未结束的课程，并重新计算 isCurrent
        val remaining = raw.courses.mapNotNull { course ->
            // endTime 为空或 00:00 时视为未设置时间，保留
            if (course.endTime.isEmpty() || course.endTime == "00:00") {
                course.copy(isCurrent = false)
            } else {
                val endMin = timeToMinutes(course.endTime)
                if (nowMinutes > endMin) {
                    null // 已结束
                } else {
                    val startMin = if (course.startTime.isEmpty() || course.startTime == "00:00") -1
                                   else timeToMinutes(course.startTime)
                    course.copy(isCurrent = startMin >= 0 && nowMinutes >= startMin && nowMinutes <= endMin)
                }
            }
        }

        // 重新计算 hasFinished
        val hasFinished = raw.courses.isNotEmpty() && remaining.isEmpty()

        // 重新计算 nextCourse / followingCourse
        val next = remaining.firstOrNull()
        val following = remaining.drop(1).firstOrNull()

        return raw.copy(
            courses = remaining,
            nextCourse = next,
            followingCourse = following,
            hasFinished = hasFinished
        )
    }

    /**
     * 自治计算今日课程数据（不依赖 Flutter 预计算的 widget_today_data）
     *
     * 从 widget_week_data 读取全部课程 + 时间槽 + 周次，原生侧根据当前日期和时间
     * 自行计算今日课程。解决跨天不更新问题：即使 app 多日未启动，也能显示正确的今日课程。
     *
     * 计算流程：
     * 1. 读取 widget_week_data（全量课程 + 时间槽 + 开学日期）
     * 2. 由开学日期原生重算当前周次（推送的 currentWeek 在 app 跨周未
     *    启动后已过期），缺失时退回推送值
     * 3. 根据当前日期判断星期几 + 当前周次 → 过滤今日课程
     * 4. 根据当前时间过滤已结束课程 + 重新计算 isCurrent
     * 5. 计算明日课程（跨周边界：周次 +1，且按明日周次筛选单双周课程）
     * 6. 回退：如果 widget_week_data 为空或解析失败，回退到 loadTodayDataFiltered
     */
    fun loadTodayDataAuto(context: Context): TodayData {
        val weekData = loadWeekData(context)

        // 无数据或无课程时回退
        if (weekData.courses.isEmpty() && weekData.timeSlots.isEmpty()) {
            return loadTodayDataFiltered(context)
        }

        val cal = Calendar.getInstance()
        // Android Calendar.DAY_OF_WEEK: 1=周日, 2=周一, ..., 7=周六
        // 转为 0=周一, 1=周二, ..., 6=周日
        val todayDayOfWeek = (cal.get(Calendar.DAY_OF_WEEK) + 5) % 7
        val nowMinutes = getCurrentMinutes()

        // 当前周次：优先由开学日期原生重算；无法计算时退回推送的 currentWeek
        val nativeWeek = computeCurrentWeek(weekData.semesterStartMillis)
        val currentWeek = if (nativeWeek > 0) nativeWeek else weekData.currentWeek

        // 假期判断：开学日期可用时以原生重算为准（推送的 isHoliday 只是
        // 上次 app 运行时的快照，跨假期边界会失真）；缺失时用推送值 + 超周兜底
        val isHoliday = if (weekData.semesterStartMillis > 0L) {
            System.currentTimeMillis() < mondayOfWeek1Millis(weekData.semesterStartMillis) ||
                currentWeek > weekData.semesterWeeks
        } else {
            weekData.isHoliday || currentWeek > weekData.semesterWeeks
        }

        val weekDays = arrayOf("周一", "周二", "周三", "周四", "周五", "周六", "周日")
        val label = "${weekDays[todayDayOfWeek]} · 第${currentWeek}周"

        // 假期时直接返回空课程，不显示任何课程信息
        if (isHoliday) {
            return TodayData(
                label = label,
                isHoliday = true,
                courses = emptyList(),
                nextCourse = null,
                followingCourse = null,
                hasFinished = false,
                tomorrowLabel = "",
                tomorrowCourses = emptyList()
            )
        }

        // 过滤今日课程（day + 当前周次；weekData.courses 已是全量课程，
        // 单双周课程必须按周次判断，空 weeks 视为每周都上）
        val todayCourses = weekData.courses.filter { c ->
            c.day == todayDayOfWeek &&
                (c.weeks.isBlank() || isCourseInWeek(c.weeks, currentWeek))
        }.map { c ->
            // 根据时间槽计算 startTime/endTime
            fillCourseTime(c, weekData.timeSlots)
        }.sortedBy { it.periodStart }

        // 过滤已结束课程 + 重新计算 isCurrent
        val remaining = todayCourses.mapNotNull { course ->
            if (course.endTime.isEmpty() || course.endTime == "00:00") {
                course.copy(isCurrent = false)
            } else {
                val endMin = timeToMinutes(course.endTime)
                if (nowMinutes > endMin) {
                    null
                } else {
                    val startMin = if (course.startTime.isEmpty() || course.startTime == "00:00") -1
                                   else timeToMinutes(course.startTime)
                    course.copy(isCurrent = startMin >= 0 && nowMinutes >= startMin && nowMinutes <= endMin)
                }
            }
        }

        val hasFinished = todayCourses.isNotEmpty() && remaining.isEmpty()
        val next = remaining.firstOrNull()
        val following = remaining.drop(1).firstOrNull()

        // 计算明日课程
        val tomorrowCal = Calendar.getInstance().apply { add(Calendar.DAY_OF_MONTH, 1) }
        val tomorrowDayOfWeek = (tomorrowCal.get(Calendar.DAY_OF_WEEK) + 5) % 7
        // 跨周：今天周日(6) → 明天周一(0)，周次+1
        val tomorrowWeek = if (todayDayOfWeek == 6 && tomorrowDayOfWeek == 0) {
            currentWeek + 1
        } else {
            currentWeek
        }
        val tomorrowIsHoliday = tomorrowWeek > weekData.semesterWeeks
        val tomorrowLabel = "${weekDays[tomorrowDayOfWeek]} · 第${tomorrowWeek}周"
        // 明日课程按"明天的周次"筛选：周日晚上看周一，单双周课程与本周
        // 集合不同（下周一才上的课要出现，本周最后一次上的课不能出现）
        val tomorrowCourses = if (tomorrowIsHoliday) {
            emptyList()
        } else {
            weekData.courses.filter { c ->
                c.day == tomorrowDayOfWeek &&
                    (c.weeks.isBlank() || isCourseInWeek(c.weeks, tomorrowWeek))
            }.map { c ->
                fillCourseTime(c, weekData.timeSlots)
            }.sortedBy { it.periodStart }
        }

        return TodayData(
            label = label,
            isHoliday = isHoliday,
            courses = remaining,
            nextCourse = next,
            followingCourse = following,
            hasFinished = hasFinished,
            tomorrowLabel = tomorrowLabel,
            tomorrowCourses = tomorrowCourses
        )
    }

    /** 根据时间槽填充课程的 startTime/endTime */
    private fun fillCourseTime(course: Course, timeSlots: List<TimeSlot>): Course {
        if (timeSlots.isEmpty()) return course
        val startIdx = course.periodStart - 1 // periodStart 是 1-based
        val endIdx = course.periodEnd - 1
        var startTime = ""
        var endTime = ""
        if (startIdx in timeSlots.indices) {
            startTime = timeSlots[startIdx].start
        }
        if (endIdx in timeSlots.indices) {
            endTime = timeSlots[endIdx].end
        }
        return course.copy(startTime = startTime, endTime = endTime)
    }

    /** 获取当前时间的分钟数 (0-1439) */
    fun getCurrentMinutes(): Int {
        val cal = Calendar.getInstance()
        return cal.get(Calendar.HOUR_OF_DAY) * 60 + cal.get(Calendar.MINUTE)
    }

    /** "HH:mm" 转分钟数 */
    fun timeToMinutes(time: String): Int {
        val parts = time.split(":")
        if (parts.size == 2) {
            val h = parts[0].toIntOrNull() ?: 0
            val m = parts[1].toIntOrNull() ?: 0
            return h * 60 + m
        }
        return 0
    }

    /**
     * 判断课程周次串是否包含指定周（与 Flutter 侧 _isCourseInWeek 同规则，
     * 支持 "1-16"、"1,3,5"、"1-16连" 等）。空串返回 false，调用方需先按
     * "空=每周都上"处理
     */
    fun isCourseInWeek(weeks: String, week: Int): Boolean {
        val cleaned = weeks.replace("连", "").replace("周", "").replace(" ", "")
        for (part in cleaned.split(",")) {
            val p = part.trim()
            if (p.contains("-")) {
                val range = p.split("-")
                if (range.size == 2) {
                    val start = range[0].trim().toIntOrNull()
                    val end = range[1].trim().toIntOrNull()
                    if (start != null && end != null && week >= start && week <= end) {
                        return true
                    }
                }
            } else {
                if (p.toIntOrNull() == week) return true
            }
        }
        return false
    }

    /** 开学日期所在周的周一（保留开学时刻，与 Flutter 侧 getCurrentWeek 的锚点一致） */
    private fun mondayOfWeek1Millis(semesterStartMillis: Long): Long {
        val cal = Calendar.getInstance().apply {
            timeInMillis = semesterStartMillis
            // DAY_OF_WEEK: 1=周日..7=周六 → (value + 5) % 7 得周一偏移量，回退到周一
            add(Calendar.DAY_OF_MONTH, -((get(Calendar.DAY_OF_WEEK) + 5) % 7))
        }
        return cal.timeInMillis
    }

    /**
     * 由开学日期原生重算当前周次（app 跨周未启动时推送的 currentWeek 已过期）。
     * 与 Flutter 侧 getCurrentWeek 同规则：周一锚点 + 整天差整除 7 + 1。
     * 返回 -1 表示无法计算（semesterStartMillis 缺失），调用方退回推送值。
     */
    fun computeCurrentWeek(semesterStartMillis: Long): Int {
        if (semesterStartMillis <= 0L) return -1
        val diffMillis = System.currentTimeMillis() - mondayOfWeek1Millis(semesterStartMillis)
        // Long 除法向零截断，与 Dart Duration.inDays 一致；负值（开学前）在下方归 1
        val week = (diffMillis / (DAY_MILLIS * 7)).toInt() + 1
        return if (week < 1) 1 else week
    }

    // ===== 从 HomeWidgetGlanceState 读取（向后兼容） =====

    /** 从 home_widget 状态中读取今日数据 */
    fun parseTodayData(state: HomeWidgetGlanceState?): TodayData {
        val json = state?.preferences?.getString(KEY_TODAY, null)
        return parseTodayJson(json)
    }

    /** 从 home_widget 状态中读取本周数据 */
    fun parseWeekData(state: HomeWidgetGlanceState?): WeekData {
        val json = state?.preferences?.getString(KEY_WEEK, null)
        return parseWeekJson(json)
    }

    // ===== JSON 解析 =====

    private fun parseTodayJson(json: String?): TodayData {
        if (json.isNullOrBlank()) {
            return TodayData("CourseHub", false, emptyList(), null, null)
        }
        return try {
            val obj = JSONObject(json)
            val label = obj.optString("label", "CourseHub")
            val isHoliday = obj.optBoolean("isHoliday", false)
            val courses = parseCourseArray(obj.optJSONArray("courses"))
            val nextObj = obj.optJSONObject("nextCourse")
            val next = if (nextObj != null) parseCourse(nextObj) else null
            val followingObj = obj.optJSONObject("followingCourse")
            val following = if (followingObj != null) parseCourse(followingObj) else null
            val hasFinished = obj.optBoolean("hasFinished", false)
            val tomorrowLabel = obj.optString("tomorrowLabel", "")
            val tomorrowCourses = parseCourseArray(obj.optJSONArray("tomorrowCourses"))
            TodayData(label, isHoliday, courses, next, following, hasFinished, tomorrowLabel, tomorrowCourses)
        } catch (e: Exception) {
            TodayData("CourseHub", false, emptyList(), null, null)
        }
    }

    private fun parseWeekJson(json: String?): WeekData {
        if (json.isNullOrBlank()) {
            return WeekData("CourseHub", false, 10, 1, 20, 0L, emptyList(), emptyList())
        }
        return try {
            val obj = JSONObject(json)
            val label = obj.optString("label", "CourseHub")
            val isHoliday = obj.optBoolean("isHoliday", false)
            val dailyPeriods = obj.optInt("dailyPeriods", 10)
            val currentWeek = obj.optInt("currentWeek", 1)
            val semesterWeeks = obj.optInt("semesterWeeks", 20)
            val semesterStartMillis = obj.optLong("semesterStartMillis", 0L)
            val courses = parseCourseArray(obj.optJSONArray("courses"))
            val timeSlots = parseTimeSlotArray(obj.optJSONArray("timeSlots"))
            WeekData(label, isHoliday, dailyPeriods, currentWeek, semesterWeeks,
                semesterStartMillis, courses, timeSlots)
        } catch (e: Exception) {
            WeekData("CourseHub", false, 10, 1, 20, 0L, emptyList(), emptyList())
        }
    }

    private fun parseCourseArray(arr: org.json.JSONArray?): List<Course> {
        if (arr == null) return emptyList()
        val list = mutableListOf<Course>()
        for (i in 0 until arr.length()) {
            val c = arr.optJSONObject(i) ?: continue
            list.add(parseCourse(c))
        }
        return list
    }

    private fun parseTimeSlotArray(arr: org.json.JSONArray?): List<TimeSlot> {
        if (arr == null) return emptyList()
        val list = mutableListOf<TimeSlot>()
        for (i in 0 until arr.length()) {
            val s = arr.optJSONObject(i) ?: continue
            list.add(TimeSlot(
                start = s.optString("start", ""),
                end = s.optString("end", "")
            ))
        }
        return list
    }

    private fun parseCourse(obj: JSONObject): Course {
        return Course(
            name = obj.optString("name", "未命名"),
            teacher = obj.optString("teacher", ""),
            location = obj.optString("location", ""),
            color = parseColor(obj.optString("color", "#4A90E2")),
            startTime = obj.optString("startTime", ""),
            endTime = obj.optString("endTime", ""),
            periodStart = obj.optInt("periodStart", 0),
            periodEnd = obj.optInt("periodEnd", 0),
            day = obj.optInt("day", -1),
            weeks = obj.optString("weeks", ""),
            isCurrent = obj.optBoolean("isCurrent", false)
        )
    }

    /** 解析 HEX 颜色字符串为 Color Int，带透明度支持 */
    fun parseColor(hex: String): Int {
        return try {
            Color.parseColor(hex)
        } catch (e: Exception) {
            Color.parseColor("#4A90E2")
        }
    }

    /** 将颜色 Int 转为带指定透明度的 HEX 字符串 */
    fun withAlpha(color: Int, alpha: Float): Int {
        val a = (255 * alpha).toInt().coerceIn(0, 255)
        return (a shl 24) or (color and 0x00FFFFFF)
    }
}
