-keep class com.google.android.gms.internal.** { *; }
-keep class com.google.android.gms.common.** { *; }
-dontwarn com.google.android.gms.**

# 保留小组件相关类，避免 R8 混淆导致 Glance 内部类名 key 冲突
-keep class com.coursehub.app.widget.** { *; }
-keep class androidx.glance.** { *; }
-keep class es.antonborri.home_widget.** { *; }
