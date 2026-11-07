import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:town_pass/service/data_authorization_service.dart';
import 'package:town_pass/util/tp_colors.dart';
import 'package:town_pass/util/tp_line.dart';
import 'package:town_pass/util/tp_text.dart';

/// 「授權管理」：列出各網頁微服務得到的個資授權，可撤回。
class DataAuthorizationList extends StatelessWidget {
  const DataAuthorizationList({super.key});

  @override
  Widget build(BuildContext context) {
    final service = Get.find<DataAuthorizationService>();
    return Obx(() {
      final records = service.records.toList()..sort((a, b) => b.at.compareTo(a.at));
      if (records.isEmpty) {
        return const Center(
          child: TPText(
            '目前沒有授權紀錄',
            style: TPTextStyles.h3Regular,
            color: TPColors.grayscale500,
          ),
        );
      }
      return ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: records.length,
        separatorBuilder: (_, _) => const TPLine.horizontal(),
        itemBuilder: (_, index) {
          final record = records[index];
          final granted = record.decision == AuthDecision.granted;
          final date = '${record.at.month}/${record.at.day}';
          return Container(
            color: TPColors.white,
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TPText(
                        service.serviceNameOf(record.origin),
                        style: TPTextStyles.h3SemiBold,
                        color: TPColors.grayscale800,
                      ),
                      const SizedBox(height: 4),
                      TPText(
                        '${record.scope.label}・${granted ? '已授權' : '未授權'}（$date）',
                        style: TPTextStyles.bodyRegular,
                        color: TPColors.grayscale700,
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () => service.reset(record),
                  child: TPText(
                    granted ? '撤回授權' : '重新詢問',
                    style: TPTextStyles.h3Regular,
                    color: TPColors.primary500,
                  ),
                ),
              ],
            ),
          );
        },
      );
    });
  }
}
