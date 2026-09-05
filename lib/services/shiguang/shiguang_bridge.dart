/// 拾光适配脚本 JS Bridge：控制台通道版。
///
/// 瑞数等反爬 WAF 通过指纹探测 window 上的注入痕迹（原生桥对象、
/// Promise/print 覆写等）判定非真人浏览器，随后对子资源持续返回 HTML
/// 挑战页，表现为页面元素大量加载失败（$ / jQuery is not defined）。
/// 配合本地补丁的 flutter_inappwebview_android（见 pubspec.yaml
/// dependency_overrides），本桥不在页面加载期创建任何全局对象：
/// - JS → Dart：`console.log('[[SG]]' + JSON)` 魔术前缀消息，
///   由宿主在 onConsoleMessage 中解析分发（[magicPrefix]）；
/// - Dart → JS：`evaluateJavascript`（WebView 原生通道，页面无感知）；
/// - 大数据（课程 JSON）：JS 侧先存 `window.__sgSavePayload`，Dart 再
///   拉取，避免控制台消息被截断。
///
/// [glueJs] 仅在用户点击「开始导入」时注入，页面加载期零环境痕迹。
class ShiguangBridge {
  ShiguangBridge._();

  /// 控制台桥消息的魔术前缀（onConsoleMessage 据此识别桥消息）。
  static const String magicPrefix = '[[SG]]';

  /// 桥胶水：把适配脚本期望的 window.shiguangBridge /
  /// window.shiguangBridgePromise 协议适配到控制台通道。
  ///
  /// Promise 结果由宿主通过 evaluateJavascript 调用
  /// `window.__sgResolve(id, ok, value)` 回填：
  /// - ok=true：resolve(value ?? true)；
  /// - ok=false 且带 value：reject(Error)——保存失败 / 用户取消。多数
  ///   适配脚本不检查 saveImportedCourses 的返回值，resolve(false) 会
  ///   放行脚本继续走「导入成功」流程（取消后仍弹成功提示的根因），
  ///   reject 让 await 抛异常进脚本自身 catch（抽查 8 校脚本均有）
  ///   统一收尾；
  /// - ok=false 无 value：resolve(false)（对话框被关闭等中性结果）。
  ///
  /// 同时暴露 window.AndroidBridge / AndroidBridgePromise 别名（旧
  /// 协议 v1 命名，部分学校脚本仍在使用），仅在导入期注入无指纹风险。
  static const String glueJs = '''
(function() {
  if (window.__shiguangBridgeReady) { return; }
  window.__shiguangBridgeReady = true;
  var pending = {};
  var nextId = 1;
  window.__sgResolve = function(id, ok, value) {
    var r = pending[id];
    if (!r) { return; }
    delete pending[id];
    if (ok) {
      r[0](value !== undefined ? value : true);
    } else if (value !== undefined && value !== null) {
      r[1](new Error(String(value)));
    } else {
      r[0](false);
    }
  };
  var send = function(msg) {
    try { console.log('[[SG]]' + JSON.stringify(msg)); } catch (e) {}
  };
  var call = function(msg) {
    var id = nextId++;
    msg.id = id;
    var p = new Promise(function(resolve, reject) {
      pending[id] = [resolve, reject];
    });
    send(msg);
    return p;
  };
  window.shiguangBridge = {
    showToast: function(msg) {
      send({fn: 'toast', msg: msg == null ? '' : String(msg)});
    },
    notifyTaskCompletion: function() { send({fn: 'completion'}); }
  };
  window.shiguangBridgePromise = {
    showAlert: function(title, message, btnText) {
      return call({fn: 'alert',
            title: title == null ? '' : String(title),
            message: message == null ? '' : String(message),
            btnText: btnText == null ? '确定' : String(btnText)});
    },
    // 单选对话框：返回选中索引（int），取消返回 null / -1。
    showSingleSelection: function(title, labelsJson, defaultIdx) {
      return call({fn: 'selection',
            title: title == null ? '' : String(title),
            labels: labelsJson == null ? '[]' : String(labelsJson),
            defaultIdx: defaultIdx == null ? 0 : Number(defaultIdx) || 0});
    },
    // 输入对话框：返回输入文本（string），取消返回 null。
    showPrompt: function(title, message, defaultText) {
      return call({fn: 'prompt',
            title: title == null ? '' : String(title),
            message: message == null ? '' : String(message),
            defaultText: defaultText == null ? '' : String(defaultText)});
    },
    // 保存作息时间段（[{number,startTime,endTime}]）：数据小，直接走
    // 控制台消息体（大数据才需要 window 变量中转）。
    savePresetTimeSlots: function(slotsJson) {
      return call({fn: 'timeSlots',
            payload: slotsJson == null ? '[]' : String(slotsJson)});
    },
    // 保存课程配置（{semesterTotalWeeks,...} 等）。
    saveCourseConfig: function(configJson) {
      return call({fn: 'config',
            payload: configJson == null ? '{}' : String(configJson)});
    },
    saveImportedCourses: function(jsonString) {
      window.__sgSavePayload = String(jsonString);
      return call({fn: 'save'});
    }
  };
  window.AndroidBridge = window.shiguangBridge;
  window.AndroidBridgePromise = window.shiguangBridgePromise;
})();
''';

