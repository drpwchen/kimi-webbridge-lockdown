#!/bin/bash
# ai-browser-lockdown — macOS
#
# Writes the ExtensionSettings policy (runtime_blocked_hosts) for Microsoft Edge /
# Google Chrome into /Library/Managed Preferences, which is the ONLY layer macOS
# browsers treat as *mandatory* policy.
#
# Verified on macOS 26.5.2 with Chrome 151 + a real debugger-permission extension
# (2026-08-09), in both directions:
#
#   user defaults (`defaults write com.google.Chrome`)
#       -> chrome://policy shows level "Recommended", status "Valid"
#       -> chrome.debugger.attach on a blocked host STILL SUCCEEDS.  No protection.
#   /Library/Managed Preferences/com.google.Chrome.plist (root:wheel, 644)
#       -> chrome://policy shows level "Mandatory", scope "Machine"
#       -> chrome.debugger.attach on a blocked host fails:
#          "Cannot attach to this target."   Unblocked hosts keep working.
#
# That is why this script needs sudo: without root-owned managed preferences the
# policy is cosmetic. v0.1.0 wrote user defaults and did not protect anything.
#
# Usage:  ./lockdown.sh [lock|status|restore]
set -euo pipefail

BACKUP_DIR="$HOME/.ai-browser-lockdown/backups"
MANAGED_DIR="/Library/Managed Preferences"

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
policy_page()    { [ "$1" = "edge" ] && echo "edge://policy" || echo "chrome://policy"; }
managed_plist()  { echo "$MANAGED_DIR/$(browser_domain "$1").plist"; }

normalize_host() {
  # Accept "host", "*://host" or a pasted URL; print a bare lowercase hostname.
  # Returns 1 (printing nothing) if the input cannot be reduced to one.
  local h="$1"
  h="$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  h="${h#\*://}"
  case "$h" in *://*) h="${h#*://}";; esac
  h="${h%%[/?#]*}"   # drop path / query / fragment
  h="${h##*@}"       # drop userinfo  (user:pw@host -> host)
  h="${h%%:*}"       # drop port      (host:443    -> host)
  h="${h%.}"         # drop trailing dot
  # Chrome match patterns take a plain hostname: [a-z0-9-] labels separated by dots.
  # Anything else (bare words, bracketed IPv6, stray punctuation) is rejected rather
  # than written as a pattern Chrome would silently discard.
  case "$h" in
    "" | -* | *- | *[!a-z0-9.-]* | *..* ) return 1;;
    *.* ) ;;
    * ) return 1;;   # no dot: not a public host, almost always a typo
  esac
  printf '%s\n' "$h"
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

blocked_patterns_for() {
  # Existing runtime_blocked_hosts for extension $2 in plist $1, one per line.
  # plutil's JSON escapes forward slashes ("*:\/\/host"); unescape or dedup silently
  # fails and every re-run appends a duplicate of what is already blocked.
  plutil -extract "ExtensionSettings.$2.runtime_blocked_hosts" json -o - "$1" 2>/dev/null \
    | tr ',' '\n' | tr -d '[]"' | sed 's|\\/|/|g' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' || true
}

do_status() {
  local b domain managed
  for b in edge chrome; do
    echo ""
    echo "=== $(browser_label "$b") ==="
    [ -d "$(browser_appdir "$b")" ] || { echo "  （未偵測到安裝）"; continue; }
    echo "  帶 debugger 權限的擴充："
    scan_debugger_extensions "$b" | sed 's/^/    /' || true
    domain="$(browser_domain "$b")"
    managed="$(managed_plist "$b")"
    echo "  強制政策層 ${managed}："
    if [ -f "$managed" ]; then
      plutil -p "$managed" 2>/dev/null | sed 's/^/    /'
    else
      echo "    （未設定 — 目前沒有任何強制封鎖）"
    fi
    if defaults read "$domain" ExtensionSettings >/dev/null 2>&1; then
      echo "  ⚠ user defaults 層也有 ExtensionSettings（v0.1.0 遺留）："
      defaults read "$domain" ExtensionSettings | sed 's/^/    /'
      echo "    這一層是「建議採用」等級，經實測「不會」阻擋 debugger attach，只會讓"
      echo "    $(policy_page "$b") 看起來有設定。清掉：defaults delete $domain ExtensionSettings"
    fi
  done
  echo ""
  echo "驗證方式：開 chrome://policy / edge://policy，ExtensionSettings 的「等級」必須是"
  echo "「強制 Mandatory」。顯示「建議採用 Recommended」＝沒有保護。"
}

