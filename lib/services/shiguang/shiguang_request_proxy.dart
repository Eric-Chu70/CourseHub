import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 诊断回调（type / url / detail）。
typedef ShiguangProxyDiag = void Function(
    String type, String url, String detail);

/// WebView 主文档请求头代理。
///
/// 根因：Android WebView 内核在 HTTP 层自动附加的客户端提示头
/// `sec-ch-ua` 品牌列表中固定包含 `"Android WebView"`（Chrome 为
/// `"Google Chrome"`）。瑞数等服务端指纹检测直接据此识别 WebView，
/// 即便挑战 cookie 合法，也对其降级返回剥除了全部外链 script 的 HTML
/// （页面表现为元素大量缺失 / `$ is not defined`）。该头由网络栈生成，
/// JS 层无法改写；shouldInterceptRequest 是唯一的请求改写点。
///
/// 本代理把主文档 GET 导航在 Dart 侧重发：
/// - 透传内核可见头（Accept / Referer / Upgrade-Insecure-Requests /
///   User-Agent / sec-ch-ua-mobile / sec-ch-ua-platform …）；
/// - 把所有 sec-ch-* 头中的 `Android WebView` 品牌替换为 `Google Chrome`
///   （保留 GREASE 结构与版本号，与 UA 声称的 Chrome 一致）；
/// - 补 Accept-Language（内核网络层会发，但 shouldInterceptRequest 层
///   不可见，需自行补齐）与 Sec-Fetch-* 导航头；
/// - Cookie：shouldInterceptRequest 同样看不到网络层注入的 Cookie 头，
///   从 CookieManager 读取拼装；响应的 Set-Cookie 逐跳解析回写
///   CookieManager（重定向链上的会话 cookie 依赖此步骤）；
/// - 重定向（30x）由代理手动跟随（每跳 Set-Cookie 按各自 origin 持久
///   化）；最终 URL 与请求不同时交付 meta-refresh 落地页让内核自行导
///   航（文档源 / cookie 源 / 地址栏全部正确，且目标请求再次进入代
///   理）。绝不把合成 30x 直接交回内核——Chromium 对拦截层返回的
///   重定向响应不走正常跳转流程，实测（内核 124）直接原生闪退；
/// - 最终响应以 WebResourceResponse 返回（已解压，剥
///   Content-Encoding/Content-Length）。
///
/// 出错 / 超时 / 超时返回 null → 内核按原样自行请求（自然降级）。
/// POST 无法拿到请求体（Android 限制），一律透传（登录表单等场景
/// 内核原生行为可用）。
class ShiguangRequestProxy {
  ShiguangRequestProxy({
    required this.acceptLanguage,
    this.onDiag,
  });

  /// 请求头 Accept-Language（由宿主按设备 locale 生成）。
  final String acceptLanguage;
  final ShiguangProxyDiag? onDiag;

  HttpClient? _client;
  static const int _maxRedirects = 10;

  /// 连续挑战循环防护：同一 host 连续 N 个 202/412 视为代理方案在该站
  /// 失效（如 T cookie 与请求指纹绑定校验），停用并回落内核原生请求。
  static const int _challengeLoopLimit = 5;
  final Map<String, int> _challengeStreak = <String, int>{};
  final Set<String> _disabledHosts = <String>{};

  /// 落地页循环防护：同一 URL 连续触发 N 次落地页跳转（A→B→A 式
  /// 循环）时停用该域代理。
  static const int _shimLoopLimit = 6;
  final Map<String, int> _shimStreak = <String, int>{};

  void dispose() {
    _client?.close(force: true);
    _client = null;
  }

  HttpClient _http() {
    if (_client != null) return _client!;
    final c = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    // 老教务站点偶有证书配置问题；WebView 本身也不因证书中断导入
    // 流程，这里保持宽松。参数类型交由上下文推断（避免 X509Certificate
    // 名字解析歧义）。
    c.badCertificateCallback = (cert, host, port) => true;
    _client = c;
    return c;
  }

  /// 是否需要代理：主文档 GET 导航（http/https）。
  /// POST 拿不到请求体（Android 限制）只能透传；子资源目前原生
  /// 请求表现正常（图片 / VMP 脚本均 200），不动。
  static bool shouldProxy(WebResourceRequest request) {
    if (request.isForMainFrame != true) return false;
    final m = (request.method ?? 'GET').toUpperCase();
    if (m != 'GET') return false;
    final s = request.url.scheme;
    return s == 'http' || s == 'https';
  }

