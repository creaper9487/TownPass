import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart';
import 'package:town_pass/gen/assets.gen.dart';
import 'package:town_pass/service/account_service.dart';
import 'package:town_pass/service/assistive_backend_service.dart';
import 'package:town_pass/service/data_authorization_service.dart';
import 'package:town_pass/service/device_service.dart';
import 'package:town_pass/service/geo_locator_service.dart';
import 'package:town_pass/service/notification_service.dart';
import 'package:town_pass/service/push_service.dart';
import 'package:town_pass/service/shared_preferences_service.dart';
import 'package:town_pass/service/subscription_service.dart';
import 'package:town_pass/util/tp_button.dart';
import 'package:town_pass/util/tp_dialog.dart';
import 'package:town_pass/util/tp_route.dart';
import 'package:town_pass/util/tp_text.dart';
import 'package:town_pass/util/web_message_handler/tp_web_message_reply.dart';
import 'package:url_launcher/url_launcher.dart';

abstract class TPWebMessageHandler {
  String get name;

  Future<void> handle({
    required Object? message,
    required WebUri? sourceOrigin,
    required bool isMainFrame,
    required Function(WebMessage replyWebMessage)? onReply,
  });

  WebMessage replyWebMessage({required Object? data}) {
    return TPWebStringMessageReply(
      name: name,
      data: data,
    ).message;
  }
}

class UserinfoWebMessageHandler extends TPWebMessageHandler {
  @override
  String get name => 'userinfo';

  @override
  Future<void> handle({
    required Object? message,
    required WebUri? sourceOrigin,
    required bool isMainFrame,
    required onReply,
  }) async {
    // 沒有取得使用者授權就不給任何個資（回傳空值），由網頁自行請使用者填寫。
    final bool allowed = await Get.find<DataAuthorizationService>().ensure(
      origin: sourceOrigin,
      scope: DataScope.userinfo,
    );

    onReply?.call(replyWebMessage(
      data: allowed ? (Get.find<AccountService>().account ?? []) : [],
    ));
  }
}

class LaunchMapWebMessageHandler extends TPWebMessageHandler {
  @override
  String get name => 'launch_map';

  @override
  handle({
    required Object? message,
    required WebUri? sourceOrigin,
    required bool isMainFrame,
    required Function(WebMessage reply)? onReply,
  }) async {
    if (message == null || message is! String) {
      onReply?.call(
        replyWebMessage(data: false),
      );
    }
    final Uri uri = Uri.parse(message as String);
    final bool canLaunch = await canLaunchUrl(uri);

    onReply?.call(
      replyWebMessage(data: canLaunch),
    );

    if (canLaunch) {
      await launchUrl(uri);
    }
  }
}

class Agree1999MessageHandler extends TPWebMessageHandler {
  @override
  String get name => '1999agree';

  @override
  handle({
    required Object? message,
    required WebUri? sourceOrigin,
    required bool isMainFrame,
    required Function(WebMessage reply)? onReply,
  }) async {
    if (message == null) {
      onReply?.call(
        replyWebMessage(data: false),
      );
      return;
    }
    final Uri uri = Uri(scheme: 'tel', path: '1999');

    final bool canLaunch = await canLaunchUrl(uri);
    if (!canLaunch) {
      onReply?.call(replyWebMessage(data: false));
      return;
    }

    final bool userAgreement = SharedPreferencesService().instance.getBool(SharedPreferencesService.keyPhoneCallUserAgreement) ?? false;
    if (!userAgreement) {
      await Get.toNamed(TPRoute.phoneCallUserAgreement);

      final bool userAgreement = SharedPreferencesService().instance.getBool(SharedPreferencesService.keyPhoneCallUserAgreement) ?? false;
      if (!userAgreement) {
        onReply?.call(replyWebMessage(data: false));
        return;
      }
    }

    await TPDialog.show(
      padding: const EdgeInsets.symmetric(horizontal: 68, vertical: 40),
      showCloseCross: true,
      barrierDismissible: false,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Assets.svg.phoneCallService.svg(),
          const TPText('語音通報', style: TPTextStyles.titleSemiBold),
          const SizedBox(height: 8),
          const TPText('電話撥號'),
          const SizedBox(height: 24),
          TPButton.primary(
            text: '立即撥號',
            onPressed: () async => await launchUrl(uri),
          ),
        ],
      ),
    );
  }
}

class PhoneCallMessageHandler extends TPWebMessageHandler {
  @override
  String get name => 'phone_call';

