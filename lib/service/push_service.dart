import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:town_pass/page/city_service/model/my_service_model.dart';
import 'package:town_pass/service/assistive_backend_service.dart';
import 'package:town_pass/service/data_authorization_service.dart';
import 'package:town_pass/service/notification_service.dart';
import 'package:town_pass/service/shared_preferences_service.dart';
import 'package:town_pass/util/tp_route.dart';
import 'package:town_pass/util/tp_web_view.dart';

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

  /// 服務公告用 topic：登記推播裝置時一起訂閱。
  static const String noticeTopic = 'assistive-notice';

  /// 向後端登記過的 token（換 token 時要先移除舊的，撤回授權時要移除）。
  static const String _registeredKey = 'assistive_push_registered_token';

  bool _ready = false;
  bool get isReady => _ready;

  /// Firebase Installation ID（FID）：這支手機在 FCM 的推播目標，後端以它當 token 送出。
  String? _installationId;
  final StreamController<String> _registrations = StreamController<String>.broadcast();

  Future<PushService> init() async {
    _watchAuthorization();
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
      FirebaseMessaging.instance.onRegistered.listen((id) {
        _installationId = id;
        _registrations.add(id);
        // 這支手機的 FID 換了：已經登記過的話，悄悄用新的重新登記。
        final String? registered = _prefs.getString(_registeredKey);
        if (registered != null && registered != id) {
          registerDevice(askPermission: false);
        }
      });
      FirebaseMessaging.onMessage.listen(_showInForeground);
      FirebaseMessaging.onMessageOpenedApp.listen(_openMessage);
    } catch (error) {
      // Firebase 設定不正確時不能讓整個 App 打不開。
      debugPrint('Push disabled: $error');
    }
    return this;
  }

  SharedPreferences get _prefs => Get.find<SharedPreferencesService>().instance;

  void _watchAuthorization() {
    // 使用者在「歷程與授權管理」撤回推播授權：請後端不要再推播到這支手機。
    ever(Get.find<DataAuthorizationService>().records, (_) {
      final String origin = DataAuthorizationService.originOf(
        MyServiceItemId.assistiveBooking.item.destinationUrl,
      );
      final bool granted = Get.find<DataAuthorizationService>().records.any(
            (r) => r.origin == origin && r.scope == DataScope.push && r.decision == AuthDecision.granted,
          );
      if (!granted) {
        unregisterDevice();
      }
    });
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
      return await _registeredId();
    } catch (error) {
      debugPrint('Push token unavailable: $error');
      return null;
    }
  }

  /// 向 FCM 註冊並取得 Installation ID；已經註冊過就直接用記下來的（更換時 onRegistered 會再通知）。
  Future<String?> _registeredId() async {
    if (_installationId != null) {
      return _installationId;
    }
    await FirebaseMessaging.instance.register();
    if (_installationId != null) {
      return _installationId;
    }
    try {
      return await _registrations.stream.first.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      return null;
    }
  }

  /// 向後端登記這支手機，並訂閱服務公告。成功回傳 true；拿不到 token（系統拒絕通知、沒有 Firebase）或後端連不上回傳 false。
  /// [askPermission] 為 false 時不會跳出系統的通知權限視窗。
  Future<bool> registerDevice({required bool askPermission}) async {
    final String? token = await this.token(askPermission: askPermission);
    if (token == null) {
      return false;
    }
    final backend = Get.find<AssistiveBackendService>();
    try {
      final String? previous = _prefs.getString(_registeredKey);
      if (previous != null && previous != token) {
        await backend.unregisterDevice(previous).catchError((_) {});
      }
      await backend.registerDevice(token);
      await _prefs.setString(_registeredKey, token);
    } on AssistiveApiException catch (error) {
      debugPrint('Push device registration failed: $error');
      return false;
    }
    if (_ready) {
      try {
        await FirebaseMessaging.instance.subscribeToTopic(noticeTopic);
      } catch (error) {
        debugPrint('Subscribe $noticeTopic failed: $error');
      }
    }
    return true;
  }

  /// 請後端移除這支手機（撤回授權或關閉通知時）。
  Future<void> unregisterDevice() async {
    final String? token = _prefs.getString(_registeredKey);
    if (token == null) {
      return;
    }
    await _prefs.remove(_registeredKey);
    try {
      await Get.find<AssistiveBackendService>().unregisterDevice(token);
    } on AssistiveApiException catch (error) {
      // 連不上：推播失敗時後端會自己移除失效的 token。
      debugPrint('Push device removal failed: $error');
    }
    if (_ready) {
      try {
        await FirebaseMessaging.instance.unsubscribeFromTopic(noticeTopic);
      } catch (error) {
        debugPrint('Unsubscribe $noticeTopic failed: $error');
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
      await _openMessage(message);
    }
  }

  /// 同一則通知只開一次：冷啟動時 onMessageOpenedApp 與 getInitialMessage 可能各通知一次。
  String? _lastOpenedMessageId;
  Future<void> _openMessage(RemoteMessage message) async {
    final id = message.messageId;
    if (id != null && id == _lastOpenedMessageId) {
      return;
    }
    // 真的開成功才記下來；太早（導覽器還沒好）被略過的話，後面的 getInitialMessage 還要再開一次。
    if (await open(message.data)) {
      _lastOpenedMessageId = id;
    }
  }

  /// 只把使用者不在畫面上也需要知道的非同步消息顯示成通知：到貨、取貨期限當天提醒、中心確認。
  /// 預約成功、取消這類使用者自己剛做完的事，網頁已經用彈窗告知；後端就算推了（舊版後端會推），這裡也不再跳通知。
  static const Set<String> shownTypes = {
    'stock.arrived',
    'reservation.pickup_reminder',
    'reservation.confirmed',
  };

  /// 前景時系統不會顯示 FCM 通知，改用本機通知顯示，點了一樣會開對應頁面。
  Future<void> _showInForeground(RemoteMessage message) async {
    final notification = message.notification;
    if (notification == null || !shownTypes.contains(message.data['type'])) {
      return;
    }
    await NotificationService.showNotification(
      title: notification.title,
      content: notification.body,
      channelId: NotificationService.assistiveChannelId,
      payload: jsonEncode(message.data),
      tag: message.data['type'] == 'stock.arrived' ? arrivalTag('${message.data['variant_id']}') : null,
    );
  }

  /// 到貨通知在通知列上的識別；登記取消或已經預約到這個品項時，用它把通知收掉。
  static String arrivalTag(String variantId) => 'assistive.arrival.$variantId';

  /// 依通知帶的資料開啟輔具預約：有預約編號就開那一筆，到貨通知直接開這件輔具的預約（選中心），其餘開首頁。
  static Future<bool> open(Map<String, dynamic> data) async {
    final base = MyServiceItemId.assistiveBooking.item.destinationUrl;
    // App 還沒畫出第一個畫面（冷啟動）時 GetX 沒有導覽器可用；那種情況由 openInitialMessage 負責。
    if (base.isEmpty || Get.key.currentState == null) {
      return false;
    }
    final reservationId = data['reservation_id'];
    final variantId = data['variant_id'];
    // 到貨通知：直接帶著這件輔具到「選中心」，選完就是確認資料，不用先到預約查詢再按一次預約。
    final path = reservationId is String && reservationId.isNotEmpty
        ? '/reservations/${Uri.encodeComponent(reservationId)}'
        : data['type'] == 'stock.arrived'
            ? (variantId is String && variantId.isNotEmpty
                ? '/borrow/quick/${Uri.encodeComponent(variantId)}'
                : '/reservations')
            : '';
    // GetX 預設不會重複開同一個路由；使用者正好在輔具預約裡時，仍要疊開通知指向的那一頁。
    // toNamed 要等頁面關掉才會結束，這裡不等，才能立刻回報「已經開了」。
    unawaited(Get.toNamed(
      TPRoute.webView,
      arguments: WebViewArgument(url: '$base$path'),
      preventDuplicates: false,
    ));
    return true;
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