  /// 执行代理请求；null = 交回内核原生处理。
  Future<WebResourceResponse?> fetch(WebResourceRequest request) async {
    final originHost = request.url.host;
    if (_disabledHosts.contains(originHost)) return null;
    final sw = Stopwatch()..start();
    final requestUrl = request.url.toString();
    var uri = Uri.parse(requestUrl);
    final srcHeaders = request.headers ?? const <String, String>{};
    try {
      // 手动跟随重定向链（单跳请求 + 逐跳持久化 Set-Cookie）。
      // 绝不把 3xx 交回内核：Chromium 把 shouldInterceptRequest 的
      // 合成响应当最终响应处理，对合成 30x 不走正常重定向流程，
      // 轻则 ERR_UNSAFE_REDIRECT / ERR_FAILED，实测（内核 124）直接
      // 原生闪退。
      HttpClientResponse res;
      Uint8List body;
      var hops = 0;
      while (true) {
        final (r, b) = await _fetchOnce(uri, srcHeaders).timeout(
          const Duration(seconds: 25),
        );
        res = r;
        body = b;
        final loc =
            res.isRedirect ? res.headers.value(HttpHeaders.locationHeader) : null;
        if (loc == null || loc.isEmpty || hops >= _maxRedirects) break;
        hops++;
        uri = uri.resolve(loc);
      }

      // 残余 3xx（链超限 / 无 Location）：绝不把合成 30x 交付内核
      // （崩溃向量），一律回落内核原生请求。
      if (res.isRedirect) {
        if (hops >= _maxRedirects) {
          _disabledHosts.add(originHost);
          _diag('代理停用', originHost, '重定向链超限（>$_maxRedirects跳）');
        } else {
          _diag('代理跳转异常', originHost, '重定向响应缺少 Location，回落内核原生请求');
        }
        return null;
      }

      // 挑战循环检测。
      if (res.statusCode == 202 || res.statusCode == 412) {
        final c = (_challengeStreak[originHost] ?? 0) + 1;
        _challengeStreak[originHost] = c;
        if (c > _challengeLoopLimit) {
          _disabledHosts.add(originHost);
          _diag('代理停用', originHost,
              '连续 $c 个 ${res.statusCode}（挑战循环），该域名回落内核原生请求');
        }
      } else {
        _challengeStreak.remove(originHost);
      }

      // 最终 URL 与请求不同（发生过重定向）：交付 meta-refresh 落地页
      // 让内核自行导航到目标 URL——文档 URL / cookie 源 / 地址栏全部
      // 归位，且目标请求再次进入代理（挑战 / 头重写对每跳生效）。
      // 直接交付最终响应会把 idas 的页面挂到 eams 的 URL 名下，页面内
      // 相对资源（/authserver/...）全部打到错误主机 404（实测教训）。
      if (uri.toString() != requestUrl) {
        final c = (_shimStreak[requestUrl] ?? 0) + 1;
        _shimStreak[requestUrl] = c;
        if (c > _shimLoopLimit) {
          _disabledHosts.add(originHost);
          _diag('代理停用', originHost, '落地页循环（A→B→A），该域名回落内核原生请求');
          return null;
        }
        _diag('代理跳转', uri.host, '$hops跳 ${res.statusCode} → $uri');
        return _shimResponse(uri);
      }
      _shimStreak.remove(requestUrl);

      _diag('代理', uri.host, _describe(res, body, sw));
      return _toResponse(res, body);
    } on TimeoutException {
      _diag('代理超时', originHost, '25s，回落内核原生请求');
      return null;
    } catch (e) {
      _diag('代理失败', originHost, '$e，回落内核原生请求');
      return null;
    }
  }

  /// meta-refresh 落地页：0 秒跳转到 [target]，内核以全新导航请求目标
  /// URL（再次进入代理）。0 秒 meta refresh 在 Chromium 中按重定向语义
  /// 处理（替换历史记录，不产生返回按钮垃圾条目）。
  WebResourceResponse _shimResponse(Uri target) {
    final esc = const HtmlEscape().convert(target.toString());
    final html = '<!DOCTYPE html><html><head><meta charset="utf-8">'
        '<meta http-equiv="refresh" content="0;url=$esc">'
        '</head><body></body></html>';
    return WebResourceResponse(
      contentType: 'text/html',
      contentEncoding: 'utf-8',
      statusCode: 200,
      reasonPhrase: 'OK',
      headers: const {'Cache-Control': 'no-store'},
      data: Uint8List.fromList(utf8.encode(html)),
    );
  }

