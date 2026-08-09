#!/bin/bash
# ai-browser-lockdown — macOS (EXPERIMENTAL, not yet verified on real hardware)
#
# Writes the ExtensionSettings policy (runtime_blocked_hosts) for Microsoft Edge /
# Google Chrome via `defaults write`. On macOS, policies written to user defaults
# may or may not be honored as *mandatory* policy depending on browser version —
# some builds only trust /Library/Managed Preferences (MDM). That is why the
# verification step below is NOT optional: you must confirm in edge://policy or
# chrome://policy that ExtensionSettings actually shows up, then live-test that
# your AI tool really cannot attach to a blocked site. If the policy does not
# appear, this approach does not work on your setup — use an MDM profile instead.
#
# Usage:  ./lockdown.sh [lock|status|restore]
set -euo pipefail

BACKUP_DIR="$HOME/.ai-browser-lockdown/backups"

# --- catalog (master copy: catalog/hosts.json — keep in sync when editing) -----
GROUP_LABELS=(
  "永豐銀行 SinoPac (personal e-banking)"
  "華南銀行 Hua Nan Bank (e-banking)"
  "玉山銀行 E.SUN Bank (e-banking)"
  "台新銀行 Taishin / Richart (e-banking)"
  "聯邦銀行 Union Bank of Taiwan (personal e-banking)"
  "聯邦證券 Union Securities (broker)"
  "Charles Schwab (broker + bank)"
  "Gmail (mail content)"
)
GROUP_HOSTS=(
  "mma.sinopac.com accessibility.sinopac.com"
  "netbank.hncb.com.tw lovebank.hncb.com.tw"
  "ebank.esunbank.com.tw"
  "my.taishinbank.com.tw ac.taishinbank.com.tw richart.tw"
  "www.ubot.com.tw"
  "www.usot.com.tw"
  "client.schwab.com online.schwabbank.com"
  "mail.google.com"
)

browser_label()  { [ "$1" = "edge" ] && echo "Microsoft Edge" || echo "Google Chrome"; }
browser_domain() { [ "$1" = "edge" ] && echo "com.microsoft.Edge" || echo "com.google.Chrome"; }
browser_appdir() {
  if [ "$1" = "edge" ]; then echo "$HOME/Library/Application Support/Microsoft Edge"
  else echo "$HOME/Library/Application Support/Google/Chrome"; fi
}
policy_page() { [ "$1" = "edge" ] && echo "edge://policy" || echo "chrome://policy"; }

normalize_host() {
  # Accept "host", "*://host" or a pasted URL; print bare lowercase host, or nothing.
  local h="$1"
  h="$(echo "$h" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  h="${h#\*://}"
  case "$h" in *://*) h="${h#*://}";; esac
  h="${h%%[/?#]*}"
  h="${h%.}"
  [ -n "$h" ] && echo "$h"
}

scan_debugger_extensions() {
  # Print "id<TAB>name" for installed extensions whose manifest requests "debugger".
  local appdir manifest extdir id name msgdir locale
  appdir="$(browser_appdir "$1")"
  [ -d "$appdir" ] || return 0
  find "$appdir" -maxdepth 5 -path '*/Extensions/*/manifest.json' 2>/dev/null | while read -r manifest; do
    grep -q '"debugger"' "$manifest" 2>/dev/null || continue
    extdir="$(dirname "$(dirname "$manifest")")"
    id="$(basename "$extdir")"
    name="$(sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest" | head -1)"
    if [[ "$name" == __MSG_* ]]; then
      locale="$(sed -n 's/.*"default_locale"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest" | head -1)"
      msgdir="$(dirname "$manifest")/_locales/${locale:-en}/messages.json"
      [ -f "$msgdir" ] && name="$(sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$msgdir" | head -1)"
    fi
    printf '%s\t%s\n' "$id" "${name:-unknown}"
  done | sort -u
}

do_status() {
  local b domain
  for b in edge chrome; do
    echo ""
    echo "=== $(browser_label "$b") ==="
    [ -d "$(browser_appdir "$b")" ] || { echo "  （未偵測到安裝）"; continue; }
    echo "  帶 debugger 權限的擴充："
    scan_debugger_extensions "$b" | sed 's/^/    /' || true
    domain="$(browser_domain "$b")"
    echo "  目前 ExtensionSettings（user defaults 層）："
    defaults read "$domain" ExtensionSettings 2>/dev/null | sed 's/^/    /' || echo "    （未設定）"
  done
  echo ""
  echo "⚠ 注意：user defaults 有值 ≠ 瀏覽器一定套用。請開 edge://policy 或 chrome://policy 確認。"
}

