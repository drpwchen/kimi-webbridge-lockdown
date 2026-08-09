# ai-browser-lockdown

[English](README.md)

把 AI 瀏覽器控制擴充擋在你的網銀、券商、信箱之外——其他網站照常讓它自動化。

## 問題在哪

AI coding agent 可以透過擴充套件（Kimi WebBridge、Claude in Chrome 等）直接操作你的真實瀏覽器。其中一類用的是 `chrome.debugger` API 加上 `<all_urls>` 權限：**一次拿到你所有網站的登入身分**，不是逐頁問你同意。

反直覺的地方（2026-08-09 於 Windows Edge 實測確認）：

> **擴充套件設定裡的逐站「網站存取權」白名單，擋不住 debugger 型擴充。** 那層 UI 只收回 `host_permissions`（content script、webRequest 那類）；`debugger` 是 API 權限、全域生效——就算你把某網站從清單移除，它照樣能 attach 到該分頁、讀取內容、執行 JavaScript。

真正有效的逐 host 控制在**企業政策層**：`ExtensionSettings` → `runtime_blocked_hosts`。設定後，擴充在被封網站得到 `Cannot attach to this target`，其他網站完全不受影響。已在真實環境雙向驗證（13 個要害 host 全部拒絕 attach、自動化該用的網站照常通行）。

這個工具把該政策做成有引導、可還原的一鍵設定。

## 它做什麼

1. **偵測**所有瀏覽器 profile 裡帶 `debugger` 權限的擴充（就是有風險的那類）。
2. **讓你選**要保護什麼：內建一份實地驗證過的台灣網銀／券商／Gmail 登入 host 目錄，也可自訂（直接貼登入頁網址，會自動取出 host）。
3. **先備份**現有政策，再把封鎖清單**合併**進 `ExtensionSettings`（絕不覆蓋既有設定）。
4. **驗證**：讀回 registry 比對，並引導你做實測——被封網站必須 attach 失敗、正常網站必須照常。
5. **一鍵還原**任何一次備份。

## 使用方式

### Windows（Edge＋Chrome）——已實測

用**系統管理員身分**開 PowerShell（政策寫在 HKLM）：

```powershell
git clone https://github.com/drpwchen/ai-browser-lockdown
cd ai-browser-lockdown\windows
.\lockdown.ps1              # 互動選單：上鎖／狀態／還原
.\lockdown.ps1 -Action status    # 唯讀，不需系統管理員
```

寫入後**完全關閉瀏覽器再重開**（含背景程序），到 `edge://policy` / `chrome://policy` 確認 `ExtensionSettings` 有出現，然後雙向實測。

### macOS（Edge＋Chrome）——已實測

政策必須寫在 `/Library/Managed Preferences`，所以腳本會呼叫 `sudo`：

```bash
cd ai-browser-lockdown/macos
./lockdown.sh                    # 互動選單：上鎖／狀態／還原
./lockdown.sh status             # 唯讀，不需要管理員權限
```

寫入後**完全關閉瀏覽器再重開**（Cmd+Q，所有視窗），開 `chrome://policy` /
`edge://policy`，確認 `ExtensionSettings` 的**等級是「強制 Mandatory」**，再做雙向實測。

> **`defaults write` 沒有用，而且是無聲失敗。** v0.1.0 把政策寫到 user 層 `defaults`。
> 在 macOS 26.5.2 / Chrome 151 上用真的帶 `debugger` 權限的擴充實測（2026-08-09）：
>
> | 政策寫在哪 | `chrome://policy` | 對被封鎖 host 呼叫 `chrome.debugger.attach` |
> |---|---|---|
> | `defaults write com.google.Chrome` | 等級**建議採用**，狀態*有效* | **成功** —— 擴充 attach 上去並讀到頁面內容 |
> | `/Library/Managed Preferences/…`（root:wheel, 644） | 等級**強制**，範圍*本機* | **`Cannot attach to this target.`** |
>
> 兩次測試中未封鎖的對照 host 都正常，所以這是精準封鎖、不是瀏覽器壞掉。危險的是中間那欄：
> user defaults 那層在 `chrome://policy` 上顯示「有效」，照 v0.1.0 自己寫的驗證步驟做，
> 會讓你以為受保護了，其實完全沒有。所以現在的檢查標準是「等級必須是強制」，
> 而不是「ExtensionSettings 有出現」。

如果你的 Mac 由 MDM 管理，MDM 可能會覆蓋 `/Library/Managed Preferences`，
請改用 MDM 下發同樣的 `ExtensionSettings` payload。

## 設計取捨

- **精確 host，絕不用 `*.域名` wildcard。** 封 `*.esunbank.com.tw` 會連 `card.esunbank.com.tw` 一起封掉——信用卡活動、開戶這些子網域常常正是你**要**自動化去搶的。精確就是重點。
- **合併，不覆蓋。** 既有的 `ExtensionSettings`（其他擴充、同擴充的其他設定）全部保留，封鎖清單做聯集；每次寫入前自動留時間戳備份在 `~/.ai-browser-lockdown/backups/`。
- **目錄裡的 host 不是驗證過的就不收。** `catalog/hosts.json` 每一條都是實際開登入頁、從網址列抄下來的。搜尋引擎的記憶不算數——過期索引會列出已死的 host（我們真的遇過），而且個人網銀跟企業網銀常常是不同 host。

## 限制——請務必讀

- **黑名單只擋你列出來的。** 新開銀行帳戶要回來補一行。這是機制先天限制。
- **本機管理員可以解除。** 這道鎖防的是「AI agent 拿著你的登入 session 逛進網銀」，不防惡意軟體或任何有管理員權限的人。
- AI 瀏覽器控制更深層的殘餘風險是 **prompt injection**：agent 一邊讀有敵意的網頁、一邊同瀏覽器裡還登著你的要害帳號。這工具把最要命的目標移出它的射程，但「別讓 agent 邊逛不信任的網站邊掛著重要登入」這個習慣還是要靠你自己。
- 更密不透風的替代方案：讓自動化跑在**一個從不登入任何要害帳號的獨立瀏覽器 profile**。設定麻煩一點，但沒有枚舉問題。

## 貢獻目錄條目

歡迎 PR 增加銀行／券商 host 群組，唯一硬規則：**每個 host 都必須實際開登入頁、從網址列抄下來驗證**，並附上驗證日期。也請順手註記該保持開放的兄弟子網域（信用卡活動、開戶、行銷官網）。

## 授權

MIT
