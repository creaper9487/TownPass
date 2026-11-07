# 輔具預約：本機建置與執行

網頁（`TownPass-Services`，Vue）在台北通 App（本 repo，Flutter）的 WebView 裡執行。網頁程式碼由 Vite 開發伺服器即時提供，
**只有 Flutter 端有改動才需要重建 App**。

兩個 repo 都用 `wip/assistive-booking` 分支（`main` 沒有輔具預約的入口）。

## 1. 網頁

```bash
cd TownPass-Services
git checkout wip/assistive-booking
pnpm install
cp .env.development.example .env.development   # 填後端位址
pnpm exec vite --host 0.0.0.0 --port 5173        # 一定要 --host，模擬器或手機才連得到
```

`.env.development` 的 `VITE_ASSISTIVE_API_BASE` 指向後端（`/assistive/v1`）；不設定就用瀏覽器 localStorage 模擬，方便只看畫面。
後端若跑在你自己的電腦，模擬器可以 `adb reverse tcp:8000 tcp:8000`，位址填 `http://localhost:8000/assistive/v1`。

## 2. App（Android）

需要 Flutter 3.47、JDK 17、Android SDK。

```bash
cd TownPass-upstream
git checkout wip/assistive-booking
flutter pub get
dart run build_runner build          # 產生 *.gen.dart（不在版本庫裡）
flutter build apk --debug --target-platform android-arm64 \
  --dart-define-from-file=firebase.local.json
adb -s <裝置> install -r build/app/outputs/flutter-apk/app-debug.apk
```

兩個建置參數：

- **`firebase.local.json`**（推播用，不要 commit）：向專案管理者拿，格式見 [push-notifications.md](push-notifications.md)。
  沒有的話把 `--dart-define-from-file` 那行拿掉：App 照常運作，只是沒有推播。
- **`ASSISTIVE_API_BASE`**：App 呼叫後端（信箱、推播裝置、到貨通知）的網址，預設 `http://10.0.2.2:8000/assistive/v1`（只適用 Android 模擬器）。
  要和網頁 `.env.development` 的 `VITE_ASSISTIVE_API_BASE` 指向同一台後端，真機請改成後端電腦的區網 IP。
- **`ASSISTIVE_URL`**：App 載入的網頁網址，預設 `http://10.0.2.2:5173/assistive`（只適用 Android 模擬器）。
  真機要加上 `--dart-define=ASSISTIVE_URL=http://<電腦的區網 IP>:5173/assistive`，手機與電腦要在同一個 Wi-Fi。

debug 版允許連 http（`android/app/src/debug/AndroidManifest.xml`），release 版不行。

## 3. 打開服務

App →「服務」分頁 →「輔具預約」。第一次使用資料或通知時，App 會跳出授權視窗；之後可在「歷程與授權管理」撤回。

## 常見問題

- **打開是空白或連不上**：確認 Vite 有加 `--host`，網址（模擬器 `10.0.2.2`、真機區網 IP）和防火牆沒擋 5173。
- **預約送出失敗**：後端連不上。網頁會在後端不認得舊信箱時自動重建，但位址錯或後端沒開就只能顯示失敗。
- **多台裝置時 adb 報錯**：每個指令加 `-s <裝置序號>`。
