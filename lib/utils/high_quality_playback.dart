import 'dart:convert';
import 'dart:math' show Random;

import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/models/common/video/video_quality.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/services/logger.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/wbi_sign.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;

/// 高画质播放（第三方取流覆盖，实验性）
///
/// 参考 BiliPai-HQ 的 HighQualityPlaybackPlugin 思路实现：
/// 非大会员账号请求 1080P 以上画质时，`api.bilibili.com/x/player/wbi/playurl`
/// 会按账号权益降档。本模块把已签名的 playurl 请求 URL 与当前播放账号的
/// 登录态提交给用户自行配置的远端服务，由远端返回未降档的播放地址后，
/// 再把高画质轨道合并回原响应。
///
/// 覆盖范围（与参考油猴脚本「网盘下载助手」的两个 hook 一一对应）：
/// - 普通投稿 / 课程（`/x/player/wbi/playurl`）：`POST {server}/api/bzview2`，
///   转交已签名的 wbi GET URL（`.ugc` / `.pugv`）
/// - 番剧 / 国创 / 影视（`/ogv/player/playview` 的 POST）：`POST {server}/api/bzview3`，
///   转交该请求的 URL 与原始 body（`.pgc`）
///
/// 隐私提示：启用后会把 SESSDATA、bili_jct、buvid3 等登录凭证发送到所配置
/// 的服务地址，请只填写自己信任或自建的服务，否则存在账号泄露风险。
abstract final class HighQualityPlayback {
  /// 可选目标画质（1080P 高码率及以上）
  static const List<int> qualityOptions = [
    112, // 1080P+
    116, // 1080P60
    120, // 4K
    125, // HDR
    126, // 杜比视界
    127, // 8K
  ];

  static String get serverUrl => Pref.highQualityPlaybackServer.trim();

  static int get maxQuality => Pref.highQualityPlaybackQuality;

  /// 最近一次请求结果，用于设置页展示
  static String status = '尚未请求';

  /// 最近一次远端响应的**原始文本**，设置页可查看 / 复制（排查用）
  static String lastRawResponse = '';

  /// 最近一次发往远端的请求体（cookie 值已打码），设置页可查看 / 复制。
  /// 排查「远端返回 ignore/invalid」时，用来与浏览器脚本发出的 payload 逐字段对照。
  static String lastRequest = '';

  /// 最近一次远端错误的 `code`（`null` 表示这次没有拿到错误码），
  /// 用来判断是否值得换一套参数重试
  static int? lastErrorCode;

  /// 最近一次远端错误的 `message` 原文（`ignore` / `timeout` / `invalid` …）
  static String lastErrorMessage = '';

  /// 本次解析里每一次尝试的结果（`第 1 次（qn=116）→ code=2 ignore`），
  /// 设置页会把它放在请求体前面，方便判断是哪一次被拒、被拒的原因
  static String lastAttempts = '';

  static final List<String> _attempts = [];

  static void _record(String label) {
    _attempts.add(
      '$label → ${lastErrorCode == null ? '成功' : 'code=$lastErrorCode $lastErrorMessage'}',
    );
    lastAttempts = _attempts.join('\n');
    _log('attempt: $label -> code=$lastErrorCode message=$lastErrorMessage');
  }

  /// 与脚本里 `navigator.userAgent` 一致的桌面 Chrome UA（调试开关控制）。
  /// 脚本发出的 `ui.ua` 就是这个，服务端如果按 UA 区分「网页」/「App」，
  /// 换成它才能和浏览器那份请求一致。
  static const String desktopUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36';

  static String get _ua =>
      Pref.highQualityPlaybackDesktopUa ? desktopUa : BrowserUa.pc;

  /// 用**播放账号**的 cookie 现取一次 nav（等级 / 硬币 / 大会员状态）。
  /// `Pref.userInfoCache` 是登录时缓存的，可能是旧值甚至缺字段（等级会退化成
  /// 0），而脚本每次都从 nav 现取，所以这里对齐成现取。
  static Map<String, dynamic>? _navInfo;
  static bool _navTried = false;