  /// Chrome 环境补全（document-start 注入，所有 frame）：Android WebView
  /// 没有 window.chrome 对象（Chrome 浏览器独有）、navigator.plugins 为空
  /// （Chrome 95+ 全平台固定上报 5 个 PDF 插件 + 2 个 mimeType），瑞数等
  /// WAF 据此识别 WebView 并持续下发挑战页（表现为页面 JS 资源永远无法
  /// 通过验证）。补全：
  /// - window.chrome：app / csi / loadTimes / runtime 四件套；
  /// - navigator.plugins / mimeTypes / pdfViewerEnabled（HTML 规范规定
  ///   支持内嵌 PDF 的浏览器固定返回 5 个标准插件）；
  /// 通过全局 Function.prototype.toString 补丁让所有补全函数的原生性
  /// 检测（fn.toString().includes('[native code]')）通过——补丁自身同样
  /// 返回原生形态，页面无法察觉。
  /// 注入通道：WebViewCompat.addDocumentStartJavaScript（主世界、
  /// 先于页面任何脚本执行、原生层注入无 JS 痕迹，由 initialUserScripts
  /// 挂载，见 shiguang_web_import_screen.dart）；about:blank（origin 规则
  /// 不覆盖）由 onLoadStart/onLoadStop 的兜底注入补齐。
  static const String chromeEnvJs = '''
(function() {
  // 幂等守卫：chrome 已补且 plugins 已非空（补全后 length=5）则跳过。
  // 不留任何自定义标记属性（真实 navigator 上多出的可枚举键本身就是
  // 新指纹）。
  if (window.chrome && navigator.plugins && navigator.plugins.length > 0) { return; }
  var origToString = Function.prototype.toString;
  var nativeNames = new WeakMap();
  var patchedToString = function toString() {
    var n = nativeNames.get(this);
    if (n !== undefined) { return 'function ' + n + '() { [native code] }'; }
    if (this === patchedToString) { return 'function toString() { [native code] }'; }
    return origToString.call(this);
  };
  Function.prototype.toString = patchedToString;
  var native = function(fn, name) { nativeNames.set(fn, name); return fn; };
  var noop = function() {};

  // ---- window.chrome ----
  if (!window.chrome) {
    var app = {
      isInstalled: false,
      InstallState: {DISABLED: 'disabled', INSTALLED: 'installed', NOT_INSTALLED: 'not_installed'},
      RunningState: {CANNOT_RUN: 'cannot_run', READY_TO_RUN: 'ready_to_run', RUNNING: 'running'},
      getDetails: native(function() { return null; }, 'getDetails'),
      getIsInstalled: native(noop, 'getIsInstalled'),
      install: native(noop, 'install'),
      installState: native(function() { return 'not_installed'; }, 'installState'),
      runningState: native(function() { return 'running'; }, 'runningState')
    };
    var csi = native(function() {
      return {startE: Date.now(), onloadT: Date.now(), pageT: 1234, tran: 15};
    }, 'csi');
    var loadTimes = native(function() {
      var t = Date.now() / 1000;
      return {
        requestTime: t, startLoadTime: t, commitLoadTime: t,
        finishDocumentLoadTime: t, finishLoadTime: t,
        firstPaintTime: t, firstPaintAfterLoadTime: 0,
        navigationType: 'Other', wasFetchedViaSpdy: false,
        wasNpnNegotiated: true, npnNegotiatedProtocol: 'h2',
        wasAlternateProtocolAvailable: false, connectionInfo: 'h2'
      };
    }, 'loadTimes');
    var runtime = {
      OnInstalledReason: {CHROME_UPDATE: 'chrome_update', INSTALL: 'install',
        SHARED_MODULE_UPDATE: 'shared_module_update', UPDATE: 'update'},
      OnRestartRequiredReason: {APP_UPDATE: 'app_update', OS_UPDATE: 'os_update', PERIODIC: 'periodic'},
      PlatformArch: {ARM: 'arm', ARM64: 'arm64', MIPS: 'mips', MIPS64: 'mips64', X86_32: 'x86_32', X86_64: 'x86_64'},
      PlatformNaclArch: {ARM: 'arm', MIPS: 'mips', MIPS64: 'mips64', X86_32: 'x86_32', X86_64: 'x86_64'},
      PlatformOs: {ANDROID: 'android', CROS: 'cros', LINUX: 'linux', MAC: 'mac', OPENBSD: 'openbsd', WIN: 'win'},
      RequestUpdateCheckStatus: {NO_UPDATE: 'no_update', THROTTLED: 'throttled', UPDATE_AVAILABLE: 'update_available'},
      connect: native(function() {
        return {disconnect: noop, postMessage: noop, onMessage: {addListener: noop}};
      }, 'connect'),
      sendMessage: native(noop, 'sendMessage')
    };
    var chromeObj = {app: app, csi: csi, loadTimes: loadTimes, runtime: runtime};
    try {
      Object.defineProperty(window, 'chrome', {
        value: chromeObj, writable: true, enumerable: true, configurable: true
      });
    } catch (e) {
      window.chrome = chromeObj;
    }
  }

  // ---- navigator.plugins / mimeTypes / pdfViewerEnabled ----
  // HTML 规范：支持内嵌 PDF 的浏览器 navigator.plugins 固定返回 5 个标准
  // 插件（PDF Viewer / Chrome PDF Viewer / Chromium PDF Viewer /
  // Microsoft Edge PDF Viewer / WebKit built-in PDF），mimeTypes 返回
  // application/pdf + text/pdf 两个。Chrome 95+ 全平台如此；Android
  // WebView 不支持内嵌 PDF → 空（0/0），是与 Chrome 的显著指纹差异。
  // 借用真实存在的 PluginArray/Plugin/MimeTypeArray/MimeType 原型
  // （WebView 实现了这些接口，只是数据为空），instanceof 与 toStringTag
  // 天然正确；属性以不可枚举方式定义（规范：命名/索引属性不可枚举）。
  if (navigator.plugins && navigator.plugins.length === 0) {
    var mimePdfProps = {type: 'application/pdf', suffixes: 'pdf', description: 'Portable Document Format'};
    var mimeTextProps = {type: 'text/pdf', suffixes: 'pdf', description: 'Portable Document Format'};
    var pluginDefs = [
      {name: 'PDF Viewer', filename: 'internal-pdf-viewer'},
      {name: 'Chrome PDF Viewer', filename: 'internal-pdf-viewer'},
      {name: 'Chromium PDF Viewer', filename: 'internal-pdf-viewer'},
      {name: 'Microsoft Edge PDF Viewer', filename: 'internal-pdf-viewer'},
      {name: 'WebKit built-in PDF', filename: 'internal-pdf-viewer'}
    ];
    var mimeArr = Object.create(typeof MimeTypeArray !== 'undefined'
        ? MimeTypeArray.prototype : Object.prototype);
    var pluginArr = Object.create(typeof PluginArray !== 'undefined'
        ? PluginArray.prototype : Object.prototype);
    var defProp = function(o, k, v, en) {
      try { Object.defineProperty(o, k, {value: v, enumerable: en, configurable: true, writable: false}); } catch (e) {}
    };
    for (var pi = 0; pi < pluginDefs.length; pi++) {
      var pd = pluginDefs[pi];
      var mimes = [];
      for (var mi = 0; mi < 2; mi++) {
        var mp = mi === 0 ? mimePdfProps : mimeTextProps;
        var mt = Object.create(typeof MimeType !== 'undefined'
            ? MimeType.prototype : Object.prototype);
        Object.defineProperty(mt, 'type', {value: mp.type, enumerable: true});
        Object.defineProperty(mt, 'suffixes', {value: mp.suffixes, enumerable: true});
        Object.defineProperty(mt, 'description', {value: mp.description, enumerable: true});
        mimes.push(mt);
        // navigator.mimeTypes 取首个插件的同名 mimeType 实例（真实
        // Chrome 中 mimeTypes[0].enabledPlugin = 'PDF Viewer'）。
        if (pi === 0) {
          defProp(mimeArr, mi === 0 ? '0' : '1', mt, false);
          defProp(mimeArr, mp.type, mt, false);
        }
      }
      var pl = Object.create(typeof Plugin !== 'undefined'
          ? Plugin.prototype : Object.prototype);
      Object.defineProperty(pl, 'name', {value: pd.name, enumerable: true});
      Object.defineProperty(pl, 'filename', {value: pd.filename, enumerable: true});
      Object.defineProperty(pl, 'description', {value: 'Portable Document Format', enumerable: true});
      Object.defineProperty(pl, 'length', {value: 2, enumerable: false});
      defProp(pl, '0', mimes[0], false);
      defProp(pl, '1', mimes[1], false);
      Object.defineProperty(mimes[0], 'enabledPlugin', {value: pl, enumerable: true});
      Object.defineProperty(mimes[1], 'enabledPlugin', {value: pl, enumerable: true});
      defProp(pl, 'item', native(function(i) { return this[i] || null; }, 'item'), false);
      defProp(pl, 'namedItem', native(function(n) { return this[n] || null; }, 'namedItem'), false);
      defProp(pluginArr, String(pi), pl, false);
      // 命名属性可枚举：经典插件探测依赖 for-in 遍历。
      Object.defineProperty(pluginArr, pd.name, {value: pl, enumerable: true, configurable: true, writable: false});
    }
    Object.defineProperty(pluginArr, 'length', {value: pluginDefs.length, enumerable: false});
    defProp(pluginArr, 'item', native(function(i) { return this[i] || null; }, 'item'), false);
    defProp(pluginArr, 'namedItem', native(function(n) { return this[n] || null; }, 'namedItem'), false);
    defProp(pluginArr, 'refresh', native(noop, 'refresh'), false);
    Object.defineProperty(mimeArr, 'length', {value: 2, enumerable: false});
    defProp(mimeArr, 'item', native(function(i) { return this[i] || null; }, 'item'), false);
    defProp(mimeArr, 'namedItem', native(function(n) { return this[n] || null; }, 'namedItem'), false);
    try {
      Object.defineProperty(Navigator.prototype, 'plugins', {
        get: native(function() { return pluginArr; }, 'get plugins'),
        configurable: true
      });
      Object.defineProperty(Navigator.prototype, 'mimeTypes', {
        get: native(function() { return mimeArr; }, 'get mimeTypes'),
        configurable: true
      });
      Object.defineProperty(Navigator.prototype, 'pdfViewerEnabled', {
        get: native(function() { return true; }, 'get pdfViewerEnabled'),
        configurable: true
      });
    } catch (e) {
      try {
        Object.defineProperty(navigator, 'plugins', {
          get: native(function() { return pluginArr; }, 'get plugins'),
          configurable: true
        });
        Object.defineProperty(navigator, 'mimeTypes', {
          get: native(function() { return mimeArr; }, 'get mimeTypes'),
          configurable: true
        });
        Object.defineProperty(navigator, 'pdfViewerEnabled', {
          get: native(function() { return true; }, 'get pdfViewerEnabled'),
          configurable: true
        });
      } catch (e2) {}
    }
  }

  // ---- navigator.share（Chrome Android 有、WebView 无）----
  if (typeof navigator.share === 'undefined') {
    try {
      Object.defineProperty(Navigator.prototype, 'share', {
        value: native(function share(data) {
          // 真实 Chrome 无用户手势时以 NotAllowedError 拒绝；页面
          // 正常流程极少实际调用，反爬主要探测其存在性。
          return Promise.reject(new DOMException(
            'The request is not allowed by the user agent or the platform ' +
            'in the current context.', 'NotAllowedError'));
        }, 'share'),
        writable: true, enumerable: true, configurable: true
      });
    } catch (e) {}
  }

  // ---- Notification（Chrome Android 有、WebView 无）----
  // Android Chrome 对未安装 PWA 的普通站点 Notification.permission 固定
  // 为 'denied'（通知权限需安装 PWA 后授予）；WebView 干脆没有
  // window.Notification，typeof 检查是反爬的经典采集项。
  if (typeof Notification === 'undefined') {
    var NotifCtor = function Notification(title, options) {
      throw new TypeError("Failed to construct 'Notification': Illegal constructor.");
    };
    NotifCtor.prototype = Object.create(typeof EventTarget !== 'undefined'
        ? EventTarget.prototype : Object.prototype);
    Object.defineProperty(NotifCtor.prototype, 'constructor',
        {value: NotifCtor, writable: true, configurable: true});
    Object.defineProperty(NotifCtor, 'permission', {
      get: native(function() { return 'denied'; }, 'get permission'),
      enumerable: false, configurable: true
    });
    Object.defineProperty(NotifCtor, 'maxActions', {
      get: native(function() { return 2; }, 'get maxActions'),
      enumerable: false, configurable: true
    });
    NotifCtor.requestPermission = native(function(callback) {
      var p = Promise.resolve('denied');
      if (typeof callback === 'function') { p.then(callback); }
      return p;
    }, 'requestPermission');
    try {
      Object.defineProperty(window, 'Notification', {
        value: NotifCtor, writable: true, enumerable: false, configurable: true
      });
    } catch (e) { window.Notification = NotifCtor; }
  }

  // ---- navigator.getInstalledRelatedApps（Chrome Android 有、WebView 无）----
  if (typeof navigator.getInstalledRelatedApps === 'undefined') {
    try {
      Object.defineProperty(Navigator.prototype, 'getInstalledRelatedApps', {
        value: native(function getInstalledRelatedApps() {
          return Promise.resolve([]);
        }, 'getInstalledRelatedApps'),
        writable: true, enumerable: true, configurable: true
      });
    } catch (e) {}
  }

  // ---- PWA 安装事件（Chrome Android 有、WebView 无）----
  // window.onbeforeinstallprompt / onappinstalled 是 Chrome 的
  // [LegacyUnforgeable] 自有属性（in 检查即可区分 WebView）。
  try {
    if (!('onbeforeinstallprompt' in window)) {
      Object.defineProperty(window, 'onbeforeinstallprompt',
          {value: null, writable: true, enumerable: true, configurable: true});
    }
    if (!('onappinstalled' in window)) {
      Object.defineProperty(window, 'onappinstalled',
          {value: null, writable: true, enumerable: true, configurable: true});
    }
    if (typeof window.BeforeInstallPromptEvent === 'undefined') {
      var BipeCtor = function BeforeInstallPromptEvent(type, eventInitDict) {
        throw new TypeError(
            "Failed to construct 'BeforeInstallPromptEvent': Illegal constructor.");
      };
      BipeCtor.prototype = Object.create(typeof Event !== 'undefined'
          ? Event.prototype : Object.prototype);
      Object.defineProperty(BipeCtor.prototype, 'constructor',
          {value: BipeCtor, writable: true, configurable: true});
      Object.defineProperty(window, 'BeforeInstallPromptEvent', {
        value: BipeCtor, writable: true, enumerable: false, configurable: true
      });
    }
  } catch (e) {}

  // ---- permissions.query 与 Notification.permission 一致性 ----
  // 真实浏览器中 Notification.permission 与 permissions.query({name:
  // 'notifications'}).state 永远一致，两者矛盾是「补环境」的经典破绽
  //（headless Chrome 曾因此被抓）。WebView 的 query 对 notifications 可能
  // 抛错，这里统一为 'denied'，其余权限名原样透传。
  try {
    if (typeof Permissions !== 'undefined' && Permissions.prototype &&
        Permissions.prototype.query) {
      var origQuery = Permissions.prototype.query;
      Permissions.prototype.query = native(function query(desc) {
        if (desc && desc.name === 'notifications') {
          var st = Object.create(typeof PermissionStatus !== 'undefined'
              ? PermissionStatus.prototype : Object.prototype);
          Object.defineProperty(st, 'state', {
            get: native(function() { return 'denied'; }, 'get state'),
            configurable: true
          });
          Object.defineProperty(st, 'onchange', {
            get: native(function() { return null; }, 'get onchange'),
            set: noop, configurable: true
          });
          return Promise.resolve(st);
        }
        return origQuery.apply(this, arguments);
      }, 'query');
    }
  } catch (e) {}
})();
''';
}
