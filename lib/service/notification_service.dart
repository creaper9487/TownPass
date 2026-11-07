import 'dart:async';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:get/get.dart';

class NotificationService extends GetxService {
  /// 輔具預約的通知頻道；後端推播指定的 channel_id 要和這裡一致。
  static const String assistiveChannelId = 'assistive';
  static const String _defaultChannelId = 'TownPass android notification id';

  /// 使用者點了通知時呼叫，參數是顯示通知時帶的 payload。
  static void Function(String? payload)? onTap;

  static int _id = 0;
  static final FlutterLocalNotificationsPlugin _notificationInstance = FlutterLocalNotificationsPlugin();

  Future<NotificationService> init() async {
    await _notificationInstance.getNotificationAppLaunchDetails();

    final InitializationSettings initializationSettings = InitializationSettings(
      android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );

    await _notificationInstance.initialize(
      settings: initializationSettings,
      onDidReceiveNotificationResponse: (response) => onTap?.call(response.payload),
    );

    await _notificationInstance
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            assistiveChannelId,
            '輔具預約通知',
            description: '輔具到貨、取貨期限提醒與中心確認申請',
            importance: Importance.max,
          ),
        );

    return this;
  }

  static Future<void> requestPermission() async {
    if (Platform.isAndroid) {
      await _notificationInstance.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
    } else if (Platform.isIOS) {
      await _notificationInstance.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          );
    }
  }

  static Future<void> showNotification({
    String? title,
    String? content,
    String? channelId,
    String? payload,
    String? tag,
  }) async {
    final bool isAssistive = channelId == assistiveChannelId;
    await _notificationInstance.show(
      id: _id++,
      title: title,
      body: content,
      payload: payload,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          isAssistive ? assistiveChannelId : _defaultChannelId,
          isAssistive ? '輔具預約通知' : 'TownPass android notification channel name',
          importance: Importance.max,
          priority: Priority.max,
          tag: tag,
        ),
      ),
    );
  }

  /// 收回已經用不到的通知（例如已經預約了的品項的到貨通知）：顯示時帶的 [tag] 相同的都收掉。
  /// Android 讀不到通知當初帶的 payload，所以用 tag 辨認。只收得回 App 自己顯示的通知；
  /// App 在背景時由系統直接顯示的推播沒有這個 tag，留給使用者自行清除。
  static Future<void> cancelTagged(String tag) async {
    try {
      for (final notification in await _notificationInstance.getActiveNotifications()) {
        final int? id = notification.id;
        if (id != null && notification.tag == tag) {
          await _notificationInstance.cancel(id: id, tag: tag);
        }
      }
    } catch (_) {
      // 收不掉就留著，不影響其他功能
    }
  }
}
