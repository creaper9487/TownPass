import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:town_pass/gen/assets.gen.dart';
import 'package:town_pass/page/assistive_agreement/assistive_agreement_view_controller.dart';
import 'package:town_pass/util/tp_app_bar.dart';
import 'package:town_pass/util/tp_bottom_sheet.dart';
import 'package:town_pass/util/tp_button.dart';
import 'package:town_pass/util/tp_card.dart';
import 'package:town_pass/util/tp_checkbox_list_tile.dart';
import 'package:town_pass/util/tp_colors.dart';
import 'package:town_pass/util/tp_text.dart';

/// 輔具預約的個資使用聲明：版面與「1999電話」的個資使用聲明相同（卡片、勾選同意、同意鍵），
/// 只在第一次使用時出現；同意後台北通資料、位置與推播通知一併授權，不再逐項詢問。
class AssistiveAgreementView extends GetView<AssistiveAgreementViewController> {
  const AssistiveAgreementView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const TPAppBar(title: '輔具預約'),
      bottomSheet: Obx(
        () => TPBottomSheet(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TPCheckboxListTile(
                value: controller.checkboxValue.value,
                onChanged: (value) => controller.checkboxValue.value = value!,
                content: '本人已詳閱並同意以上條款個資使用聲明',
              ),
              const SizedBox(height: 10),
              TPButton.primary(
                text: '同意',
                enable: controller.checkboxValue.value,
                onPressed: () async => controller.agree(),
              ),
            ],
          ),
        ),
      ),
      body: ListView(
        physics: const BouncingScrollPhysics(),
        children: [
          Padding(
            padding: const EdgeInsets.all(_CardContent._kOuterPadding),
            child: TPCard(
              child: _CardContent(),
            ),
          ),
          // 底部固定列（勾選與同意鍵）的高度，避免最後一段被蓋住。
          const SizedBox(height: 140),
        ],
      ),
    );
  }
}

class _CardContent extends StatelessWidget {
  static const double _kOuterPadding = 24.0;
  static const double _kCircleAvatarRadius = 50.0;
  static const double _kCircleAvatarTopOffset = -20.0;
  static const double _kCircleAvatarLeftOffset = -20.0;
  static const double _kIconTopOffset = 18.0;
  static const double _kIconLeftOffset = 22.0;
  static const double _kTextSpacingS = 4.0;
  static const double _kTextSpacingL = 32.0;

  // 依輔具預約實際會用到的資料列出；法律用語請由業務單位確認後再定稿。
  static const String _kAgreementContent =
      '依據個人資料保護法等相關規定，臺北市政府有義務告知以下事項：\n\n'
      '為提供更快速、便利之服務，利用台北通使用輔具預約時，系統會依您的操作使用下列資料：\n'
      '1. 台北通會員的「姓名、手機、E-mail、身分證字號、戶籍所在行政區」，用來預先填好預約表單。資料在您按下送出後才會傳送，不會自動送出。\n'
      '2. 您目前的位置，用來推薦離您最近的輔具中心，只在借用選擇中心時使用。\n'
      '3. 這支手機的通知識別碼，用來在已登記的輔具到貨、取貨期限當天、輔具評估與維修申請經中心確認時通知您。通知內容不會出現姓名、電話或身分證字號。\n\n'
      '您送出的預約資料（姓名、聯絡方式等）會傳送至輔具預約系統，轉交臺北市輔具中心辦理，'
      '其個人資料的利用之期間、對象、地區及方式，皆以該系統或該中心的「隱私權公告」為主，'
      '並遵守個人資料保護法相關規定，保障使用者的個資。\n\n'
      '之後可以在「歷程與授權管理」撤回。如有使用問題，請洽各輔具中心。';

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned(
          top: _kCircleAvatarTopOffset,
          left: _kCircleAvatarLeftOffset,
          child: CircleAvatar(
            radius: _kCircleAvatarRadius,
            backgroundColor: TPColors.primary100,
          ),
        ),
        Positioned(
          top: _kIconTopOffset,
          left: _kIconLeftOffset,
          child: Assets.svg.iconFamilyCenter.svg(),
        ),
        const Padding(
          padding: EdgeInsets.all(_kOuterPadding),
          child: Column(
            children: [
              TPText(
                '輔具預約',
                style: TPTextStyles.h2SemiBold,
                color: TPColors.primary500,
              ),
              SizedBox(height: _kTextSpacingS),
              TPText(
                '個資使用聲明',
                style: TPTextStyles.h3Regular,
                color: TPColors.grayscale700,
              ),
              SizedBox(height: _kTextSpacingL),
              TPText(
                _kAgreementContent,
                style: TPTextStyles.h3Regular,
                color: TPColors.grayscale700,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
