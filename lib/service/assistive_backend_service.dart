import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:town_pass/page/city_service/model/my_service_model.dart';
import 'package:town_pass/service/data_authorization_service.dart';

class AssistiveApiException implements Exception {
  const AssistiveApiException(this.status, {this.code, this.fields = const []});

  /// 0 = 連不上（逾時、沒有網路）
  final int status;
  final String? code;
  final List<String> fields;

  /// 後端不認得這個信箱（資料被清掉、換了環境）
  bool get isUnknownMailbox =>
      (status == 401 && code == 'BAD_KEY') || (status == 422 && fields.contains('mailbox_id'));

  @override
  String toString() => 'AssistiveApiException($status $code)';
}

class AssistiveSubscription {
  const AssistiveSubscription({
    required this.id,
    required this.variantId,
    required this.status,
    this.categoryId,
    this.createdAt,
    this.arrivedAt,
  });

  final String id;
  final String variantId;
  final String? categoryId;

  /// waiting 等待中、arrived 已到貨
  final String status;
  final String? createdAt;
  final String? arrivedAt;

  factory AssistiveSubscription.fromJson(Map<String, dynamic> json) => AssistiveSubscription(
        id: '${json['id']}',
        variantId: '${json['variant_id']}',
        categoryId: json['category_id']?.toString(),
        status: '${json['status']}',
        createdAt: json['created_at']?.toString(),
        arrivedAt: json['arrived_at']?.toString(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'variant_id': variantId,
        'category_id': categoryId,
        'status': status,
        'created_at': createdAt,
        'arrived_at': arrivedAt,
      };
}

class _Mailbox {
  const _Mailbox(this.id, this.key);
  final String id;
  final String key;
}

/// 輔具預約後端（/assistive/v1）的信箱、推播裝置與到貨通知。
///
/// 信箱金鑰只存在這裡（系統的安全儲存），不交給網頁；網頁只能拿到信箱 id，
/// 到貨通知的新增、取消、列表都由 App 代為呼叫。
class AssistiveBackendService extends GetxService {
  /// 後端網址。預設是 Android 模擬器上連到開發機的位址；真機建置用 --dart-define=ASSISTIVE_API_BASE=... 覆蓋。
  static const String baseUrl = String.fromEnvironment(
    'ASSISTIVE_API_BASE',
    defaultValue: 'http://10.0.2.2:8000/assistive/v1',
  );

  static const String _idKey = 'assistive_mailbox_id';
  static const String _secretKey = 'assistive_mailbox_key';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final http.Client _client = http.Client();

  _Mailbox? _mailbox;
  Future<_Mailbox>? _creating;

  Future<AssistiveBackendService> init() async => this;

  /// 只有輔具預約自己的網頁可以用 assistive_* 訊息，避免其他網頁取得信箱。
  static bool isServiceOrigin(WebUri? origin) {
    final String expected = DataAuthorizationService.originOf(
      MyServiceItemId.assistiveBooking.item.destinationUrl,
    );
    return expected.isNotEmpty && origin?.origin == expected;
  }

  Future<String> mailboxId() async => (await _ensureMailbox()).id;

  /// 信箱不能用了（後端不認得）時建立新的。舊的通知與到貨通知登記找不回來。
  Future<String> renewMailbox() async {
    _mailbox = null;
    try {
      await _storage.delete(key: _idKey);
      await _storage.delete(key: _secretKey);
    } catch (error) {
      debugPrint('Assistive mailbox storage reset failed: $error');
    }
    return mailboxId();
  }

  // ---- 推播裝置 ----

  Future<void> registerDevice(String token) => _authed((box) => _send(
        'POST',
        '/devices',
        body: {'mailbox_id': box.id, 'platform': 'fcm', 'token': token},
        key: box.key,
      ));

  Future<void> unregisterDevice(String token) => _authed((box) => _send(
        'DELETE',
        '/devices?mailbox_id=${Uri.encodeQueryComponent(box.id)}',
        body: {'token': token},
        key: box.key,
      ));

