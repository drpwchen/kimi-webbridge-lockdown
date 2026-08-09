# Changelog

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