  /// 浏览器 cookie 里有、App 的 cookie 罐子里没有的字段（`buvid4` / `_uuid`
  /// / `b_nut` …）。服务端把请求转给 B 站时，这些越像网页越不容易被风控，
  /// 缺了就可能被折算成 `ignore`。值都来自 B 站自己的接口或本地生成。
  static Map<String, String> _webCookies = const {};
  static bool _webCookieTried = false;

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      // 解析服务在番剧上偶尔会慢一些（服务自身也有超时兜底）
      receiveTimeout: const Duration(seconds: 30),
      headers: {'user-agent': BrowserUa.pc},
    ),
  );

  static String qualityDesc(int code) => VideoQuality.fromCode(code).desc;

  /// 构造远端服务需要的完整 URL：`https://api.bilibili.com<api>?<query>`
  static String buildRequestUrl(
    Map<String, dynamic> params, {
    String api = Api.ugcUrl,
  }) {
    return Uri.https(
      'api.bilibili.com',
      api,
      params.map((key, value) => MapEntry(key, '$value')),
    ).toString();
  }

  /// 普通投稿：`POST {server}/api/bzview2`，转交已签名的 GET URL
  static Future<void> apply(
    PlayUrlModel data, {
    required String signedUrl,
    required int requestedQn,
    String source = 'ugc',
    bool isPreview = false,
  }) {
    return _apply(
      data,
      requestedQn: requestedQn,
      source: source,
      isPreview: isPreview,
      fetch: () => _fetch(signedUrl, requestedQn: requestedQn),
    );
  }

  /// 番剧 / 国创 / 影视（PGC）：`POST {server}/api/bzview3`
  ///
  /// 与参考脚本的 `bzview3` hook 一致——**原样转交网页自己那份 playview 请求**：
  /// - [url]：`POST https://api.bilibili.com/ogv/player/playview` 加上网页那 5 个 query
  ///   参数（`x-bili-locale-json` / `csrf` / `x-bili-device-req-json` / `w_rid` / `wts`）。
  ///   取值必须与网页那一份相同，否则 `w_rid` 签名算不出来（服务端会判 invalid）；
  /// - [body]：该请求的 POST body **原文**（`video_index` 的 ogv_season_id/ogv_episode_id、
  ///   `video_param.qn`、`player_param`、`exp_info` 都在 body 里，缺了它会被判 timeout）。
  ///
  /// [areaLimit] 对应脚本里的 `AreaLimitPanel`：原响应是否带「地区限制」，
  /// 为 true 时远端会走港澳台（iic）通道。
  static Future<void> applyPgc(
    PlayUrlModel data, {
    required String url,
    String? body,
    required int requestedQn,
    bool areaLimit = false,
    bool isPreview = false,
  }) {
    return _apply(
      data,
      requestedQn: requestedQn,
      source: 'pgc',
      isPreview: isPreview,
      areaLimit: areaLimit,
      fetch: () => _fetchPgc(url: url, body: body, areaLimit: areaLimit),
    );
  }

  /// 本地取流拿不到任何可播放资源时（非会员的会员专享剧集会被 B 站判成
  /// 「需要大会员」，连 `video_info` 都不给），把远端返回的整份结果直接
  /// 当成本机取流结果——参考脚本就是这么整份替换响应的。
  ///
  /// 返回 null 表示远端也没给出可用结果，调用方继续走原来的错误处理。
  static Future<PlayUrlModel?> resolveWhole(
    String signedUrl, {
    required int requestedQn,
    String source = 'ugc',
  }) async {
    if (!_canRequest(requestedQn)) return null;
    _setStatus('请求中…');
    _log('resolve($source) qn=$requestedQn：本地无可播放流，改由远端整份提供');
    try {
      return _usable(await _fetch(signedUrl, requestedQn: requestedQn));
    } catch (e) {
      _setStatus('失败：$e');
      return null;
    }
  }

  /// [resolveWhole] 的番剧 / 国创 / 影视版本（走 bzview3）
  static Future<PlayUrlModel?> resolveWholePgc({
    required String url,
    String? body,
    required int requestedQn,
    bool areaLimit = false,
  }) async {
    if (!_canRequest(requestedQn, areaLimit: areaLimit)) return null;
    _setStatus('请求中…');
    _log('resolve(pgc) qn=$requestedQn：本地无可播放流，改由远端整份提供');
    try {
      return _usable(
        await _fetchPgc(url: url, body: body, areaLimit: areaLimit),
      );
    } catch (e) {
      _setStatus('失败：$e');
      return null;
    }
  }

  /// 是否该向远端服务发起请求（功能开关 / 服务地址 / 画质 / 会员状态）
  ///
  /// [areaLimit] 为番剧 / 影视的「地区限制」解锁：这类请求是为了拿到本地根本
  /// 播不了的流（地区不可见），与画质无关，所以不受 1080P 下限约束，否则在
  /// 低画质下会被直接跳过，表现为「脚本能解锁、App 不能解锁」。
  static bool _canRequest(int requestedQn, {bool areaLimit = false}) {
    if (!Pref.enableHighQualityPlayback) return false;
    if (serverUrl.isEmpty) {
      status = '未配置服务地址';
      return false;
    }
    // 地区限制解锁与画质无关，任意画质都应放行
    if (!areaLimit) {
      // 1080P 及以下无需处理
      if (requestedQn < VideoQuality.high1080.code) return false;
      // 大会员本身即可获取高画质
      if (Pref.userInfoCache?.vipStatus == 1) return false;
    }
    return true;
  }

  /// 远端整份结果能否直接用于播放：归一化 CDN 主机、补齐画质菜单
  static PlayUrlModel? _usable(PlayUrlModel? remote) {
    if (remote == null) return null;
    final preview = _previewDesc(remote);
    final video = remote.dash?.video;
    if (video == null || video.isEmpty) {
      if (remote.durl.isNullOrEmpty) {
        _setStatus('远端未返回可用流');
        return null;
      }
      final len = _durlLength(remote.durl);
      _setStatus(
        preview ?? '成功：改用远端 durl 流（${(len / 1000).round()}s）',
      );
      return remote;
    }
    for (final item in video) {
      _fixHost(item);
    }
    if (remote.dash?.audio case final audio?) {
      for (final item in audio) {
        _fixHost(item);
      }
    }
    // controller 会直接取 `data.supportFormats!`，缺了会让播放流程崩掉
    remote.supportFormats ??= [];
    final qualities = video.availableVideoQualities.toList()
      ..sort((a, b) => b.compareTo(a));
    _ensureQualities(remote, video, qualities);
    _removeUnavailableGaps(remote);
    _setStatus(
      preview ?? '成功：改用远端完整流（${qualities.map(qualityDesc).join('、')}）',
    );
    return remote;
  }

  /// 远端给的是不是「试看片段」。
  ///
  /// 番剧 / 国创 / 影视在非会员下，B 站返回的 `timelength` 仍是**整集**时长，
  /// 但真正能播的只有前几分钟（3 分钟 / 6 分钟，视剧集而定）。所以拿可播长度
  /// （dash.duration 或 durl 各段 length 之和）和 `timelength` 一比就知道：
  /// 差出 30 秒以上，就是远端这次没拿到未降档流，而不是我们截断了播放。
  static String? _previewDesc(PlayUrlModel remote) {
    final full = remote.timeLength ?? 0;
    if (full <= 0) return null;
    final playable = _dashDurationMs(remote.dash) ?? _durlLength(remote.durl);
    if (playable <= 0) return null;
    if (full - playable < 30000) return null;
    String fmt(int ms) => '${ms ~/ 60000} 分 ${(ms % 60000) ~/ 1000} 秒';
    return '远端只给了试看片段（${fmt(playable)} / 全片 ${fmt(full)}）：'
        '这一集服务端这次没拿到未降档流，可稍后重试或换服务地址';
  }

  /// `dash.duration` 是**秒**（B 站原始字段），这里统一换成毫秒。
  /// `timelength` / `Durl.length` 都是毫秒，混用会把整集误判成 1 秒的试看片段。
  static int? _dashDurationMs(Dash? dash) {
    final seconds = dash?.duration;
    if (seconds == null || seconds <= 0) return null;
    return seconds * 1000;
  }

  /// 尝试用远端服务返回的高画质轨道覆盖 [data]（就地修改，失败时不生效）
  static Future<void> _apply(
    PlayUrlModel data, {
    required int requestedQn,
    required String source,
    required bool isPreview,
    bool areaLimit = false,
    required Future<PlayUrlModel?> Function() fetch,
  }) async {
    if (!_canRequest(requestedQn, areaLimit: areaLimit)) return;
    final localDash = data.dash;
    final hasLocalDash = localDash != null && !localDash.video.isNullOrEmpty;
    // 本地既没有 dash 也没有 durl：没有可播放资源，无从下手
    if (!hasLocalDash && data.durl.isNullOrEmpty) return;

    _setStatus('请求中…');
    _log(
      'apply($source) qn=$requestedQn preview=$isPreview '
      'timelength=${data.timeLength} dashDuration=${localDash?.duration} '
      'acceptDesc=${data.acceptDesc} quality=${data.quality} '
      'tracks=${localDash?.video?.map((e) => '${e.id}:${e.codecs}').toList()} '
      'formats=${data.supportFormats?.map((e) => e.quality).toList()}',
    );

    try {
      final remote = await fetch();
      if (remote == null) return;

      // 单位必须统一：`dash.duration` 是**秒**（B 站原始字段），`timelength`
      // 是**毫秒**。之前直接拿两者相减，番剧（本地没有 dash、回落到 timelength）
      // 会把「远端 1228 秒」当成「1228 毫秒」，判成试看片段整份丢掉，
      // 于是永远只播本地那 3 分钟试看。
      final remoteDuration = _dashDurationMs(remote.dash);
      final localDuration = localDash != null
          ? _dashDurationMs(localDash)
          : data.timeLength;
      _log('duration(ms): local=$localDuration remote=$remoteDuration');

      // 默认不比较时长：只要远端给了流就整套采纳（设置里可关掉这个开关）。
      // 关掉之后才做「远端反而更短 → 视为试看片段，保留本地完整流」的判断。
      if (!Pref.highQualityPlaybackAlwaysAccept &&
          remoteDuration != null &&
          remoteDuration > 0 &&
          localDuration != null &&
          remoteDuration < localDuration - 10000) {
        final desc =
            '远端为试看片段（${(remoteDuration / 1000).round()}s / '
            '本地 ${(localDuration / 1000).round()}s）';
        _setStatus('$desc，已忽略（可在设置里关掉「始终采用服务端流」来照单采纳）');
        return;
      }

      // 番剧 / 国创 / 影视在非大会员下只返回 durl 形式的试看片段（dash 为 null），
      // 既没有轨道可合并，画质菜单也会被 `videoInfo.dash == null` 拦成
      // 「当前视频不支持选择画质」，这里只能整套采纳远端返回的流
      if (!hasLocalDash) {
        _adoptWhole(data, remote);
        return;
      }

      // 远端拿到了更完整的流时同步时长，否则播放会被本地试看时长截断
      final fullStream =
          remoteDuration != null &&
          remoteDuration > 0 &&
          (localDuration == null || remoteDuration > localDuration);
      if (fullStream) {
        data.timeLength = remoteDuration;
        // `Dash.duration` 是秒，回写时要换回去
        localDash.duration = remoteDuration ~/ 1000;
        _log('adopt duration: $localDuration -> $remoteDuration');
      }

      final added = _merge(data, remote);
      if (added.isEmpty) {
        _setStatus(
          isPreview ? '会员专享试看：远端未提供更完整的流' : '远端未返回更高画质',
        );
        return;
      }
      _removeUnavailableGaps(data);
      final qualities = added.map(qualityDesc).join('、');
      _setStatus(
        isPreview && !fullStream
            ? '成功：新增 $qualities（会员专享试看：仅预览片段可播，整集需大会员）'
            : '成功：新增 $qualities',
      );
    } catch (e) {
      _setStatus('失败：$e');
    }
  }

  /// 本地没有 dash 时整套采纳远端返回的流。
  ///
  /// 番剧 / 国创 / 影视在非大会员下只会返回 `durl` 形式的试看片段（`dash` 为
  /// null），此时既没有轨道可以合并，画质菜单也会被 `videoInfo.dash == null`
  /// 直接拦住，因此把远端返回的 dash 当作本机取流结果使用。
  static void _adoptWhole(PlayUrlModel data, PlayUrlModel remote) {
    final remoteDash = remote.dash;
    if (remoteDash == null || remoteDash.video.isNullOrEmpty) {
      if (remote.durl.isNullOrEmpty) {
        _setStatus(
          data.dash == null && data.durl != null
              ? '会员专享试看：远端未提供更完整的流'
              : '远端未返回可用流',
        );
        return;
      }
      // 远端同样只有 durl：默认照单采纳（「始终采用服务端流」开）；
      // 关掉这个开关时，只有远端确实更长才替换
      final localLen = _durlLength(data.durl);
      final remoteLen = _durlLength(remote.durl);
      if (remoteLen <= localLen && !Pref.highQualityPlaybackAlwaysAccept) {
        final preview = _previewDesc(remote);
        _setStatus(
          preview ??
              '会员专享试看：远端未提供更完整的流'
                  '（远端 ${(remoteLen / 1000).round()}s / 本地 '
                  '${(localLen / 1000).round()}s）',
        );
        return;
      }
      data.durl = remote.durl;
      _adoptMeta(data, remote);
      _setStatus(
        _previewDesc(remote) ??
            '成功：改用远端 durl 流（${(remoteLen / 1000).round()}s）',
      );
      return;
    }

    final video = remoteDash.video!;
    for (final item in video) {
      _fixHost(item);
    }
    data
      ..dash = remoteDash
      // 已改由 dash 播放，清掉试看用的 durl，避免其它逻辑继续引用片段
      ..durl = null
      ..supportFormats ??= remote.supportFormats;
    _adoptMeta(data, remote);

    final qualities = video.availableVideoQualities.toList()
      ..sort((a, b) => b.compareTo(a));
    _ensureQualities(data, video, qualities);
    _removeUnavailableGaps(data);

    final desc = qualities.isEmpty
        ? '远端画质'
        : qualities.map(qualityDesc).join('、');
    _setStatus(_previewDesc(remote) ?? '成功：改用远端完整流（$desc）');
  }

  /// 同步远端返回的画质 / 时长等元数据
  static void _adoptMeta(PlayUrlModel data, PlayUrlModel remote) {
    data.quality = remote.quality ?? data.quality;
    data.acceptQuality = remote.acceptQuality ?? data.acceptQuality;
    data.acceptDesc = remote.acceptDesc ?? data.acceptDesc;
    data.format = remote.format ?? data.format;
    data.videoCodecid = remote.videoCodecid ?? data.videoCodecid;
    final timeLength = remote.timeLength;
    if (timeLength != null && timeLength > 0) data.timeLength = timeLength;
  }

  /// 分段流的实际总长度；试看片段的 `timelength` 仍是整集长度，不能用来比较
  static int _durlLength(List<Durl>? durl) {
    if (durl == null || durl.isEmpty) return 0;
    var total = 0;
    for (final e in durl) {
      total += e.length ?? 0;
    }
    return total;
  }

  static void _setStatus(String value) {
    status = value;
    debugPrint('HighQualityPlayback: $value');
  }

  static void _log(String value) {
    debugPrint('HighQualityPlayback: $value');
  }

  /// 与脚本里的 `box.ui` 逐字段一致：脚本只发这 7 个字段，`money` 是
  /// `parseInt` 之后的整数（小于 1 时按 0 处理），多发的字段可能被服务端判为
  /// 异常请求，所以这里不再附带 `face` / `name`。
  ///
  /// 取值来源也按脚本对齐：`mid` / `csrf` 直接取 cookie（保证与 `cookie` 字段
  /// 自洽），`level` / `money` / `vip` 用播放账号现取的 nav，取不到才退回缓存。
  static Future<Map<String, dynamic>> _ui() async {
    final account = Accounts.video;
    final jar = account.cookieJar.toJson();
    final cookie = jar.entries.map((e) => '${e.key}=${e.value}').join('; ');
    final csrf = jar['bili_jct'] ?? account.csrf;
    await _prepareIdentity(cookie, csrf);

    final nav = _navInfo;
    final cached = Pref.userInfoCache;
    final level =
        (nav?['level'] as int?) ?? cached?.levelInfo?.currentLevel ?? 0;
    final money = ((nav?['money'] as num?) ?? cached?.money ?? 0).toInt();
    final vip = (nav?['vip'] as int?) ?? (cached?.vipStatus == 1 ? 1 : 0);
    final extra = _webCookies.isEmpty
        ? ''
        : '; ${_webCookies.entries.map((e) => '${e.key}=${e.value}').join('; ')}';

    return {
      'ua': _ua,
      'mid': '${jar['DedeUserID'] ?? account.mid}',
      'vip': vip,
      'level': level,
      'money': money < 1 ? 0 : money,
      'cookie': '$cookie$extra',
      'csrf': jar['bili_jct'] ?? account.csrf,
    };
  }

  static Future<void> _prepareIdentity(String cookie, String csrf) async {
    final tasks = <Future<void>>[];
    if (!_navTried) {
      _navTried = true;
      tasks.add(_refreshNav(cookie));
    }
    if (!_webCookieTried) {
      _webCookieTried = true;
      tasks.add(_fillWebCookies(cookie, csrf));
    }
    if (tasks.isNotEmpty) await Future.wait(tasks);
  }

  static Future<void> _refreshNav(String cookie) async {
    try {
      final res = await _dio.get<dynamic>(
        'https://api.bilibili.com/x/web-interface/nav',
        options: Options(
          headers: {'cookie': cookie},
          responseType: ResponseType.plain,
        ),
      );
      final json = jsonDecode('${res.data}');
      final data = json is Map ? json['data'] : null;
      if (data is Map && data['isLogin'] == true) {
        final levelInfo = data['level_info'];
        _navInfo = {
          'level': levelInfo is Map ? levelInfo['current_level'] : null,
          'money': data['money'],
          'vip': data['vipStatus'] == 1 ? 1 : 0,
        };
        _log(
          'nav: level=${_navInfo!['level']} money=${_navInfo!['money']} '
          'vip=${_navInfo!['vip']}',
        );
      }
    } catch (e) {
      _log('nav 刷新失败（继续用本地缓存）: $e');
    }
  }

  /// 把网页端才有的 cookie 字段补上（只补缺的，已有的不动）
  static Future<void> _fillWebCookies(String cookie, String csrf) async {
    bool has(String name) => RegExp('(^|;\\s*)$name=').hasMatch(cookie);
    final extra = <String, String>{};
    if (!has('_uuid')) extra['_uuid'] = '${_genUuid()}infoc';
    if (!has('b_nut')) {
      extra['b_nut'] = '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
    }
    if (!has('CURRENT_FNVAL')) extra['CURRENT_FNVAL'] = '4048';
    if (!has('buvid4')) {
      final buvid4 = await _fetchBuvid4(cookie);
      if (buvid4 != null) extra['buvid4'] = buvid4;
    }
    if (!has('bili_ticket') && csrf.isNotEmpty) {
      final ticket = await _fetchBiliTicket(cookie, csrf);
      if (ticket != null) extra.addAll(ticket);
    }
    _webCookies = extra;
    _log('补齐网页 cookie: ${extra.keys.toList()}');
  }

  /// 网页端每次进站都会拿一张 `bili_ticket`（HMAC-SHA256 签名），浏览器那份
  /// cookie 里带着它；App 的 cookie 罐子里没有，补上后更像一次真实网页会话
  static Future<Map<String, String>?> _fetchBiliTicket(
    String cookie,
    String csrf,
  ) async {
    try {
      final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final sign = Hmac(
        sha256,
        utf8.encode('XgwSnGZ1p'),
      ).convert(utf8.encode('ts$ts')).toString();
      final res = await _dio.post<dynamic>(
        'https://api.bilibili.com/bapis/bilibili.api.ticket.v1.Ticket'
        '/GenWebTicket?key_id=ec02&hexsign=$sign&context%5Bts%5D=$ts&csrf=$csrf',
        options: Options(
          headers: {'cookie': cookie, 'referer': 'https://www.bilibili.com/'},
          responseType: ResponseType.plain,
        ),
      );
      final json = jsonDecode('${res.data}');
      final data = json is Map ? json['data'] : null;
      final ticket = data is Map ? data['ticket'] : null;
      if (ticket is String && ticket.isNotEmpty) {
        final createdAt = (data['created_at'] as num?)?.toInt() ?? ts;
        final ttl = (data['ttl'] as num?)?.toInt() ?? 259200;
        _log('bili_ticket 获取成功');
        return {
          'bili_ticket': ticket,
          'bili_ticket_expires': '${createdAt + ttl}',
        };
      }
      _log('取 bili_ticket 失败: $json');
    } catch (e) {
      _log('取 bili_ticket 异常: $e');
    }
    return null;
  }

  static Future<String?> _fetchBuvid4(String cookie) async {
    try {
      final res = await _dio.get<dynamic>(
        'https://api.bilibili.com/x/frontend/finger/spi',
        options: Options(
          headers: {'cookie': cookie},
          responseType: ResponseType.plain,
        ),
      );
      final json = jsonDecode('${res.data}');
      final data = json is Map ? json['data'] : null;
      final b4 = data is Map ? data['b_4'] : null;
      if (b4 is String && b4.isNotEmpty) {
        _log('buvid4: $b4');
        return b4;
      }
    } catch (e) {
      _log('取 buvid4 失败: $e');
    }
    return null;
  }

  /// B 站网页的 `_uuid` 形态：8-4-5-4-12 位十六进制 + 5 位数字 + `infoc`
  static String _genUuid() {
    const chars = '0123456789ABCDEF';
    final rnd = Random();
    String block(int n) =>
        List.generate(n, (_) => chars[rnd.nextInt(16)]).join();
    final digits = List.generate(5, (_) => '${rnd.nextInt(10)}').join();
    return '${block(8)}-${block(4)}-${block(5)}-${block(4)}-${block(12)}$digits';
  }

  /// 普通投稿：`POST {server}/api/bzview2`，直接转交已签名的 GET URL
  ///
  /// 实测（2026-10-23，用真实网页 cookie 对同一视频做对照）：
  /// - 「网页播放器原始参数集」→ `code 0`，能拿到 1080P+ 的 dash；
  /// - 「App 参数」或「网页精简参数」→ 秒回 `{"code":2,"message":"ignore"}`。
  ///
  /// 所以第一次就用页面原始参数集（`app_id=100` / `version_name` /
  /// `client_attr` / `session` / `x-bili-*` 那一套），只有它被判 `ignore`
  /// 时才退到网页精简参数、App 参数（`timeout` 之类换参数也没用，直接放弃）。
  static Future<PlayUrlModel?> _fetch(
    String signedUrl, {
    required int requestedQn,
  }) async {
    // 脚本会把 dm_* 这类噪音参数剔除后再交给远端
    final cleaned = signedUrl.replaceAll(RegExp(r'dm_.+?&'), '');
    final target = requestedQn < maxQuality ? requestedQn : maxQuality;

    _attempts.clear();
    lastAttempts = '';

    final ui = await _ui();
    final webQn = target < VideoQuality.high108060.code
        ? target
        : VideoQuality.high108060.code;

    // 实测结论（2026-10-23，用真实网页 cookie 对服务端做对照）：
    // 只有「页面原始参数集」会被真正处理并返回 code 0，App 参数 / 精简网页
    // 参数都会秒回 `{"code":2,"message":"ignore"}`。所以第一次就用它。
    var url = await _resign(cleaned, qn: webQn, pageLike: true);
    var remote = await _post('/api/bzview2', {'ui': ui, 'url': url});
    _record('第 1 次（qn=$webQn，页面原始参数集）');
    if (remote != null || !_shouldTryAnotherShape) return remote;

    _setStatus('远端拒绝（$lastErrorMessage），改用网页精简参数重试…');
    url = await _resign(cleaned, qn: webQn, webShape: true);
    remote = await _post('/api/bzview2', {'ui': ui, 'url': url});
    _record('第 2 次（qn=$webQn，网页精简参数）');
    if (remote != null || !_shouldTryAnotherShape) return remote;

    _setStatus('远端仍拒绝，改用 App 参数重试…');
    url = await _resign(cleaned, qn: target);
    remote = await _post('/api/bzview2', {'ui': ui, 'url': url});
    _record('第 3 次（qn=$target，App 参数）');
    if (remote != null || !_shouldTryAnotherShape) return remote;

    _setStatus('远端三次都拒绝：$lastAttempts（$accountDesc）');
    return null;
  }

  /// 只有 `ignore`（服务端按参数形状判定「不用处理」）才值得换一种参数重试；
  /// `timeout` / `fail` / `invalid` 是服务端自身或上游的问题，换参数没用，
  /// 再发只会白耗次数。
  static bool get _shouldTryAnotherShape =>
      lastErrorCode == 2 && lastErrorMessage == 'ignore';

  /// 当前「播放账号」的自述：mid / 等级 / 硬币 / 大会员。
  /// 服务端是按账号身份重放请求的，等级 0（未转正）的号很可能被直接判 ignore，
  /// 所以设置页把这里显式列出来，方便一眼确认「用的是哪个号」。
  static String get accountDesc {
    final account = Accounts.video;
    final jar = account.cookieJar.toJson();
    final nav = _navInfo;
    final cached = Pref.userInfoCache;
    final mid = '${jar['DedeUserID'] ?? account.mid}';
    final level =
        (nav?['level'] as int?) ?? cached?.levelInfo?.currentLevel ?? 0;
    final money = ((nav?['money'] as num?) ?? cached?.money ?? 0).toInt();
    final vip = (nav?['vip'] as int?) ?? (cached?.vipStatus == 1 ? 1 : 0);
    return '账号 mid=$mid 等级=$level 硬币=$money 大会员=${vip == 1 ? '是' : '否'}';
  }

  /// 改写 URL 里的 `qn`（可选换成网页播放器那份参数形状）并重新做 wbi 签名。
  ///
  /// 签名覆盖整个 query，改过参数必须重签，否则服务端/上游都会判 invalid。
  /// 网页那份的差异：没有 `voice_balance` / `cur_language`，多了
  /// `from_client=BROWSER` / `is_main_page` / `need_fragment`，
  /// 且 `isGaiaAvoided=false`、`gaia_source` 为空。
  static Future<String> _resign(
    String url, {
    required int qn,
    bool webShape = false,
    bool pageLike = false,
  }) async {
    final uri = Uri.parse(url);
    final params = <String, Object>{};
    if (pageLike) {
      params.addAll(_pageParams(uri, qn));
    } else {
      uri.queryParameters.forEach((key, value) {
        if (key == 'w_rid' || key == 'wts') return;
        if (webShape && (key == 'voice_balance' || key == 'cur_language')) {
          return;
        }
        params[key] = value;
      });
      params['qn'] = '$qn';
      if (webShape) {
        params
          ..['from_client'] = 'BROWSER'
          ..['is_main_page'] = 'true'
          ..['need_fragment'] = 'false'
          ..['isGaiaAvoided'] = 'false'
          ..['web_location'] = '1315873';
      }
    }
    final signed = await WbiSign.makSign(params);
    // 渲染必须和签名用的编码完全一致：`makSign` 用 `Uri.encodeComponent` 拼串，
    // 再用 `Uri.https(queryParameters:)` 渲染会把 `:` `,` 之类原样留下，
    // 导致 URL 里看到的 query 与签名输入不同（服务端重算签名必然失败）
    final query = signed.entries
        .map(
          (e) =>
              '${Uri.encodeComponent(e.key)}='
              '${Uri.encodeComponent('${e.value}'.replaceAll(_signFilter, ''))}',
        )
        .join('&');
    return '${uri.scheme}://${uri.authority}${uri.path}?$query';
  }

  static final RegExp _signFilter = RegExp(r"[!'()*]");

  /// 网页播放器那条 playurl 的真实参数集（取自页面 Network 里的原请求），
  /// `dm_*` 那几个按脚本的做法剔除，其余逐项照抄。服务端如果按网页参数
  /// 白名单判断「这条请求要不要处理」，缺任意一项都可能直接 ignore。
  static Map<String, Object> _pageParams(Uri uri, int qn) {
    final p = uri.queryParameters;
    String pick(String key, String fallback) {
      final v = p[key];
      return (v == null || v.isEmpty) ? fallback : v;
    }

    return {
      'avid': ?p['avid'],
      'bvid': ?p['bvid'],
      'cid': ?p['cid'],
      'qn': '$qn',
      'fnver': pick('fnver', '0'),
      'fnval': pick('fnval', '4048'),
      'fourk': pick('fourk', '1'),
      'gaia_source': '',
      'from_client': 'BROWSER',
      'is_main_page': 'true',
      'need_fragment': 'false',
      'isGaiaAvoided': 'false',
      'client_attr': '0',
      'version_name': '4.10.6',
      'app_id': '100',
      'session': _sessionId(),
      'voice_balance': '1',
      'try_look': '0',
      'web_location': '1315873',
      'x-bili-device-req-json':
          '{"platform":"web","device":"pc","mobi_app":"web_cn"}',
      'x-bili-locale-json':
          '{"c_locale":{"language":"zh","script":"Hans"},'
          '"always_translate":false}',
    };
  }

  /// 网页播放器每条 playurl 都会带一个 32 位十六进制的 `session`
  static String _sessionId() {
    final random = Random();
    const chars = '0123456789abcdef';
    return List.generate(32, (_) => chars[random.nextInt(16)]).join();
  }

  /// 番剧 / 国创 / 影视：`POST {server}/api/bzview3`
  ///
  /// 网页播放器的 playview 是 **GET**（参数全在 url、wbi 全签），此时 [body]
  /// 为 null，与脚本里 `args[1]?.body === undefined` 一致，服务端只用 url 重放。
  static Future<PlayUrlModel?> _fetchPgc({
    required String url,
    String? body,
    required bool areaLimit,
  }) async {
    _attempts.clear();
    lastAttempts = '';
    final remote = await _post('/api/bzview3', {
      'iic': areaLimit,
      'url': url,
      'body': ?body,
      'ui': await _ui(),
    });
    _record('bzview3（番剧/影视）');
    return remote;
  }

  static Future<PlayUrlModel?> _post(
    String path,
    Map<String, dynamic> payload,
  ) async {
    lastRequest = _redact(payload);
    lastErrorCode = null;
    lastErrorMessage = '';
    _log('request($path): $lastRequest');
    logger.w('HighQualityPlayback($path) 远端请求体:\n$lastRequest');
    dynamic raw;
    // 服务端回包带着 `keep-alive: timeout=5`（gunicorn），Dio 默认复用连接，
    // 隔几秒再发就会被对端 RST（`Connection reset by peer`）。这类错误重发一次
    // 基本都能过，所以这里固定「失败换连接重试一次」，并且不把异常抛给上层
    // ——取流失败只该降级，不该让整个视频播不了。
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        final res = await _dio.post<dynamic>(
          '$serverUrl$path',
          data: payload,
          options: Options(
            contentType: Headers.jsonContentType,
            responseType: ResponseType.plain,
            headers: {
              'user-agent': _ua,
              'accept': '*/*',
              'accept-language': 'zh-CN,zh;q=0.9',
              'origin': 'https://www.bilibili.com',
              'referer': 'https://www.bilibili.com/',
              // 别让对端/本地复用空闲连接
              'connection': 'close',
            },
          ),
        );
        raw = res.data;
        break;
      } on DioException catch (e) {
        _log('远端连接失败（第 $attempt 次）: ${e.type} ${e.error ?? e.message}');
        if (attempt == 2) {
          final hint = _transportHint(e);
          lastErrorCode = -1;
          lastErrorMessage = hint;
          lastRawResponse = '${e.type} ${e.error ?? e.message}';
          _setStatus('连接失败：$hint');
          return null;
        }
        await Future<void>.delayed(const Duration(milliseconds: 400));
      } catch (e) {
        _log('远端请求异常: $e');
        lastErrorCode = -1;
        lastErrorMessage = '$e';
        lastRawResponse = '$e';
        _setStatus('连接失败：$e');
        return null;
      }
    }
    final text = raw is String ? raw : jsonEncode(raw);
    lastRawResponse = text;
    _log('remote raw (${text.length} 字符): ${_clip(text, 3000)}');
    // release 下 logger 只放行 warning 及以上，用 w 才会落到 App 的「日志」里
    logger.w('HighQualityPlayback($path) 远端原始响应:\n${_clip(text, 30000)}');
    return _parse(raw);
  }

  /// 连接层错误的中文说明（这类错误跟 payload 无关，重试/换网络才有用）
  static String _transportHint(DioException e) {
    final detail = '${e.error ?? e.message ?? ''}';
    final lower = detail.toLowerCase();
    if (lower.contains('reset')) return '连接被对端重置（connection reset）';
    if (e.type == DioExceptionType.connectionTimeout ||
        lower.contains('timed out')) {
      return '连接超时';
    }
    if (lower.contains('connection refused')) {
      return '端口未开放（connection refused）';
    }
    if (lower.contains('failed host lookup') ||
        lower.contains('nodename nor servname')) {
      return '域名解析失败（检查服务地址）';
    }
    if (detail.isEmpty) return '未知连接错误（${e.type.name}）';
    return '${e.type.name}: $detail';
  }

  static String _clip(String text, int max) => text.length <= max
      ? text
      : '${text.substring(0, max)}…（共 ${text.length} 字符，已截断）';

  /// 请求体脱敏：cookie 只保留**名字**、值一律打码（避免 SESSDATA 落到日志或
  /// 设置页），其余字段原样输出，方便与浏览器脚本发出的 payload 逐字段对照。
  static String _redact(Map<String, dynamic> payload) {
    final map = Map<String, dynamic>.from(payload);
    if (map['ui'] case final Map ui) {
      final copy = Map<String, dynamic>.from(ui);
      if (copy['cookie'] case final String cookie) {
        copy['cookie'] = cookie
            .split(';')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .map((e) => '${e.split('=').first}=***')
            .join('; ');
      }
      map['ui'] = copy;
    }
    return jsonEncode(map);
  }

  /// 远端错误码/消息的人话解释：服务端 `code 2` 表示「没能完成」，真正的原因
  /// 在 message 里（timeout / invalid / fail / ignore …）。
  static String _hint(int code, String message) {
    if (code == 9) return '次数已达上限，给任意视频投币可重置';
    return switch (message) {
      'ignore' =>
        '$message（服务端判定这条请求「不用处理」，通常是 playurl 参数'
            '形状不符合它的预期；App 已按网页原始参数集发送，若仍 ignore 可稍后'
            '再试或换服务地址）',
      'timeout' => '$message（服务端请求 B 站超时）',
      'invalid' => '$message（服务端认为请求体不合法）',
      'fail' => '$message（服务端网络失败）',
      '' => '未知原因',
      _ => message,
    };
  }

  static PlayUrlModel? _parse(dynamic raw) {
    dynamic json = raw;
    if (raw is String) {
      if (raw.isEmpty) {
        _setStatus('远端返回空内容');
        return null;
      }
      try {
        json = jsonDecode(raw);
      } catch (_) {
        _setStatus('远端返回的不是合法 JSON');
        _log('remote raw: ${raw.length > 300 ? raw.substring(0, 300) : raw}');
        return null;
      }
    }
    if (json is! Map) {
      _setStatus('远端返回格式异常');
      return null;
    }

    final code = json['code'];
    if (code is int && code != 0) {
      final message = '${json['message'] ?? json['msg'] ?? ''}';
      lastErrorCode = code;
      lastErrorMessage = message;
      _setStatus('远端返回错误($code)：${_hint(code, message)}');
      _log('remote error: code=$code message=$message');
      return null;
    }

    // 兼容远端返回 { code, data }（ogv）/ { code, result }（pgc web v2）
    // 或直接返回 playurl data 几种形态
    dynamic payload = json['data'] ?? json['result'] ?? json;
    if (payload is String && payload.isNotEmpty) {
      try {
        payload = jsonDecode(payload);
      } catch (_) {
        return null;
      }
    }
    if (payload is! Map) {
      _setStatus('远端返回格式异常');
      return null;
    }

    // 兼容 ogv 形态：data.video_info.<playurl data>
    final videoInfo = payload['video_info'];
    if (videoInfo is Map) payload = videoInfo;

    final map = Map<String, dynamic>.from(payload);
    _log(
      'remote: dash=${map['dash'] != null} durl=${map['durl'] != null} '
      'acceptDesc=${map['accept_description']} '
      'quality=${map['quality']} timelength=${map['timelength']}',
    );
    if (map['dash'] == null && map['durl'] == null) {
      _setStatus('远端返回数据不完整');
      final text = raw is String ? raw : jsonEncode(raw);
      _log(
        'remote body: ${text.length > 800 ? '${text.substring(0, 800)}…' : text}',
      );
      return null;
    }
    final model = PlayUrlModel.fromJson(map);
    final dash = model.dash;
    _log(
      'remote tracks: dashDuration=${dash?.duration} '
      'video=${dash?.video?.map((e) => '${e.id}:${e.codecs}:${e.bandWidth}').toList()} '
      'audio=${dash?.audio?.map((e) => '${e.id}:${e.codecs}').toList()} '
      'durl=${model.durl?.map((e) => e.length).toList()}',
    );
    return model;
  }

  static List<int> _merge(PlayUrlModel data, PlayUrlModel remote) {
    final remoteVideo = remote.dash?.video;
    if (remoteVideo == null || remoteVideo.isEmpty) return const [];

    final target = maxQuality;
    final candidates = remoteVideo
        .where((e) => e.id <= target && (e.baseUrl?.isNotEmpty ?? false))
        .toList();
    if (candidates.isEmpty) return const [];

    final video = data.dash!.video!;
    final before = video.availableVideoQualities.toSet();
    for (final item in candidates) {
      _fixHost(item);
    }
    video.merge(candidates);
    final added = video.availableVideoQualities.difference(before).toList()
      ..sort((a, b) => b.compareTo(a));
    if (added.isEmpty) return added;

    // 补全 supportFormats / acceptQuality，让画质菜单能展示并选中新档位
    _ensureQualities(data, video, added);
    return added;
  }

  /// 补全 supportFormats 与 acceptQuality。
  ///
  /// 除了把新增档位补进画质菜单，还要修正 `codecs`——番剧试看片段的
  /// `support_formats` 里 `codecs` 是空数组，而 controller 会取它选编码格式，
  /// 空数组会让 `VideoDecodeFormatType.fromString(codecs.first)` 直接抛异常。
  static void _ensureQualities(
    PlayUrlModel data,
    List<VideoItem> video,
    Iterable<int> ids,
  ) {
    final formats = data.supportFormats ??= [];
    for (final item in formats) {
      final id = item.quality;
      if (id == null) continue;
      if (item.codecs == null || item.codecs!.isEmpty) {
        item.codecs = _codecsOf(video, id);
      }
    }
    for (final id in ids) {
      if (formats.any((e) => e.quality == id)) continue;
      final qa = VideoQuality.fromCode(id);
      formats.add(
        FormatItem(
          quality: id,
          format: qa.shortDesc,
          newDesc: qa.desc,
          displayDesc: qa.shortDesc,
          codecs: _codecsOf(video, id),
        ),
      );
    }
    formats.sort((a, b) => (b.quality ?? 0).compareTo(a.quality ?? 0));

    data.acceptQuality = {...?data.acceptQuality, ...ids}.toList()
      ..sort((a, b) => b.compareTo(a));
  }

  /// 取出某个新档位实际可用的编码格式，避免 support_formats 里出现空 codecs
  static List<String> _codecsOf(List<VideoItem> video, int id) {
    final codecs = <String>{};
    for (final e in video) {
      if (e.quality.code != id) continue;
      final codec = e.codecs;
      if (codec != null && codec.isNotEmpty) codecs.add(codec);
    }
    return codecs.isEmpty ? const ['avc1'] : codecs.toList();
  }

  /// 远端返回的部分 CDN 主机名（mirrorcosov）可能不可用，按参考实现归一化
  static void _fixHost(BaseItem item) {
    item.baseUrl = _fixHostStr(item.baseUrl);
    final backupUrl = item.backupUrl;
    if (backupUrl != null) {
      for (var i = 0; i < backupUrl.length; i++) {
        backupUrl[i] = _fixHostStr(backupUrl[i])!;
      }
    }
  }

  static String? _fixHostStr(String? url) =>
      url?.replaceFirst('-mirrorcosov.', '-mirrorcos.');

  /// 移除低于最高可用画质、但实际不可用的画质项，避免播放时额外的补流请求
  static void _removeUnavailableGaps(PlayUrlModel data) {
    final video = data.dash?.video;
    final formats = data.supportFormats;
    if (video == null || video.isEmpty || formats == null || formats.isEmpty) {
      return;
    }
    final highest = video.first.id;
    final available = video.availableVideoQualities;
    formats.removeWhere((e) {
      final quality = e.quality;
      return quality != null &&
          quality < highest &&
          !available.contains(quality);
    });
  }
}
