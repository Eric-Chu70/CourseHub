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
     * 1. 读取 widget_week_data（含全部课程、时间槽、当前周次、学期周数）
     * 2. 根据当前日期判断今天星期几 → 过滤今日课程
     * 3. 根据当前时间过滤已结束课程 + 重新计算 isCurrent
     * 4. 计算明日课程（处理跨周边界）
     * 5. 回退：如果 widget_week_data 为空或解析失败，回退到 loadTodayDataFiltered
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

        // 假期判断：当前周次 > 学期周数
        val isHoliday = weekData.currentWeek > weekData.semesterWeeks

        val weekDays = arrayOf("周一", "周二", "周三", "周四", "周五", "周六", "周日")
        val label = "${weekDays[todayDayOfWeek]} · 第${weekData.currentWeek}周"

        // 过滤今日课程（根据 day 字段 + 周次）
        val todayCourses = weekData.courses.filter { c ->
            c.day == todayDayOfWeek
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
            weekData.currentWeek + 1
        } else {
            weekData.currentWeek
        }
        val tomorrowIsHoliday = tomorrowWeek > weekData.semesterWeeks
        val tomorrowLabel = "${weekDays[tomorrowDayOfWeek]} · 第${tomorrowWeek}周"
        val tomorrowCourses = if (tomorrowIsHoliday) {
            emptyList()
        } else {
            weekData.courses.filter { c -> c.day == tomorrowDayOfWeek }.map { c ->
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
            return WeekData("CourseHub", false, 10, 1, 20, emptyList(), emptyList())
        }
        return try {
            val obj = JSONObject(json)
            val label = obj.optString("label", "CourseHub")
            val isHoliday = obj.optBoolean("isHoliday", false)
            val dailyPeriods = obj.optInt("dailyPeriods", 10)
            val currentWeek = obj.optInt("currentWeek", 1)
            val semesterWeeks = obj.optInt("semesterWeeks", 20)
            val courses = parseCourseArray(obj.optJSONArray("courses"))
            val timeSlots = parseTimeSlotArray(obj.optJSONArray("timeSlots"))
            WeekData(label, isHoliday, dailyPeriods, currentWeek, semesterWeeks, courses, timeSlots)
        } catch (e: Exception) {
            WeekData("CourseHub", false, 10, 1, 20, emptyList(), emptyList())
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