  /// 单跳请求（不跟随重定向）。
  Future<(HttpClientResponse, Uint8List)> _fetchOnce(
      Uri uri, Map<String, String> srcHeaders) async {
    final req = await _http().getUrl(uri);
    // 关键：dart:io HttpClient 默认自动跟随重定向，会吞掉 30x 并把最终
    // 响应挂到首个请求名下（文档源错乱的根因），必须显式关闭。
    req.followRedirects = false;
    await _applyHeaders(req, uri, srcHeaders);
    final res = await req.close();
    await _persistCookies(uri, res);
    final body = await _readBody(res);
    return (res, body);
  }

  Future<void> _applyHeaders(HttpClientRequest req, Uri uri,
      Map<String, String> srcHeaders) async {
    // 1. 透传内核可见头（Cookie/Accept-Encoding/Host 由网络层注入或
    //    自行管理，跳过；条件请求头一并剥离——内核 reload 可能携带
    //    If-None-Match，服务器返回 304 空体会让 Chromium 再渲染一次
    //    错误页，代理强制取全量响应）。
    srcHeaders.forEach((k, v) {
      final lk = k.toLowerCase();
      if (lk == 'cookie' || lk == 'host' || lk == 'accept-encoding' ||
          lk == 'content-length' || lk == 'connection' ||
          lk == 'if-none-match' || lk == 'if-modified-since') {
        return;
      }
      req.headers.set(k, v);
    });

    // 2. sec-ch-* 品牌重写：Android WebView → Google Chrome（保留
    //    GREASE 结构与版本号）。
    final ua = srcHeaders['user-agent'] ?? srcHeaders['User-Agent'] ?? '';
    var version = '143';
    final vm = RegExp(r'Chrome/(\d+)').firstMatch(ua);
    if (vm != null) version = vm.group(1)!;
    var hasSecChUa = false;
    req.headers.forEach((String name, List<String> values) {
      if (name.toLowerCase().startsWith('sec-ch-ua')) {
        hasSecChUa = true;
      }
    });
    if (!hasSecChUa) {
      req.headers.set(
          'sec-ch-ua', '"Google Chrome";v="$version", "Chromium";v="$version", "Not A(Brand";v="24"');
    }
    // 替换品牌：dart:io 的 headers 迭代中不能改，先收集再改。
    final rewrites = <String, String>{};
    req.headers.forEach((String name, List<String> values) {
      final ln = name.toLowerCase();
      if (ln.startsWith('sec-ch-ua')) {
        rewrites[name] = values
            .join(', ')
            .replaceAll('Android WebView', 'Google Chrome');
      }
    });
    rewrites.forEach(req.headers.set);

    // 3. 补齐浏览器一致性头。
    req.headers.set(HttpHeaders.acceptLanguageHeader, acceptLanguage);
    req.headers.set('Sec-Fetch-Dest', 'document');
    req.headers.set('Sec-Fetch-Mode', 'navigate');
    req.headers.set('Sec-Fetch-User', '?1');
    req.headers.set(
        'Sec-Fetch-Site', _fetchSite(uri, srcHeaders['referer']));

    // 4. Cookie：从 CookieManager 拼装（含 HttpOnly 会话 cookie——
    //    Android getCookie 返回的就是"将随请求发送"的完整串）。
    try {
      final cookies =
          await CookieManager.instance().getCookies(url: WebUri(uri.toString()));
      final valid = cookies
          .where((c) => c.name.isNotEmpty && c.value.isNotEmpty)
          .map((c) => '${c.name}=${c.value}')
          .toList();
      if (valid.isNotEmpty) {
        req.headers.set(HttpHeaders.cookieHeader, valid.join('; '));
      }
    } catch (_) {}
  }

  /// Sec-Fetch-Site：无 Referer = none；同 host = same-origin；
  /// 粗略同注册域 = same-site；否则 cross-site。
  String _fetchSite(Uri target, String? referer) {
    if (referer == null || referer.isEmpty) return 'none';
    try {
      final r = Uri.parse(referer);
      if (r.host == target.host) return 'same-origin';
      String reg(String h) {
        final parts = h.split('.');
        return parts.length > 2
            ? parts.sublist(parts.length - 2).join('.')
            : h;
      }
      return reg(r.host) == reg(target.host) ? 'same-site' : 'cross-site';
    } catch (_) {
      return 'cross-site';
    }
  }

