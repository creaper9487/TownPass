import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:town_pass/page/city_service/model/my_service_model.dart';
import 'package:town_pass/service/shared_preferences_service.dart';
import 'package:town_pass/util/tp_dialog.dart';
import 'package:town_pass/util/tp_text.dart';
import 'package:town_pass/util/tp_colors.dart';
import 'package:town_pass/util/tp_route.dart';

/// 網頁微服務可以向 App 要求的個人資料種類。
enum DataScope {
  userinfo('台北通帳號資料'),
  location('目前位置'),
  push('推播通知'),
  ;

  const DataScope(this.label);

  final String label;
}

enum AuthDecision { granted, denied }

class DataAuthorization {
  final String origin;
  final DataScope scope;
  final AuthDecision decision;
  final DateTime at;

  const DataAuthorization({
    required this.origin,
    required this.scope,
    required this.decision,
    required this.at,
  });

  Map<String, dynamic> toJson() => {
        'origin': origin,
        'scope': scope.name,
        'decision': decision.name,
        'at': at.toIso8601String(),
      };

  static DataAuthorization? fromJson(Map<String, dynamic> json) {
    final scope = DataScope.values.firstWhereOrNull((e) => e.name == json['scope']);
    final decision = AuthDecision.values.firstWhereOrNull((e) => e.name == json['decision']);
    final at = DateTime.tryParse('${json['at']}');
    if (scope == null || decision == null || at == null || json['origin'] is! String) {
      return null;
    }
    return DataAuthorization(origin: json['origin'], scope: scope, decision: decision, at: at);
  }
}

/// 個資授權：網頁微服務要台北通帳號資料或位置時，由 App 先詢問使用者。
///
/// 授權由 App 端把關：沒有取得同意就不回傳任何資料（回傳空值），
/// 網頁端只會看到「沒有資料」，不會有機會自己略過詢問。
/// 授權以網頁來源（scheme://host:port）為單位記錄，可在「歷程與授權管理」撤回。
class DataAuthorizationService extends GetxService {
  static const String _key = 'data_authorizations';

  final RxList<DataAuthorization> records = <DataAuthorization>[].obs;

  /// 同一個來源同時送出多個要求時，共用同一次詢問。
  final Map<String, Future<bool>> _pending = {};

  /// 這次開啟 App 期間已經按返回離開、沒有同意的來源：同一次使用中不再重複跳出聲明。
  final Set<String> _leftWithoutAgreeing = {};

  DataAuthorizationService init() {
    final raw = Get.find<SharedPreferencesService>().instance.getString(_key);
    if (raw != null) {
      try {
        final list = (jsonDecode(raw) as List)
            .map((e) => DataAuthorization.fromJson(Map<String, dynamic>.from(e as Map)))
            .whereType<DataAuthorization>();
        records.assignAll(list);
      } catch (_) {
        // 資料損毀就當作沒有紀錄，之後會重新詢問。
      }
    }
    return this;
  }

  /// 確認使用者已同意；還沒決定就跳出授權視窗。沒有同意一律回傳 false。
  Future<bool> ensure({required WebUri? origin, required DataScope scope}) async {
    final o = origin?.origin ?? '';
    if (o.isEmpty || o == 'null') {
      return false;
    }
    final existing = records.firstWhereOrNull((r) => r.origin == o && r.scope == scope);
    if (existing != null) {
      return existing.decision == AuthDecision.granted;
    }
    // 輔具預約：一份個資使用聲明涵蓋所有項目，第一次使用時出現一次，同意後不再逐項詢問。
    if (o == _originOf(MyServiceItemId.assistiveBooking.item.destinationUrl)) {
      if (_leftWithoutAgreeing.contains(o)) {
        return false;
      }
      return _pending[o] ??= _askAgreement(o).whenComplete(() {
        _pending.remove(o);
      });
    }
    final key = '$o|${scope.name}';
    // 注意：whenComplete 的回呼不能回傳 Future（remove 會回傳它），否則會變成等自己，永遠不結束。
    return _pending[key] ??= _ask(o, scope).whenComplete(() {
      _pending.remove(key);
    });
  }