  @override
  handle({
    required Object? message,
    required WebUri? sourceOrigin,
    required bool isMainFrame,
    required Function(WebMessage reply)? onReply,
  }) async {
    if (message == null) {
      onReply?.call(
        replyWebMessage(data: false),
      );
      return;
    }
    final String phone = message.toString().replaceFirst(RegExp(r'^tel:/*'), '');
    final Uri uri = Uri(scheme: 'tel', path: phone);
    final bool canLaunch = await canLaunchUrl(uri);

    onReply?.call(
      replyWebMessage(data: canLaunch),
    );

    if (canLaunch) {
      await launchUrl(uri);
    }
  }
}

class LocationMessageHandler extends TPWebMessageHandler {
  @override
  String get name => 'location';

  @override
  handle({
    required Object? message,
    required WebUri? sourceOrigin,
    required bool isMainFrame,
    required Function(WebMessage reply)? onReply,
  }) async {
    Position? position;

    final bool allowed = await Get.find<DataAuthorizationService>().ensure(
      origin: sourceOrigin,
      scope: DataScope.location,
    );
    if (!allowed) {
      onReply?.call(replyWebMessage(data: []));
      return;
    }

    // might have permission issue
    try {
      position = await Get.find<GeoLocatorService>().position();
    } catch (error) {
      printError(info: error.toString());
    }

    onReply?.call(replyWebMessage(
      data: position?.toJson() ?? [],
    ));
  }
}

class DeviceInfoMessageHandler extends TPWebMessageHandler {
  @override
  String get name => 'deviceinfo';

  @override
  handle({
    required Object? message,
    required WebUri? sourceOrigin,
    required bool isMainFrame,
    required Function(WebMessage reply)? onReply,
  }) async {
    onReply?.call(replyWebMessage(
      data: Get.find<DeviceService>().baseDeviceInfo?.data ?? [],
    ));
  }
}

class OpenLinkMessageHandler extends TPWebMessageHandler {
  @override
  String get name => 'open_link';

  @override
  handle({
    required Object? message,
    required WebUri? sourceOrigin,
    required bool isMainFrame,
    required Function(WebMessage reply)? onReply,
  }) async {
    switch (message as String?) {
      case String uri:
        await TPRoute.openUri(uri: uri);
      case null:
        onReply?.call(replyWebMessage(data: false));
    }
  }
}

class NotifyMessageHandler extends TPWebMessageHandler {
  @override
  String get name => 'notify';

  @override
  Future<void> handle(
      {required Object? message,
      required WebUri? sourceOrigin,
      required bool isMainFrame,
      required Function(
        WebMessage replyWebMessage,
      )? onReply}) async {
    switch (message) {
      case Map json:
        final String? title = json['title']?.toString();
        final String? content = json['content']?.toString();
        await NotificationService.showNotification(
          title: title,
          content: content,
        );
        if (content != null) {
          if (RegExp(r'已訂閱(.+)').hasMatch(content)) {
            final String target = RegExp(r'已訂閱(.+)').firstMatch(content)!.group(1)!;
            Get.find<SubscriptionService>().addSubscription(title: target);
          } else if (RegExp(r'已取消訂閱(.+)').hasMatch(content)) {
            final String target = RegExp(r'已取消訂閱(.+)').firstMatch(content)!.group(1)!;
            Get.find<SubscriptionService>().removeSubscription(title: target);
          }
        }
        onReply?.call(replyWebMessage(data: true));
      default:
        onReply?.call(replyWebMessage(data: false));
        return;
    }
  }
}

/// 輔具預約專用訊息：只有輔具預約自己的網頁（來源相符）可以使用，其他網頁一律拿不到信箱。
mixin AssistiveOriginGuard {
  bool allowed(WebUri? sourceOrigin) => AssistiveBackendService.isServiceOrigin(sourceOrigin);
}

/// 取得信箱 id。信箱金鑰只留在 App，不給網頁。
/// 訊息可帶 `{renew: true}`：後端不認得目前的信箱時，網頁請 App 建立新的。
/// 回傳 `{mailbox_id}`；失敗（後端連不上、來源不符）回傳空陣列。
class AssistiveMailboxMessageHandler extends TPWebMessageHandler with AssistiveOriginGuard {
  @override
  String get name => 'assistive_mailbox';

  @override
  Future<void> handle({
    required Object? message,
    required WebUri? sourceOrigin,
    required bool isMainFrame,
    required Function(WebMessage replyWebMessage)? onReply,
  }) async {
    if (!allowed(sourceOrigin)) {
      onReply?.call(replyWebMessage(data: []));
      return;
    }
    final backend = Get.find<AssistiveBackendService>();
    final bool renew = message is Map && message['renew'] == true;
    try {
      final String id = renew ? await backend.renewMailbox() : await backend.mailboxId();
      if (renew) {
        // 新的信箱還沒有登記手機：已經同意推播的話，悄悄補登記。
        unawaited(Get.find<PushService>().registerDevice(askPermission: false));
      }
      onReply?.call(replyWebMessage(data: {'mailbox_id': id}));
    } on AssistiveApiException {
      onReply?.call(replyWebMessage(data: []));
    }
  }
}

