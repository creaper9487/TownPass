import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:town_pass/page/city_service/model/my_service_model.dart';
import 'package:town_pass/service/notification_service.dart';
import 'package:town_pass/util/tp_route.dart';

/// 推播（Firebase Cloud Messaging）。
///
/// Firebase 專案設定不放進程式碼，建置時用 --dart-define 帶入（見 docs/push-notifications.md）。
/// 沒有帶設定時 [isReady] 為 false：App 照常運作，只是沒有推播，網頁端會退回本機通知。
class PushService extends GetxService {
  static const String _apiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const String _appId = String.fromEnvironment('FIREBASE_APP_ID');
  static const String _senderId = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
  static const String _projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const String _iosBundleId = String.fromEnvironment('FIREBASE_IOS_BUNDLE_ID');

  /// 開發用：沒有 Firebase 專案時，用這個假 token 走完「網頁 → App → 後端登記裝置」的流程。只在 debug 版有效。
  static const String _devToken = String.fromEnvironment('PUSH_DEV_TOKEN');

  /// 網頁只能訂閱 assistive- 開頭的主題，避免任意網頁替使用者訂閱不相干的主題。
  static final RegExp _allowedTopic = RegExp(r'^assistive-[a-z0-9-]{1,40}$');

  bool _ready = false;
  bool get isReady => _ready;

  Future<PushService> init() async {
    NotificationService.onTap = (payload) {
      final data = _decode(payload);
      if (data != null) {
        open(data);
      }
    };

    if (_apiKey.isEmpty || _appId.isEmpty || _senderId.isEmpty || _projectId.isEmpty) {
      return this;
    }
    try {
      await Firebase.initializeApp(
        options: FirebaseOptions(
          apiKey: _apiKey,
          appId: _appId,
          messagingSenderId: _senderId,
          projectId: _projectId,
          iosBundleId: Platform.isIOS && _iosBundleId.isNotEmpty ? _iosBundleId : null,
        ),
      );
      _ready = true;
      FirebaseMessaging.onMessage.listen(_showInForeground);
      FirebaseMessaging.onMessageOpenedApp.listen((message) => open(message.data));
    } catch (error) {
      // Firebase 設定不正確時不能讓整個 App 打不開。
      debugPrint('Push disabled: $error');
    }
    return this;
  }

  /// 取得這支手機的 FCM token；使用者在系統層級拒絕通知、或沒有設定 Firebase 時回傳 null。
  /// [askPermission] 為 false 時不會跳出系統的通知權限視窗。
  Future<String?> token({required bool askPermission}) async {
    if (!_ready) {
      return kDebugMode && _devToken.isNotEmpty ? _devToken : null;
    }
    try {
      final messaging = FirebaseMessaging.instance;
      var status = (await messaging.getNotificationSettings()).authorizationStatus;
      if (status == AuthorizationStatus.notDetermined && askPermission) {
        status = (await messaging.requestPermission()).authorizationStatus;
      }
      if (status == AuthorizationStatus.denied || status == AuthorizationStatus.notDetermined) {
        return null;
      }
      // 後端用 FCM v1 的 token 欄位送出，這裡要給的就是註冊 token；
      // 新的 register()／onRegistered 回傳的是 Installation ID，能不能直接當 token 用要用真實專案確認後再換。
      // ignore: deprecated_member_use
      return await messaging.getToken();
    } catch (error) {
      debugPrint('Push token unavailable: $error');
      return null;
    }
  }

  Future<void> subscribeTopics(Iterable<String> topics) async {
    if (!_ready) {
      return;
    }
    for (final topic in topics.where(_allowedTopic.hasMatch)) {
      try {
        await FirebaseMessaging.instance.subscribeToTopic(topic);
      } catch (error) {
        debugPrint('Subscribe $topic failed: $error');
      }
    }
  }

  /// App 是從通知點開的（App 原本被關掉）：開啟輔具預約的對應頁面。
  Future<void> openInitialMessage() async {
    if (!_ready) {
      return;
    }
    final message = await FirebaseMessaging.instance.getInitialMessage();
    if (message != null) {
      await open(message.data);
    }
  }

  /// 前景時系統不會顯示 FCM 通知，改用本機通知顯示，點了一樣會開對應頁面。
  Future<void> _showInForeground(RemoteMessage message) async {
    final notification = message.notification;
    if (notification == null) {
      return;
    }
    await NotificationService.showNotification(
      title: notification.title,
      content: notification.body,
      channelId: NotificationService.assistiveChannelId,
      payload: jsonEncode(message.data),
    );
  }

  /// 依通知帶的資料開啟輔具預約：有預約編號就開那一筆，到貨通知開預約查詢，其餘開首頁。
  static Future<void> open(Map<String, dynamic> data) async {
    final base = MyServiceItemId.assistiveBooking.item.destinationUrl;
    if (base.isEmpty) {
      return;
    }
    final reservationId = data['reservation_id'];
    final path = reservationId is String && reservationId.isNotEmpty
        ? '/reservations/${Uri.encodeComponent(reservationId)}'
        : data['type'] == 'stock.arrived'
            ? '/reservations'
            : '';
    await TPRoute.openUri(uri: '$base$path');
  }

  static Map<String, dynamic>? _decode(String? payload) {
    if (payload == null || payload.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(payload);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }
}