  Future<Uint8List> _readBody(HttpClientResponse res) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in res) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// Set-Cookie 逐条解析回写 CookieManager。
  Future<void> _persistCookies(Uri uri, HttpClientResponse res) async {
    final raws = res.headers[HttpHeaders.setCookieHeader] ?? const <String>[];
    for (final raw in raws) {
      await _persistOne(uri, raw);
    }
  }

  Future<void> _persistOne(Uri uri, String raw) async {
    final parts = raw.split(';');
    final nv = parts.first.split('=');
    if (nv.length < 2) return;
    final name = nv.first.trim();
    final value = nv.sublist(1).join('=').trim();
    if (name.isEmpty) return;
    String path = '/';
    String? domain;
    int? maxAge;
    bool secure = false;
    bool httpOnly = false;
    for (final p in parts.skip(1)) {
      final eq = p.indexOf('=');
      final k = (eq >= 0 ? p.substring(0, eq) : p).trim().toLowerCase();
      final v = eq >= 0 ? p.substring(eq + 1).trim() : '';
      switch (k) {
        case 'path':
          if (v.isNotEmpty) path = v;
        case 'domain':
          domain = v;
        case 'max-age':
          maxAge = int.tryParse(v);
        case 'secure':
          secure = true;
        case 'httponly':
          httpOnly = true;
      }
    }
    try {
      await CookieManager.instance().setCookie(
        url: WebUri(uri.toString()),
        name: name,
        value: value,
        path: path,
        domain: domain,
        maxAge: maxAge,
        isSecure: secure,
        isHttpOnly: httpOnly,
      );
    } catch (_) {}
  }

  WebResourceResponse _toResponse(HttpClientResponse res, Uint8List body) {
    final headers = <String, String>{};
    res.headers.forEach((String name, List<String> values) {
      final ln = name.toLowerCase();
      // 已解压 / 长度不符 / Cookie 已单独持久化，剥除。
      if (ln == 'content-encoding' ||
          ln == 'content-length' ||
          ln == 'transfer-encoding' ||
          ln == 'set-cookie') {
        return;
      }
      if (values.isNotEmpty) headers[name] = values.join(', ');
    });
    // Content-Type 拆分：Android WebResourceResponse 的 mimeType 与
    // encoding 是两个独立参数。把 "text/html;charset=UTF-8" 整串塞给
    // mimeType 会被 Chromium 判为未知类型，按 text/plain 渲染成
    // <pre> 转义文本（页面「差点加载出来又变成文字」的根因）。
    final rawCt =
        res.headers.value(HttpHeaders.contentTypeHeader) ?? 'text/html';
    var mime = rawCt;
    String? charset;
    final semi = rawCt.indexOf(';');
    if (semi >= 0) {
      mime = rawCt.substring(0, semi).trim();
      final cm = RegExp(
        r'charset\s*=\s*"?([^\s;"]+)"?',
        caseSensitive: false,
      ).firstMatch(rawCt.substring(semi + 1));
      if (cm != null) charset = cm.group(1);
    }
    // 瑞数挑战页（202/412）以 200 交付：Chromium 对主文档非 200 响应
    // 渲染错误页（响应体被转义为纯文本塞进 <pre>），VMP 脚本根本不
    // 执行 → T cookie 永远无法生成 → 202 死循环。挑战页逻辑不读取
    // 自身状态码，200 只影响错误页触发。其余状态码原样保留（404 等
    // 错误页是正确行为）。
    final isChallenge = res.statusCode == 202 || res.statusCode == 412;
    return WebResourceResponse(
      contentType: mime.isEmpty ? 'text/html' : mime,
      contentEncoding: charset,
      statusCode: isChallenge ? 200 : res.statusCode,
      reasonPhrase: isChallenge
          ? 'OK'
          : (res.reasonPhrase.isNotEmpty ? res.reasonPhrase : 'OK'),
      headers: headers,
      data: body,
    );
  }

  String _describe(HttpClientResponse res, Uint8List body, Stopwatch sw) {
    final ct = res.headers.value(HttpHeaders.contentTypeHeader) ?? '';
    var scripts = -1;
    if (ct.contains('html') && body.isNotEmpty) {
      final html = utf8.decode(body, allowMalformed: true);
      scripts =
          RegExp(r'<script[^>]+src', caseSensitive: false).allMatches(html).length;
    }
    final sc = (res.headers[HttpHeaders.setCookieHeader] ?? const <String>[])
        .map((raw) => raw.split('=').first.trim())
        .where((n) => n.isNotEmpty)
        .join(',');
    return '${res.statusCode} $ct ${body.length}B '
        '脚本src:$scripts sc[$sc] ${sw.elapsedMilliseconds}ms';
  }

  void _diag(String type, String url, String detail) {
    onDiag?.call(type, url, detail);
  }
}
