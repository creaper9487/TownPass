import 'package:get/get.dart';

class AssistiveAgreementViewController extends GetxController {
  final RxBool checkboxValue = RxBool(false);

  /// 同意後回到上一頁，並回傳 true；按返回離開則沒有結果（視為還沒同意）。
  void agree() => Get.back(result: true);
}