do_lock() {
  echo "要設定哪個瀏覽器？ [1] Edge  [2] Chrome"
  read -r -p "選擇 (1/2): " bc
  local b
  case "$bc" in
    1) b="edge";;
    2) b="chrome";;
    *) echo "無效選擇「${bc}」，結束。"; exit 1;;
  esac
  local domain managed; domain="$(browser_domain "$b")"; managed="$(managed_plist "$b")"

  echo ""
  echo "偵測到的 debugger 擴充（AI 瀏覽器控制工具屬於這類）："
  scan_debugger_extensions "$b" | sed 's/^/  /' || true
  read -r -p "輸入要封鎖的擴充 ID（32 碼小寫字母，逗號分隔可多個）: " extinput
  local extids=() eid
  for eid in ${extinput//,/ }; do
    if [[ "$eid" =~ ^[a-p]{32}$ ]]; then extids+=("$eid")
    else echo "「${eid}」不是合法擴充 ID，結束。"; exit 1; fi
  done
  [ "${#extids[@]}" -gt 0 ] || { echo "沒有輸入擴充 ID，結束。"; exit 1; }

  echo ""
  echo "選擇要封鎖的網站群組（皆為實地驗證過的登入 host）："
  local i
  for i in "${!GROUP_LABELS[@]}"; do
    echo "  [$((i + 1))] ${GROUP_LABELS[$i]}  → ${GROUP_HOSTS[$i]}"
  done
  read -r -p "輸入編號（逗號分隔，all 全選，Enter 跳過）: " picks
  local hosts=() h tok
  if [ "$picks" = "all" ]; then
    for i in "${!GROUP_HOSTS[@]}"; do for h in ${GROUP_HOSTS[$i]}; do hosts+=("$h"); done; done
  elif [ -n "$picks" ]; then
    for tok in ${picks//,/ }; do
      if [[ "$tok" =~ ^[0-9]+$ ]] && [ "$tok" -ge 1 ] && [ "$tok" -le "${#GROUP_HOSTS[@]}" ]; then
        for h in ${GROUP_HOSTS[$((tok - 1))]}; do hosts+=("$h"); done
      else echo "  無效編號「${tok}」（略過）"; fi
    done
  fi
  read -r -p "自訂 host（逗號分隔，可貼登入頁網址，Enter 跳過）: " custom
  if [ -n "$custom" ]; then
    local nh
    for tok in ${custom//,/ }; do
      if nh="$(normalize_host "$tok")"; then hosts+=("$nh")
      else echo "  「${tok}」無法解析為合法 host（略過）"; fi
    done
  fi
  [ "${#hosts[@]}" -gt 0 ] || { echo "沒有選擇任何 host，結束。"; exit 1; }

  # --- build the merged plist in a temp file (never edit the live one in place) ---
  local tmp; tmp="$(mktemp -t aibl)"
  trap 'rm -f "$tmp"' EXIT
  if [ -f "$managed" ]; then cp "$managed" "$tmp"; else plutil -create xml1 "$tmp"; fi
  plutil -extract ExtensionSettings json -o - "$tmp" >/dev/null 2>&1 \
    || plutil -insert ExtensionSettings -json '{}' "$tmp"

  echo ""
  echo "即將寫入 $(browser_label "$b") 的強制封鎖規則（${managed}）："
  local eid2 merged seen arr p
  for eid2 in "${extids[@]}"; do
    plutil -extract "ExtensionSettings.$eid2" json -o - "$tmp" >/dev/null 2>&1 \
      || plutil -insert "ExtensionSettings.$eid2" -json '{}' "$tmp"
    # union: keep every pattern already blocked, add the new ones
    merged=(); seen=" "
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      case "$seen" in *" $p "*) continue;; esac
      seen="$seen$p "; merged+=("$p")
    done < <(blocked_patterns_for "$tmp" "$eid2")
    local kept="${#merged[@]}"
    for h in "${hosts[@]}"; do
      p="*://$h"
      case "$seen" in *" $p "*) continue;; esac
      seen="$seen$p "; merged+=("$p")
    done
    arr=""
    for p in "${merged[@]}"; do [ -n "$arr" ] && arr="$arr,"; arr="$arr\"$p\""; done
    plutil -remove "ExtensionSettings.$eid2.runtime_blocked_hosts" "$tmp" >/dev/null 2>&1 || true
    plutil -insert "ExtensionSettings.$eid2.runtime_blocked_hosts" -json "[$arr]" "$tmp"
    echo "  擴充 $eid2 — 保留既有 $kept 條，合併後共 ${#merged[@]} 條："
    for p in "${merged[@]}"; do echo "      $p"; done
  done
  plutil -lint "$tmp" >/dev/null || { echo "產生的 plist 不合法，中止。"; exit 1; }

  echo ""
  echo "寫入 $MANAGED_DIR 需要管理員權限（這是 macOS 唯一會當成強制政策的位置）。"
  read -r -p "確定寫入？ (y/N): " go
  [[ "$go" =~ ^[Yy]$ ]] || { echo "已取消。"; exit 0; }

  mkdir -p "$BACKUP_DIR"
  if [ -f "$managed" ]; then
    local backup; backup="$BACKUP_DIR/$b-managed-$(date +%Y%m%d-%H%M%S).plist"
    cp "$managed" "$backup"
    echo "已備份現況 → $backup"
  else
    local marker; marker="$BACKUP_DIR/$b-managed-$(date +%Y%m%d-%H%M%S).absent"
    : > "$marker"
    echo "先前無強制政策檔，已留還原標記 → $marker"
  fi

  sudo mkdir -p "$MANAGED_DIR"
  sudo cp "$tmp" "$managed"
  sudo chown root:wheel "$managed"
  sudo chmod 644 "$managed"
  echo "✓ 已寫入。讀回："
  plutil -p "$managed" | sed 's/^/  /'

  # v0.1.0 wrote an ineffective user-defaults copy; leaving it there is misleading.
  if defaults read "$domain" ExtensionSettings >/dev/null 2>&1; then
    echo ""
    echo "偵測到 user defaults 層還有 v0.1.0 寫的 ExtensionSettings（無效，只會誤導）。"
    read -r -p "要清掉嗎？ (y/N): " cl
    [[ "$cl" =~ ^[Yy]$ ]] && { defaults delete "$domain" ExtensionSettings; echo "  已清除。"; }
  fi

  echo ""
  echo "接下來："
  echo "  1. 完全關閉 $(browser_label "$b")（Cmd+Q）再重開。"
  echo "  2. 開 $(policy_page "$b") — ExtensionSettings 的「等級」必須是「強制 Mandatory」。"
  echo "     顯示「建議採用 Recommended」＝沒有保護，請回報 issue。"
  echo "  3. 實測兩個方向：叫 AI 工具開被封鎖的網站（應出現 Cannot attach to this target）"
  echo "     ＋開未封鎖的網站（應正常）。"
}

