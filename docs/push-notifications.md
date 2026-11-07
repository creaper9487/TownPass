# 推播通知（Firebase Cloud Messaging）

輔具預約的後端（預約進度、取貨提醒、到貨、公告）用 FCM 推播到使用者的手機。
App 端由 `PushService`（`lib/service/push_service.dart`）負責，網頁微服務透過 `push_token` 訊息取得 token。

## 設定

Firebase 專案設定不放進程式碼，建置時用 `--dart-define` 帶入。沒有帶的話 App 照常運作，只是沒有推播。

| 參數 | Android（`google-services.json`） | iOS（`GoogleService-Info.plist`） |
|---|---|---|
| `FIREBASE_API_KEY` | `client[0].api_key[0].current_key` | `API_KEY` |
| `FIREBASE_APP_ID` | `client[0].client_info.mobilesdk_app_id` | `GOOGLE_APP_ID` |
| `FIREBASE_MESSAGING_SENDER_ID` | `project_info.project_number` | `GCM_SENDER_ID` |
| `FIREBASE_PROJECT_ID` | `project_info.project_id` | `PROJECT_ID` |
| `FIREBASE_IOS_BUNDLE_ID` | （不需要） | `BUNDLE_ID` |

兩個檔案都在 Firebase 主控台 → 專案設定 → 一般 → 你的應用程式下載，下載後只是用來抄值，不需要放進專案。

```bash
flutter run \
  --dart-define=FIREBASE_API_KEY=... \
  --dart-define=FIREBASE_APP_ID=... \
  --dart-define=FIREBASE_MESSAGING_SENDER_ID=... \
  --dart-define=FIREBASE_PROJECT_ID=...
```

也可以把這些寫進一個不要 commit 的 JSON 檔，改用 `--dart-define-from-file=firebase.local.json`。

後端要用同一個 Firebase 專案的服務帳號金鑰（`FCM_PROJECT_ID`、`FCM_CREDENTIALS_FILE`），App 與後端才會在同一個專案。

Android 要在 `AndroidManifest.xml` 打開 `firebase_messaging_installation_id_enabled`（已設定），否則 FID API 會回報「API disabled」。

### iOS 還要做的事

- 在 Firebase 專案上傳 APNs 金鑰（Apple Developer 帳號產生）。
- Xcode 的 Runner target 打開 Push Notifications capability（會產生 `aps-environment` entitlement）。
- `Info.plist` 已加上 `UIBackgroundModes: remote-notification`。

### 沒有 Firebase 專案時的開發方式

debug 版可以用 `--dart-define=PUSH_DEV_TOKEN=local-xxxx` 代替真的 token，走完「網頁 → App → 後端登記裝置」。
後端把 `local-` 開頭的 token 當作本機假裝置，只記錄不送出。release 版不認這個參數。

## 網頁微服務 ↔ App：`push_token`

網頁送出 `{name: 'push_token', data: {silent?: boolean, topics?: string[]}}`，App 回覆 `{name: 'push_token', data}`：

- 成功：`data = {token, platform: 'fcm'}`。`token` 是 Firebase Installation ID（FID，`FirebaseMessaging.register()` + `onRegistered`），後端直接放進 FCM v1 的 `message.token` 送出（已用真實專案驗證）
- 使用者不同意、系統拒絕通知、沒有設定 Firebase：`data = []`

行為：

1. 以網頁來源（origin）為單位詢問使用者是否同意（`DataScope.push`），可在「歷程與授權管理」撤回。`silent: true` 時不跳任何視窗，沒同意就回空陣列。
2. 同意後，App 才會向系統要通知權限、取得 token。
3. `topics` 只接受 `assistive-` 開頭的名稱，同意後替使用者訂閱（後端公告用 `assistive-notice`）。

網頁拿到 token 後，用自己的信箱金鑰呼叫後端 `POST /devices` 登記；同一支手機換了 token，網頁會先請後端移除舊的再登記新的。

## 後端推播的格式（App 端的約定）

- 後端送 FCM v1 的 `notification` 訊息，`android.notification.channel_id = "assistive"`。App 啟動時建立同名頻道（`NotificationService`）。
- `data`：`{type, event_id, reservation_id?, variant_id?}`。
- App 在前景時，系統不會顯示 FCM 通知，所以 `PushService` 用本機通知顯示。
- 點通知會開輔具預約：有 `reservation_id` 開那一筆預約，`type = stock.arrived` 開預約查詢，其餘開首頁。App 被關掉時從通知開啟也一樣（`getInitialMessage`）。