/// 新增或取消到貨通知：`{variant_id, on}`。成功回傳 `true`；失敗回傳 `{ok: false, code}`
///（code 例如 DUPLICATE_WAITLIST：同一類已經有等待中的、INVALID_FIELD：品項不存在、NETWORK：連不上）。
class AssistiveSubscribeMessageHandler extends TPWebMessageHandler with AssistiveOriginGuard {
  @override
  String get name => 'assistive_subscribe';

  @override
  Future<void> handle({
    required Object? message,
    required WebUri? sourceOrigin,
    required bool isMainFrame,
    required Function(WebMessage replyWebMessage)? onReply,
  }) async {
    final Object? variant = message is Map ? message['variant_id'] : null;
    if (!allowed(sourceOrigin) || variant == null) {
      onReply?.call(replyWebMessage(data: {'ok': false, 'code': 'INVALID_REQUEST'}));
      return;
    }
    final backend = Get.find<AssistiveBackendService>();
    final bool on = (message as Map)['on'] != false;
    try {
      if (on) {
        await backend.subscribe('$variant');
      } else {
        await backend.unsubscribe('$variant');
        // 登記取消了（使用者取消，或已經預約到這個品項），通知列上它的到貨通知也一併收掉
        unawaited(NotificationService.cancelTagged(PushService.arrivalTag('$variant')));
      }
      onReply?.call(replyWebMessage(data: true));
    } on AssistiveApiException catch (error) {
      onReply?.call(replyWebMessage(data: {
        'ok': false,
        'code': error.status == 0 ? 'NETWORK' : (error.code ?? 'ERROR'),
      }));
    }
  }
}

/// 這個信箱的到貨通知：`[{id, variant_id, category_id, status: waiting|arrived, created_at, arrived_at}]`。
/// 連不上時回傳 null，網頁就沿用上次看到的。
class AssistiveSubscriptionsMessageHandler extends TPWebMessageHandler with AssistiveOriginGuard {
  @override
  String get name => 'assistive_subscriptions';

  @override
  Future<void> handle({
    required Object? message,
    required WebUri? sourceOrigin,
    required bool isMainFrame,
    required Function(WebMessage replyWebMessage)? onReply,
  }) async {
    if (!allowed(sourceOrigin)) {
      onReply?.call(replyWebMessage(data: null));
      return;
    }
    try {
      final list = await Get.find<AssistiveBackendService>().subscriptions();
      onReply?.call(replyWebMessage(data: list.map((s) => s.toJson()).toList()));
    } on AssistiveApiException {
      onReply?.call(replyWebMessage(data: null));
    }
  }
}

/// 讓這支手機接收輔具預約的推播：先詢問使用者（授權範圍 push，以網頁來源為單位，可在「歷程與授權管理」撤回），
/// 同意後才向系統要通知權限、取得 token 並向後端登記。
/// 訊息可帶 `{silent: true}`：只在已經同意時更新登記，不跳任何視窗。
/// 回傳 `true`（已登記）或 `false`（沒同意、系統拒絕通知、沒有設定 Firebase、後端連不上）。
class AssistivePushMessageHandler extends TPWebMessageHandler with AssistiveOriginGuard {
  @override
  String get name => 'assistive_push';

  @override
  Future<void> handle({
    required Object? message,
    required WebUri? sourceOrigin,
    required bool isMainFrame,
    required Function(WebMessage replyWebMessage)? onReply,
  }) async {
    if (!allowed(sourceOrigin)) {
      onReply?.call(replyWebMessage(data: false));
      return;
    }
    final bool silent = message is Map && message['silent'] == true;
    final authorization = Get.find<DataAuthorizationService>();
    final bool granted = silent
        ? authorization.isGranted(origin: sourceOrigin, scope: DataScope.push)
        : await authorization.ensure(origin: sourceOrigin, scope: DataScope.push);
    if (!granted) {
      onReply?.call(replyWebMessage(data: false));
      return;
    }
    final bool registered = await Get.find<PushService>().registerDevice(askPermission: !silent);
    onReply?.call(replyWebMessage(data: registered));
  }
}

class QRCodeScanMessageHandler extends TPWebMessageHandler {
  @override
  String get name => 'qr_code_scan';

  @override
  Future<void> handle({
    required Object? message,
    required WebUri? sourceOrigin,
    required bool isMainFrame,
    required onReply,
  }) async {
    final result = await Get.toNamed(TPRoute.qrCodeScan);
    onReply?.call(
      replyWebMessage(data: result),
    );
  }
}