  /// 已經同意才回傳 true；不會跳出詢問視窗（用在不能打擾使用者的背景更新）。
  bool isGranted({required WebUri? origin, required DataScope scope}) {
    final o = origin?.origin ?? '';
    return records.any((r) => r.origin == o && r.scope == scope && r.decision == AuthDecision.granted);
  }

  /// 撤回（或重設）授權；下次該服務要資料時會再詢問。
  Future<void> reset(DataAuthorization record) async {
    records.removeWhere((r) => r.origin == record.origin && r.scope == record.scope);
    await _persist();
  }

  /// 畫面上顯示的服務名稱：來源只對應到一個服務就用服務名稱，否則顯示網址。
  String serviceNameOf(String origin) {
    final names = MyServiceItemId.values
        .map((id) => id.item)
        .where((item) => item.destinationUrl.isNotEmpty && _originOf(item.destinationUrl) == origin)
        .map((item) => item.title)
        .toSet();
    if (names.length == 1) {
      return names.first;
    }
    return Uri.tryParse(origin)?.host ?? origin;
  }

  /// 網址的來源（scheme://host:port），和授權紀錄用的格式一樣。
  static String originOf(String url) => _originOf(url);

  static String _originOf(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasAuthority) {
      return '';
    }
    return '${uri.scheme}://${uri.host}:${uri.port}';
  }

  /// 顯示輔具預約的個資使用聲明頁（和「1999電話」相同的版面）。同意就一次授權全部項目；
  /// 按返回離開不記成拒絕，下次開啟 App 再問，但同一次使用中不會重複跳出。
  Future<bool> _askAgreement(String origin) async {
    final Object? agreed = await Get.toNamed(TPRoute.assistiveAgreement);
    if (agreed != true) {
      _leftWithoutAgreeing.add(origin);
      return false;
    }
    final DateTime now = DateTime.now();
    records.removeWhere((r) => r.origin == origin);
    records.addAll([
      for (final scope in DataScope.values)
        DataAuthorization(
          origin: origin,
          scope: scope,
          decision: AuthDecision.granted,
          at: now,
        ),
    ]);
    await _persist();
    return true;
  }

  Future<bool> _ask(String origin, DataScope scope) async {
    final name = serviceNameOf(origin);
    final answer = await TPDialog.showConfirm(
      title: switch (scope) {
        DataScope.userinfo => '「$name」想使用你的台北通資料',
        DataScope.location => '「$name」想使用你目前的位置',
        DataScope.push => '「$name」想傳送通知給你',
      },
      content: _content(scope),
    );
    if (answer == null) {
      // 按返回鍵離開：這次不提供，但也不記成「拒絕」，下次再問。
      return false;
    }
    records.removeWhere((r) => r.origin == origin && r.scope == scope);
    records.add(DataAuthorization(
      origin: origin,
      scope: scope,
      decision: answer ? AuthDecision.granted : AuthDecision.denied,
      at: DateTime.now(),
    ));
    await _persist();
    return answer;
  }

  Widget _content(DataScope scope) {
    final lines = switch (scope) {
      DataScope.userinfo => const [
          '會提供以下資料，用來幫你預先填好表單：',
          '姓名、手機、E-mail、身分證字號、戶籍所在行政區',
          '• 只提供給這個服務，不會自動送出。',
          '• 不同意的話，這個服務拿不到你的資料，你可以自己填寫。',
        ],
      DataScope.location => const [
          '用來推薦離你最近的服務據點。',
          '• 同意後，手機系統還會再詢問一次定位權限。',
        ],
      DataScope.push => const [
          '會用來通知輔具到貨、取貨期限當天的提醒，以及中心確認申請。',
          '• 通知內容不會出現姓名、電話或身分證字號。',
          '• 不同意的話，仍可在「預約查詢」自行查看最新狀態。',
        ],
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in lines) ...[
          TPText(line, style: TPTextStyles.bodyRegular, color: TPColors.grayscale700),
          const SizedBox(height: 8),
        ],
        const TPText(
          '之後可以在「歷程與授權管理」撤回。',
          style: TPTextStyles.bodyRegular,
          color: TPColors.grayscale700,
        ),
      ],
    );
  }

  Future<void> _persist() async {
    await Get.find<SharedPreferencesService>()
        .instance
        .setString(_key, jsonEncode(records.map((r) => r.toJson()).toList()));
  }
}
