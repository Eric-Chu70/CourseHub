#version 460 core

#include <flutter/runtime_effect.glsl>

// 渐进模糊标题栏（参考 MIUI 日历无界标题栏）：
// 单 pass 渐变 blur + 渐进压暗，模糊半径与压暗强度随高度变化——
// 顶部最强、底缘归零（无界过渡）。通过 ImageFilter.shader 挂进
// BackdropFilter 使用，仅 Impeller 支持。
//
// 坐标约定（实测校准）：ImageFilter 的 FragCoord 是屏幕物理像素坐标、
// 原点在屏幕顶部（标题栏钉在屏幕最顶端，故局部与屏幕坐标重合）；
// u_size 由引擎注入（整块背景纹理尺寸），只用于 px→uv 换算，不要
// 按它做位置归一——那是第一版「均匀最大模糊+硬边界」的根因。
//
// 采样：36 点黄金角螺旋 + 高斯权重 + 每像素随机旋转（stochastic
// jitter）。大半径下稀疏点采样会把高对比文字变成离散 ghost 复制
// （「划痕/打散」感），每像素随机旋转把结构化 ghost 打散成均匀
// 细噪点，视觉上即正常模糊颗粒。

// 引擎注入：背景纹理尺寸（物理px），必须是首个 uniform
uniform vec2 u_size;
// 标题栏总高（物理px，Dart 侧已乘 DPR）
uniform float u_header_h;
// 顶部最大模糊半径（物理px）
uniform float u_max_radius;
// 顶部压暗强度（0..1）
uniform float u_max_scrim;
// 状态栏区（标题栏上半段）额外遮罩强度：自中点向顶部线性加深
uniform float u_status_scrim;
// 遮罩颜色 rgb（浅色=白磨砂 / 深色=近黑磨砂）
uniform vec4 u_scrim_color;
// 模糊衰减带高度占比（0..1）：底缘向上到此比例处爬升到满模糊，
// 越小雾面越贴近带底（模糊起始线越靠下）
uniform float u_blur_band;
// 曲线整体下移量（物理px，0=不移）：同一高度压上原来上移此距离处
// 的雾浓度（标题可读性↑）；最后 u_shift 段用 smoothstep 收口，
// 底缘仍精确归零——只在标题栏内部挪曲线，不越界糊内容
uniform float u_shift;
// 首个 sampler：引擎自动绑定为背景内容
uniform sampler2D u_backdrop;

out vec4 frag_color;

float hash12(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

void main() {
  vec2 frag = FlutterFragCoord().xy;

  // 距屏幕顶部的物理像素距离。GLES 纹理 y 轴自下而上，需用纹理高度
  // （引擎注入的 u_size.y）翻转；Vulkan/Metal 原点即屏幕左上
#ifdef IMPELLER_TARGET_OPENGLES
  float yTop = u_size.y - frag.y;
#else
  float yTop = frag.y;
#endif

  // t：顶部=1、底缘=0。
  // 模糊与遮罩共用同一条曲线（2026-09-26 定稿）：
  // * 模糊：底缘**归零**（smoothstep 零导数贴边，无分界线）；衰减带
  //   高度占比由 u_blur_band 控制（默认 0.40）：标题行（多数页面上移
  //   6px 后底缘恰落在平台末端）整行近满模糊，平台以下是一段缓坡，
  //   标题压着的内容行模糊度更高（可读性问题的主要矛盾：标题压着
  //   清晰内容）；课表页带子高，收窄衰减带让雾面顶到网格线头；
  // * 遮罩：透明度渐变=模糊梯度本身（teBlur），顶部满浓度（浅色
  //   0.7 / 深色 0.55），随模糊坡同步渐弱到底缘归零——「模糊渐强的
  //   同时遮罩也渐强」，取代原先独立 55% 坡 + 浅色顶部加霜两层。
  //
  // u_shift：把整条曲线向下平移（同一 y 取原来 y-u_shift 处的浓度），
  // 再乘一个底缘 smoothstep 收口因子，保证底缘仍精确归零、不越界
  // 把标题栏下方的真实内容糊掉。收口只吃掉最后 ~u_shift 像素的浓度。
  float tRaw = 1.0 - clamp(yTop / u_header_h, 0.0, 1.0);
  float t = clamp(tRaw + u_shift / u_header_h, 0.0, 1.0);
  // 底缘收口：tRaw 从 0 爬升到 u_shift/h 时 taper 0→1（零导数贴边）；
  // u_shift=0（多数页）时不引入除零，taper 恒 1
  float shiftFrac = max(u_shift / u_header_h, 1e-5);
  float taper = u_shift > 0.0 ? smoothstep(0.0, shiftFrac, tRaw) : 1.0;
  float teBlur = smoothstep(0.0, u_blur_band, t) * taper;
  float radius = u_max_radius * teBlur;

  // 采样：背景纹理 uv = frag / u_size（屏幕空间），偏移按物理px换算。
  vec2 px = vec2(1.0) / u_size;
  vec2 uv = frag * px;

  // 每像素随机旋转采样盘（stochastic jitter）：打散结构化 ghost
  float jitter = hash12(frag) * 6.2831853;
  mat2 rot = mat2(cos(jitter), -sin(jitter), sin(jitter), cos(jitter));

  vec3 acc = vec3(0.0);
  float wsum = 0.0;
  for (int i = 0; i < 36; i++) {
    float fi = float(i);
    float a = fi * 2.39996323; // 黄金角
    float r = sqrt((fi + 0.5) / 36.0);
    vec2 suv = clamp(
        uv + rot * vec2(cos(a), sin(a)) * r * radius * px,
        vec2(0.0), vec2(1.0));
    float w = exp(-2.5 * r * r);
    acc += texture(u_backdrop, suv).rgb * w;
    wsum += w;
  }
  vec3 color = acc / wsum;

  // 渐进遮罩：与模糊共用 teBlur 曲线——顶部满浓度，随模糊坡同步
  // 渐弱，底缘归零无分界
  float scrim = clamp(u_max_scrim * teBlur, 0.0, 1.0);
  color = mix(color, u_scrim_color.rgb, scrim);

  // 状态栏可读性：标题栏上半段（含状态栏）自中点向顶部线性加深的
  // 额外遮罩——「由下往上逐渐变深」，浅色=白 / 深色=近黑
  float zoneT = 1.0 - clamp(yTop / (u_header_h * 0.5), 0.0, 1.0);
  float statusScrim = clamp(u_status_scrim * zoneT, 0.0, 1.0);
  color = mix(color, u_scrim_color.rgb, statusScrim);

  frag_color = vec4(color, 1.0);
}