do_restore() {
  [ -d "$BACKUP_DIR" ] || { echo "沒有任何備份。"; exit 0; }
  local files=() f
  while IFS= read -r f; do files+=("$f"); done < <(ls -1t "$BACKUP_DIR"/*-managed-* "$BACKUP_DIR"/*-defaults-*.plist 2>/dev/null || true)
  [ "${#files[@]}" -gt 0 ] || { echo "沒有任何備份。"; exit 0; }
  local i
  for i in "${!files[@]}"; do echo "  [$((i + 1))] $(basename "${files[$i]}")"; done
  read -r -p "選擇要還原的備份編號: " n
  if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ] || [ "$n" -gt "${#files[@]}" ]; then
    echo "無效編號。"; exit 1
  fi
  f="${files[$((n - 1))]}"
  local b; case "$(basename "$f")" in edge-*) b="edge";; *) b="chrome";; esac
  local domain managed; domain="$(browser_domain "$b")"; managed="$(managed_plist "$b")"
  read -r -p "還原 $(browser_label "$b") 到 $(basename "$f") 的狀態？ (y/N): " go
  [[ "$go" =~ ^[Yy]$ ]] || { echo "已取消。"; exit 0; }
  case "$f" in
    *.absent)   sudo rm -f "$managed"; echo "✓ 已移除強制政策檔（還原為「原本就沒有」）。";;
    *-managed-*) sudo cp "$f" "$managed"; sudo chown root:wheel "$managed"; sudo chmod 644 "$managed"
                 echo "✓ 已還原強制政策檔。";;
    *-defaults-*) # legacy v0.1.0 backup of the whole user-defaults domain
                 defaults delete "$domain" 2>/dev/null || true
                 defaults import "$domain" "$f"
                 echo "✓ 已還原 user defaults（v0.1.0 遺留層）。";;
  esac
  echo "記得完全重啟 $(browser_label "$b")。"
}

action="${1:-}"
if [ -z "$action" ]; then
  echo "ai-browser-lockdown (macOS) — [1] 上鎖  [2] 狀態  [3] 還原"
  read -r -p "選擇動作 (1/2/3): " c
  case "$c" in 1) action=lock;; 2) action=status;; 3) action=restore;; *) echo "無效選擇"; exit 1;; esac
fi
case "$action" in
  lock) do_lock;; status) do_status;; restore) do_restore;;
  *) echo "用法: $0 [lock|status|restore]"; exit 1;;
esac
