# 推播通知（Firebase Cloud Messaging）

輔具預約的後端用 FCM 推播到使用者的手機。只推使用者不在 App 裡也需要知道的非同步消息：輔具到貨（`stock.arrived`）、取貨期限當天提醒（`reservation.pickup_reminder`）、中心確認申請（`reservation.confirmed`）。預約成功、取消這類使用者自己剛做完的事，由網頁用對話框回應，不推播。
App 端由 `PushService`（`lib/service/push_service.dart`）負責，網頁微服務透過 `assistive_*` 訊息請 App 代為處理信箱、推播裝置與到貨通知。

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

## 網頁微服務 ↔ App：`assistive_*` 訊息

信箱金鑰與推播裝置都由 App 保管，網頁不碰金鑰（對應後端的 `docs/FRONTEND.md`）。這些訊息只有輔具預約自己的網頁（來源與服務網址相同）可以用，其他網頁一律拿不到信箱。

| 訊息 | 網頁送出 | App 回覆 |
|---|---|---|
| `assistive_mailbox` | 無，或 `{renew: true}` | `{mailbox_id}`；失敗是 `[]`。第一次會先 `POST /mailboxes`，金鑰存進系統安全儲存（Keystore／Keychain）。`renew` 是後端不認得目前的信箱時請 App 換新的，並補登記手機 |
| `assistive_subscribe` | `{variant_id, on}` | `true`；失敗是 `{ok: false, code}`，code 例如 `DUPLICATE_WAITLIST`、`INVALID_FIELD`、`NETWORK` |
| `assistive_subscriptions` | 無 | 到貨通知陣列 `[{id, variant_id, category_id, status: waiting｜arrived, created_at, arrived_at}]`；連不上是 `null` |
| `assistive_push` | `{silent?}` | `true`（這支手機已向後端登記）或 `false` |

`assistive_push` 的行為：

1. 第一次使用輔具預約時，App 顯示一份「個資使用聲明」頁（版面和「1999電話」相同：卡片、勾選同意、同意鍵），涵蓋台北通資料、位置與推播通知，同意後一次授權，之後不再出現。按返回離開不算同意，也不記成拒絕，同一次使用中不會再跳出。授權可在「歷程與授權管理」撤回，撤回推播後 App 會請後端移除這支手機。`silent: true` 時不跳任何視窗，沒同意就回 `false`。
2. 同意後，App 才會向系統要通知權限、取得 token（Firebase Installation ID，`FirebaseMessaging.register()` + `onRegistered`），然後 `POST /devices` 登記並訂閱 `assistive-notice`。後端直接把 FID 放進 FCM v1 的 `message.token`（已用真實專案驗證）。
3. 同一支手機換了 token（重新安裝、FID 更新）會先移除舊的再登記新的，不會收到兩份推播。

Android 要在 `AndroidManifest.xml` 打開 `firebase_messaging_installation_id_enabled`（已設定），否則 FID API 會回報「API disabled」。

後端網址用建置參數 `ASSISTIVE_API_BASE`（預設 `http://10.0.2.2:8000/assistive/v1`，只適用 Android 模擬器）；真機要換成電腦的區網 IP。

## 後端推播的格式（App 端的約定）

- 後端送 FCM v1 的 `notification` 訊息，`android.notification.channel_id = "assistive"`。App 啟動時建立同名頻道（`NotificationService`）。
- `data`：`{type, event_id, reservation_id?, variant_id?}`。
- App 在前景時，系統不會顯示 FCM 通知，所以 `PushService` 用本機通知顯示。
- 點通知會開輔具預約：有 `reservation_id` 開那一筆預約，`type = stock.arrived` 直接開這件輔具的借用（`/borrow/quick/<variant_id>`，已放進本次預約項目、從選中心開始；沒有 `variant_id` 時開預約查詢），其餘開首頁。App 被關掉時從通知開啟也一樣（`getInitialMessage`）。