  // ---- 到貨通知 ----

  Future<List<AssistiveSubscription>> subscriptions() => _authed((box) async {
        final data = await _send(
          'GET',
          '/subscriptions?mailbox_id=${Uri.encodeQueryComponent(box.id)}',
          key: box.key,
        );
        return (data as List)
            .map((e) => AssistiveSubscription.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      });

  /// 新增到貨通知；同一類已經有等待中的會丟出 DUPLICATE_WAITLIST。
  Future<AssistiveSubscription> subscribe(String variantId) => _authed((box) async {
        final data = await _send(
          'POST',
          '/subscriptions',
          body: {'mailbox_id': box.id, 'variant_id': variantId},
          key: box.key,
        );
        return AssistiveSubscription(
          id: '${(data as Map)['id']}',
          variantId: variantId,
          status: 'waiting',
        );
      });

  /// 取消這個品項的到貨通知：先找出編號再刪除。
  Future<void> unsubscribe(String variantId) async {
    final mine = (await subscriptions()).where((s) => s.variantId == variantId);
    for (final subscription in mine) {
      await _authed((box) => _send(
            'DELETE',
            '/subscriptions/${Uri.encodeComponent(subscription.id)}',
            key: box.key,
          ));
    }
  }

  // ---- 內部 ----

  Future<_Mailbox> _ensureMailbox() async {
    final cached = _mailbox;
    if (cached != null) {
      return cached;
    }
    return _creating ??= _loadOrCreate().whenComplete(() {
      _creating = null;
    });
  }

  Future<_Mailbox> _loadOrCreate() async {
    String? id;
    String? key;
    try {
      id = await _storage.read(key: _idKey);
      key = await _storage.read(key: _secretKey);
    } catch (error) {
      // 安全儲存讀不到：當作沒有，建立新的（金鑰只存在記憶體，下次開啟會再建一個）。
      debugPrint('Assistive mailbox storage unavailable: $error');
    }
    if (id != null && key != null) {
      return _mailbox = _Mailbox(id, key);
    }
    final data = await _send('POST', '/mailboxes') as Map;
    final box = _Mailbox('${data['mailbox_id']}', '${data['mailbox_key']}');
    try {
      await _storage.write(key: _idKey, value: box.id);
      await _storage.write(key: _secretKey, value: box.key);
    } catch (error) {
      debugPrint('Assistive mailbox storage write failed: $error');
    }
    return _mailbox = box;
  }

  /// 後端不認得信箱時，建立新的信箱再試一次。
  Future<T> _authed<T>(Future<T> Function(_Mailbox box) run) async {
    try {
      return await run(await _ensureMailbox());
    } on AssistiveApiException catch (error) {
      if (!error.isUnknownMailbox) {
        rethrow;
      }
      await renewMailbox();
      return run(await _ensureMailbox());
    }
  }

  Future<dynamic> _send(
    String method,
    String path, {
    Object? body,
    String? key,
  }) async {
    final request = http.Request(method, Uri.parse('$baseUrl$path'));
    request.headers['Accept'] = 'application/json';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    if (key != null) {
      request.headers['Authorization'] = 'Bearer $key';
    }

    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await _client.send(request).timeout(const Duration(seconds: 15)),
      );
    } on Exception catch (error) {
      debugPrint('Assistive backend unreachable: $error');
      throw const AssistiveApiException(0);
    }

    final String text = utf8.decode(response.bodyBytes);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return text.isEmpty ? null : jsonDecode(text);
    }
    Map? problem;
    try {
      problem = jsonDecode(text) as Map?;
    } catch (_) {
      problem = null;
    }
    throw AssistiveApiException(
      response.statusCode,
      code: problem?['code']?.toString(),
      fields: (problem?['fields'] as List?)?.map((e) => '$e').toList() ?? const [],
    );
  }
}