do_lock() {
  echo "要設定哪個瀏覽器？ [1] Edge  [2] Chrome"
  read -r -p "選擇 (1/2): " bc
  local b; [ "$bc" = "1" ] && b="edge" || b="chrome"
  local domain; domain="$(browser_domain "$b")"

  echo ""
  echo "偵測到的 debugger 擴充（AI 瀏覽器控制工具屬於這類）："
  scan_debugger_extensions "$b" | sed 's/^/  /' || true
  read -r -p "輸入要封鎖的擴充 ID（32 碼小寫字母）: " extid
  if ! [[ "$extid" =~ ^[a-p]{32}$ ]]; then echo "「$extid」不是合法擴充 ID，結束。"; exit 1; fi

  echo ""
  echo "選擇要封鎖的網站群組（皆為實地驗證過的登入 host）："
  local i
  for i in "${!GROUP_LABELS[@]}"; do
    echo "  [$((i + 1))] ${GROUP_LABELS[$i]}  → ${GROUP_HOSTS[$i]}"
  done
  read -r -p "輸入編號（逗號分隔，all 全選，Enter 跳過）: " picks
  local hosts=()
  if [ "$picks" = "all" ]; then
    for i in "${!GROUP_HOSTS[@]}"; do for h in ${GROUP_HOSTS[$i]}; do hosts+=("$h"); done; done
  elif [ -n "$picks" ]; then
    for tok in ${picks//,/ }; do
      if [[ "$tok" =~ ^[0-9]+$ ]] && [ "$tok" -ge 1 ] && [ "$tok" -le "${#GROUP_HOSTS[@]}" ]; then
        for h in ${GROUP_HOSTS[$((tok - 1))]}; do hosts+=("$h"); done
      else echo "  無效編號「$tok」（略過）"; fi
    done
  fi
  read -r -p "自訂 host（逗號分隔，可貼登入頁網址，Enter 跳過）: " custom
  if [ -n "$custom" ]; then
    for tok in ${custom//,/ }; do
      local nh; nh="$(normalize_host "$tok")"
      [ -n "$nh" ] && hosts+=("$nh") || echo "  「$tok」無法解析（略過）"
    done
  fi
  [ "${#hosts[@]}" -gt 0 ] || { echo "沒有選擇任何 host，結束。"; exit 1; }

  # de-dup + build old-style plist array "( "*://a", "*://b" )"
  local uniq=() seen=" " arr="" h
  for h in "${hosts[@]}"; do
    case "$seen" in *" $h "*) continue;; esac
    seen="$seen$h "; uniq+=("$h")
    [ -n "$arr" ] && arr="$arr, "
    arr="$arr\"*://$h\""
  done

  echo ""
  echo "即將寫入 $(browser_label "$b") 的封鎖規則："
  echo "  擴充: $extid"
  for h in "${uniq[@]}"; do echo "  *://$h"; done
  if defaults read "$domain" ExtensionSettings 2>/dev/null | grep -q "$extid"; then
    echo "  ⚠ 此擴充已有 ExtensionSettings 設定，將被本次內容取代（備份會先建立）。"
  fi
  read -r -p "確定寫入？ (y/N): " go
  [[ "$go" =~ ^[Yy]$ ]] || { echo "已取消。"; exit 0; }

  mkdir -p "$BACKUP_DIR"
  local backup="$BACKUP_DIR/$b-defaults-$(date +%Y%m%d-%H%M%S).plist"
  defaults export "$domain" "$backup"
  echo "已備份現況 → $backup"

  defaults write "$domain" ExtensionSettings -dict-add "$extid" "{ runtime_blocked_hosts = ( $arr ); }"
  echo "✓ 已寫入 user defaults。讀回："
  defaults read "$domain" ExtensionSettings | sed 's/^/  /'

  echo ""
  echo "接下來（必做，這是實驗性路徑）："
  echo "  1. 完全關閉 $(browser_label "$b")（Cmd+Q）再重開。"
  echo "  2. 開 $(policy_page "$b") — 必須看到 ExtensionSettings 出現在政策清單。"
  echo "     沒出現＝你的瀏覽器版本不吃 user defaults 政策，本方法無效，需改用 MDM profile。"
  echo "  3. 實測兩個方向：叫 AI 工具開被封鎖的網站（應 attach 失敗）＋開未封鎖的網站（應正常）。"
}

do_restore() {
  [ -d "$BACKUP_DIR" ] || { echo "沒有任何備份。"; exit 0; }
  local files=()
  while IFS= read -r f; do files+=("$f"); done < <(ls -1t "$BACKUP_DIR"/*-defaults-*.plist 2>/dev/null)
  [ "${#files[@]}" -gt 0 ] || { echo "沒有任何備份。"; exit 0; }
  local i
  for i in "${!files[@]}"; do echo "  [$((i + 1))] $(basename "${files[$i]}")"; done
  read -r -p "選擇要還原的備份編號: " n
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#files[@]}" ] || { echo "無效編號。"; exit 1; }
  local f="${files[$((n - 1))]}"
  local b; case "$(basename "$f")" in edge-*) b="edge";; *) b="chrome";; esac
  local domain; domain="$(browser_domain "$b")"
  read -r -p "還原 $(browser_label "$b") 到 $(basename "$f") 的狀態？ (y/N): " go
  [[ "$go" =~ ^[Yy]$ ]] || { echo "已取消。"; exit 0; }
  defaults delete "$domain" 2>/dev/null || true
  defaults import "$domain" "$f"
  echo "✓ 已還原。記得完全重啟 $(browser_label "$b")。"
}

action="${1:-}"
if [ -z "$action" ]; then
  echo "ai-browser-lockdown (macOS, EXPERIMENTAL) — [1] 上鎖  [2] 狀態  [3] 還原"
  read -r -p "選擇動作 (1/2/3): " c
  case "$c" in 1) action=lock;; 2) action=status;; 3) action=restore;; *) echo "無效選擇"; exit 1;; esac
fi
case "$action" in
  lock) do_lock;; status) do_status;; restore) do_restore;;
  *) echo "用法: $0 [lock|status|restore]"; exit 1;;
esac
