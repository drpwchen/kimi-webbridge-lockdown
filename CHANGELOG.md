# Changelog

## v0.3.0 — 2026-08-09

Agent-guided mode, unblock, and the Windows port of v0.2.0's host validation.

- **AGENTS.md — let your AI agent run the whole flow.** People using this tool already have an AI agent; AGENTS.md scripts it end-to-end: interview which sites to protect (hosts only from the user's address bar or the verified catalog, never from model memory), keep-open check, non-interactive apply, then the agent proves the lock by attempting to attach to a blocked host and failing. Both scripts gained a non-interactive mode for this (Windows `-Browser/-ExtensionIds/-Hosts/-Yes`; macOS positional `lock|unblock <browser> <extids> <hosts> --yes`) — confirmation is skippable, backup and read-back verification are not.
- **`unblock` on both platforms** — remove selected hosts from selected extensions; everything else (other hosts, sibling settings like `installation_mode`, other extensions, unrelated policies) is preserved; an emptied host list drops its key, an extension entry left empty disappears, and on Windows a fully emptied policy value is deleted. Backup before write, read-back verifies the removed hosts are gone.
- **Windows host validation ported from v0.2.0's macOS fix** — the same lax parsing existed in `Format-HostPattern`: ports and userinfo passed straight through (`client.schwab.com:443` → a pattern Chrome silently discards) and dot-less bare words became "hosts". Now stripped/validated identically to macOS; invalid non-interactive input aborts loudly instead of being dropped.
- Tests: Windows 26→44 (Remove-BlockedHosts, roundtrip, new rejections; mutation-verified — never-drop-emptied-key, filter-removes-nothing, and dropped-validation each fail the suite), macOS 36→54 (non-interactive lock/unblock, whole-list removal, bad-input abort).

---

代理引導模式、unblock、以及 v0.2.0 host 驗證的 Windows 移植。

- **AGENTS.md——讓你的 AI agent 跑完全程。** 會用這工具的人手上都有 AI agent；AGENTS.md 把流程整套寫給它：訪談要保護哪些網站（host 只准來自使用者網址列或已驗證目錄，絕不准用模型記憶）、keep-open 確認、非互動執行，最後 agent 以「自己 attach 被封 host 而失敗」證明鎖有效。兩平台為此加了非互動模式——確認步驟可跳過，備份與讀回驗證不可跳過。
- **兩平台皆有 `unblock`**——從選定擴充移除選定 host，其餘全數保留（其他 host、`installation_mode` 等同層設定、其他擴充、無關政策）；清空的清單移除該 key、空掉的擴充條目整個消失、Windows 上整份 policy 空掉則刪除該值。寫入前備份、讀回驗證移除到位。
- **Windows 補上 v0.2.0 修過的 host 驗證**——同款寬鬆解析也在 `Format-HostPattern`：port／userinfo 原樣通過（Chrome 會默默丟棄）、無點裸字變 host。現與 macOS 規則一致；非互動模式下無效輸入大聲中止而非默默丟棄。
- 測試：Windows 26→44（含三種變異驗證全被抓）、macOS 36→54。

## v0.2.0 — 2026-08-09

macOS path rewritten after real-hardware testing. **v0.1.0's macOS lockdown protected nothing** — upgrade if you ran it.

- **macOS policy layer moved from user `defaults` to `/Library/Managed Preferences` (requires `sudo`).** Measured on macOS 26.5.2 / Chrome 151 against a real `debugger`-permission extension: a policy written with `defaults write` loads at level *Recommended* and `chrome.debugger.attach` on a blocked host **still succeeds**; the same policy in `/Library/Managed Preferences` loads at level *Mandatory* and attach fails with `Cannot attach to this target.` An unblocked control host kept working in both runs. `chrome://policy` reported the useless user-defaults policy as *Valid*, so v0.1.0's own verification step confirmed a protection that did not exist — the check is now "level must read Mandatory".
- **macOS merge is now a real merge.** v0.1.0 used `defaults -dict-add`, which replaced the extension's whole settings object: re-running it to add one bank silently unblocked every host blocked earlier and wiped sibling keys such as `installation_mode` / `update_url`. Now unions `runtime_blocked_hosts` (idempotent) and preserves sibling keys, other extensions, and unrelated policies. Matches the Windows behaviour that was already documented.
- **macOS crash on every error path.** Under bash 3.2 (macOS default) in a UTF-8 locale, `"$var」"` parses the trailing CJK bytes as part of the variable name, so `set -u` aborted with `extid: unbound variable` instead of printing the friendly message — hit by any typo'd extension ID or group number. All such sites now brace the expansion.
- **macOS host parsing accepted patterns Chrome discards.** Ports, userinfo and bare words were passed straight through (`https://client.schwab.com:443/x` → `*://client.schwab.com:443`, `not a url` → `*://notaurl`), producing entries Chrome drops — a blocklist that looks populated and blocks nothing. Hostnames are now validated and stripped; unparseable input is rejected loudly instead of aborting the script silently.
- **macOS browser choice is validated** — anything other than `1`/`2` used to fall through to Chrome without a word.
- `status` now reports the mandatory layer and separately flags any leftover v0.1.0 user-defaults entry as ineffective, with the command to remove it; `lock` offers to clean it up. `restore` handles managed-preferences backups, "there was no policy file" markers, and legacy v0.1.0 user-defaults backups.

---

macOS 路徑在實機測試後重寫。**v0.1.0 的 macOS 上鎖完全沒有保護作用** —— 跑過的請務必更新。

- **macOS 政策層從 user `defaults` 改到 `/Library/Managed Preferences`（需 `sudo`）。** 在 macOS 26.5.2 / Chrome 151 上以真的帶 `debugger` 權限的擴充實測：用 `defaults write` 寫入的政策等級是「建議採用」，對被封鎖 host 呼叫 `chrome.debugger.attach` **仍然成功**；同樣內容放進 `/Library/Managed Preferences` 等級變成「強制」，attach 會失敗並回 `Cannot attach to this target.`。兩次測試中未封鎖的對照 host 都正常。而 `chrome://policy` 把那個沒用的 user-defaults 政策顯示為「有效」，等於 v0.1.0 自己的驗證步驟會確認一個不存在的保護——現在的檢查標準改成「等級必須是強制」。
- **macOS 的合併現在才是真的合併。** v0.1.0 用 `defaults -dict-add`，會把該擴充整個設定物件換掉：之後為了加一家銀行再跑一次，先前封鎖的 host 會無聲解封，`installation_mode`／`update_url` 之類的同層設定也一併消失。現在 `runtime_blocked_hosts` 做聯集（可重複執行不變），並保留同層設定、其他擴充與無關政策——與文件早就寫著的 Windows 行為一致。
- **macOS 每一條錯誤路徑都會 crash。** 在 bash 3.2（macOS 預設）＋ UTF-8 locale 下，`"$var」"` 會把後面的中文位元組吃進變數名，`set -u` 於是丟出 `extid: unbound variable`，而不是印出友善訊息——擴充 ID 或群組編號打錯就會踩到。所有這類位置都改成大括號展開。
- **macOS 的 host 解析會產生 Chrome 直接丟棄的 pattern。** port、userinfo、單純的亂打字串都原樣通過（`https://client.schwab.com:443/x` → `*://client.schwab.com:443`、`not a url` → `*://notaurl`），寫進去 Chrome 會丟掉——看起來滿滿一份封鎖清單，實際什麼都沒擋。現在會驗證並清理 hostname，解析不出來就明確拒絕，而不是讓腳本無聲中止。
- **macOS 瀏覽器選項會驗證** —— 以前輸入 `1`／`2` 以外的東西會默默當成 Chrome。
- `status` 現在會分別顯示強制層，以及標示任何殘留的 v0.1.0 user-defaults 設定為「無效」並附上清除指令；`lock` 會主動詢問是否清掉。`restore` 支援 managed-preferences 備份、「原本就沒有政策檔」標記，以及 v0.1.0 的舊 user-defaults 備份。

---

## v0.1.0 — 2026-08-09

Initial release.

- **Windows (tested)**: interactive PowerShell tool (`windows/lockdown.ps1`) — detects `debugger`-permission extensions across Edge/Chrome profiles, merges `runtime_blocked_hosts` into the `ExtensionSettings` policy (HKLM, JSON string value), timestamped backup before every write, read-back verification, guided live test, one-command restore. 26 logic tests (`tests/run-tests.ps1`), mutation-verified (union→overwrite, JSON depth truncation, always-pass verify — all caught).
- **macOS (experimental)**: `macos/lockdown.sh` via user-level `defaults write`; browser-side policy verification is mandatory because some builds only honor MDM-delivered policy. Not yet verified on real hardware.
- **Catalog**: `catalog/hosts.json` — verified Taiwan bank/broker/Gmail login hosts (address-bar confirmed, dated), with keep-open sibling subdomains documented. Exact hosts only, no wildcards.

---

初版發佈。

- **Windows（已實測）**：互動式 PowerShell 工具——偵測帶 `debugger` 權限的擴充（Edge／Chrome 全 profile）、把 `runtime_blocked_hosts` 合併進 `ExtensionSettings` 政策（HKLM JSON 字串值）、寫入前自動備份、讀回驗證、引導實測、一鍵還原。26 條邏輯測試＋變異驗證（三種故意破壞全被抓到）。
- **macOS（實驗性）**：走 user 層 `defaults write`；因部分版本只認 MDM 政策，瀏覽器端驗證列為必做。尚未實機驗證。
- **目錄**：實地驗證過的台灣網銀／券商／Gmail 登入 host（附驗證日期與該保持開放的子網域）。只收精確 host，不用 wildcard。
