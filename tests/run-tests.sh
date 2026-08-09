#!/bin/bash
# Logic tests for macos/lockdown.sh — no browser, no sudo, no real policy file touched.
# Run:  tests/run-tests.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../macos/lockdown.sh"
WORK="$(mktemp -d -t aibl-tests)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi; }
has()  { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "output containing '$3'" "$2";; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "output WITHOUT '$3'" "$2";; *) ok "$1";; esac; }

# Function library = everything above the dispatch tail.
sed -n '1,/^action=/p' "$SCRIPT" | sed '$d' > "$WORK/lib.sh"

# A fake browser profile with one debugger extension and one harmless one.
FAKE="$WORK/profile"
EXT_A=abcdefghijklmnopabcdefghijklmnop
EXT_B=ponmlkjihgfedcbaponmlkjihgfedcba
mkdir -p "$FAKE/Default/Extensions/$EXT_A/1.0_0" "$FAKE/Default/Extensions/$EXT_B/2.0_0"
printf '{"name":"Fake AI Control","permissions":["debugger","tabs"]}' \
  > "$FAKE/Default/Extensions/$EXT_A/1.0_0/manifest.json"
printf '{"name":"Harmless","permissions":["storage"]}' \
  > "$FAKE/Default/Extensions/$EXT_B/2.0_0/manifest.json"

cat > "$WORK/harness.sh" <<'EOS'
#!/bin/bash
source "$WORK/lib.sh"
BACKUP_DIR="$WORK/backups"
MANAGED_DIR="$WORK/managed"
browser_domain() { echo "com.test.aibl"; }
browser_appdir() { echo "$FAKE"; }
defaults() { return 1; }                       # never touch real user defaults
sudo() { case "$1" in chown|chmod|mkdir) return 0;; *) "$@";; esac; }
"$@"
EOS
chmod +x "$WORK/harness.sh"
export WORK FAKE
mkdir -p "$WORK/managed" "$WORK/backups"
run()  { "$WORK/harness.sh" "$@" 2>&1; }
feed() { printf '%s\n' "$@"; }   # answers for the interactive prompts, one per line
PLIST="$WORK/managed/com.test.aibl.plist"

echo "normalize_host — accepts and canonicalises"
# shellcheck source=/dev/null
nh() { ( . "$WORK/lib.sh"; normalize_host "$1" 2>/dev/null ) || echo "__REJECTED__"; }
is "bare host"            "$(nh 'mail.google.com')"                       "mail.google.com"
is "full URL + fragment"  "$(nh 'HTTPS://Mail.Google.COM/mail/u/0/#in')"  "mail.google.com"
is "match-pattern form"   "$(nh '*://ebank.esunbank.com.tw')"             "ebank.esunbank.com.tw"
is "surrounding spaces"   "$(nh '  richart.tw  ')"                        "richart.tw"
is "trailing dot"         "$(nh 'www.ubot.com.tw.')"                      "www.ubot.com.tw"
is "port stripped"        "$(nh 'https://client.schwab.com:443/Login')"   "client.schwab.com"
is "userinfo stripped"    "$(nh 'https://user:pw@evil.com/path')"         "evil.com"

echo "normalize_host — rejects what Chrome would silently discard"
is "bare word"            "$(nh 'not-a-url')"     "__REJECTED__"
is "sentence"             "$(nh 'hello world')"   "__REJECTED__"
is "bracketed IPv6"       "$(nh 'http://[::1]:8080/x')" "__REJECTED__"
is "empty"                "$(nh '')"              "__REJECTED__"
is "leading dash"         "$(nh '-bad.com')"      "__REJECTED__"
is "empty label"          "$(nh 'a..b.com')"      "__REJECTED__"
is "underscore"           "$(nh 'bad_host.com')"  "__REJECTED__"

echo "scan_debugger_extensions"
out="$(run scan_debugger_extensions chrome)"
has   "finds the debugger extension"       "$out" "$EXT_A"
hasnt "ignores the non-debugger extension" "$out" "$EXT_B"

echo "lock — first write"
out="$(feed 2 "$EXT_A" 3,8 "" y | run do_lock)"
has "reports 0 kept on a fresh policy" "$out" "保留既有 0 條，合併後共 2 條"
has "records an absent-marker backup"  "$out" ".absent"
is  "wrote esunbank" "$(plutil -extract ExtensionSettings.$EXT_A.runtime_blocked_hosts.0 raw -o - "$PLIST")" "*://ebank.esunbank.com.tw"
is  "wrote gmail"    "$(plutil -extract ExtensionSettings.$EXT_A.runtime_blocked_hosts.1 raw -o - "$PLIST")" "*://mail.google.com"

echo "lock — merge semantics"
out="$(feed 2 "$EXT_A" 5 "" y | run do_lock)"
has "unions instead of replacing" "$out" "保留既有 2 條，合併後共 3 條"
out="$(feed 2 "$EXT_A" 3 "" y | run do_lock)"
has "re-adding an existing host is idempotent" "$out" "保留既有 3 條，合併後共 3 條"

plutil -insert "ExtensionSettings.$EXT_A.installation_mode" -string force_installed "$PLIST" >/dev/null
plutil -insert "UnrelatedPolicy" -string keep-me "$PLIST" >/dev/null
feed 2 "$EXT_A" 7 "" y | run do_lock >/dev/null
is "sibling key on the same extension survives" \
   "$(plutil -extract ExtensionSettings.$EXT_A.installation_mode raw -o - "$PLIST")" "force_installed"
is "unrelated policy survives" \
   "$(plutil -extract UnrelatedPolicy raw -o - "$PLIST")" "keep-me"

feed 2 "$EXT_B" 8 "" y | run do_lock >/dev/null
is "a second extension does not disturb the first" \
   "$(plutil -extract ExtensionSettings.$EXT_A.runtime_blocked_hosts.0 raw -o - "$PLIST")" "*://ebank.esunbank.com.tw"
is "the second extension got its own list" \
   "$(plutil -extract ExtensionSettings.$EXT_B.runtime_blocked_hosts.0 raw -o - "$PLIST")" "*://mail.google.com"

echo "error paths — must report, not crash (bash 3.2 + set -u + UTF-8 locale)"
out="$(LC_ALL=zh_TW.UTF-8 feed 2 NOTVALID | LC_ALL=zh_TW.UTF-8 run do_lock)"
has   "bad extension ID is reported"  "$out" "不是合法擴充 ID"
hasnt "…without an unbound-variable crash" "$out" "unbound variable"
out="$(LC_ALL=zh_TW.UTF-8 feed 2 "$EXT_A" 99 "" | LC_ALL=zh_TW.UTF-8 run do_lock)"
has   "bad group number is reported"  "$out" "無效編號"
hasnt "…without an unbound-variable crash" "$out" "unbound variable"
out="$(LC_ALL=zh_TW.UTF-8 feed 2 "$EXT_A" "" "not a host" | LC_ALL=zh_TW.UTF-8 run do_lock)"
has   "unparseable host is reported"  "$out" "無法解析為合法 host"
hasnt "…without an unbound-variable crash" "$out" "unbound variable"
out="$(feed 3 | run do_lock)"
has "invalid browser choice is refused" "$out" "無效選擇"
out="$(feed 2 "$EXT_A" "" "" | run do_lock)"
has "selecting no hosts refuses to write" "$out" "沒有選擇任何 host"

echo "lock — non-interactive (agent-guided path)"
out="$(run do_lock chrome "$EXT_A" "www.ubot.com.tw,richart.tw" --yes)"
has "non-interactive lock merges" "$out" "保留既有 5 條，合併後共 6 條"
out="$(run do_lock chrome "$EXT_A" "not-a-url" --yes)" || true
has   "non-interactive bad host aborts loudly" "$out" "無法解析為合法 host"
out="$(run do_lock ie "$EXT_A" "mail.google.com" --yes)" || true
has   "non-interactive bad browser refused" "$out" "無效瀏覽器"

echo "unblock — non-interactive (agent-guided path)"
out="$(run do_unblock chrome "$EXT_A" "www.ubot.com.tw,richart.tw" --yes)"
has "reports remaining count" "$out" "剩 4 條封鎖"
has "read-back verification passes" "$out" "讀回驗證通過"
hosts_now="$(plutil -extract "ExtensionSettings.$EXT_A.runtime_blocked_hosts" json -o - "$PLIST")"
hasnt "removed host is gone"    "$hosts_now" "ubot"
has   "other hosts stay"        "$hosts_now" "ebank.esunbank.com.tw"
is "sibling key on the extension survives unblock" \
   "$(plutil -extract "ExtensionSettings.$EXT_A.installation_mode" raw -o - "$PLIST")" "force_installed"
is "unrelated policy survives unblock" \
   "$(plutil -extract UnrelatedPolicy raw -o - "$PLIST")" "keep-me"

out="$(run do_unblock chrome "$EXT_B" "mail.google.com" --yes)"
has "whole-list removal reported" "$out" "封鎖清單已全部解除"
if plutil -extract "ExtensionSettings.$EXT_B" json -o - "$PLIST" >/dev/null 2>&1; then
  bad "hosts-only extension entry removed entirely" "absent" "still present"
else
  ok "hosts-only extension entry removed entirely"
fi
is "first extension unaffected by second's unblock" \
   "$(plutil -extract "ExtensionSettings.$EXT_A.runtime_blocked_hosts.0" raw -o - "$PLIST")" "*://ebank.esunbank.com.tw"

echo "unblock — rejects what it cannot parse"
out="$(run do_unblock chrome "$EXT_A" "not-a-url" --yes)" || true
has   "invalid host rejected loudly" "$out" "無法解析為合法 host"
hasnt "…without an unbound-variable crash" "$out" "unbound variable"
has "nothing was removed" "$(plutil -extract "ExtensionSettings.$EXT_A.runtime_blocked_hosts" json -o - "$PLIST")" "ebank.esunbank.com.tw"

echo "unblock — interactive"
out="$(feed 2 "$EXT_A" all y | run do_unblock)"
has "interactive 'all' clears the list" "$out" "封鎖清單已全部解除"
is "sibling-keyed extension entry is kept" \
   "$(plutil -extract "ExtensionSettings.$EXT_A.installation_mode" raw -o - "$PLIST")" "force_installed"
if plutil -extract "ExtensionSettings.$EXT_A.runtime_blocked_hosts" json -o - "$PLIST" >/dev/null 2>&1; then
  bad "emptied host list key removed" "absent" "still present"
else
  ok "emptied host list key removed"
fi

echo "restore"
n="$(find "$WORK/backups" -type f | wc -l | tr -d ' ')"
out="$(feed "$n" y | run do_restore)"
has "restores the 'no policy file' state" "$out" "已移除強制政策檔"
if [ -f "$PLIST" ]; then bad "policy file actually removed" "no file" "file still there"; else ok "policy file actually removed"; fi

echo ""
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
