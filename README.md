# ai-browser-lockdown

[繁體中文](README.zh-TW.md)

Lock AI browser-control extensions out of your bank, broker, and mailbox — while letting them automate everything else.

## The problem

AI coding agents can drive your real browser through extensions (Kimi WebBridge, Claude in Chrome, and similar). Some of these use the `chrome.debugger` API with `<all_urls>` host permissions: they get **your logged-in identity on every site, all at once**.

The counter-intuitive part, confirmed by hands-on testing (2026-08-09, Edge on Windows):

> **The per-site "site access" whitelist in the extensions UI does NOT stop debugger-based extensions.** That UI only withholds `host_permissions` (content scripts, webRequest). The `debugger` API permission is granted globally — the extension can still attach to any tab, read the page, and run JavaScript, even on sites you removed from its list.

The only per-host control that actually works is the **enterprise policy layer**: `ExtensionSettings` → `runtime_blocked_hosts`. With it set, the extension gets `Cannot attach to this target` on blocked sites and works normally everywhere else. Verified in both directions on a real setup (13 blocked hosts refused, unblocked automation targets unaffected).

This tool makes that policy a guided, reversible, one-command setup.

## What it does

1. **Detects** installed extensions holding the `debugger` permission (the risky class), across all browser profiles.
2. **Lets you pick** what to protect: a starter catalog of verified Taiwan bank / broker / Gmail login hosts, plus any host you add (paste the login-page URL — the host is extracted for you).
3. **Backs up** the current policy, then **merges** (never overwrites) your blocked hosts into `ExtensionSettings`.
4. **Verifies** by reading the policy back, and walks you through the live test: blocked site must fail to attach, normal site must still work.
5. **Restores** any backup with one command.

## Usage

### Windows (Edge + Chrome) — tested

Run in an **elevated** PowerShell (the policy lives in HKLM):

```powershell
git clone https://github.com/drpwchen/ai-browser-lockdown
cd ai-browser-lockdown\windows
.\lockdown.ps1              # interactive menu: lock / status / restore
.\lockdown.ps1 -Action status    # read-only, no admin needed
```

After writing, **fully quit and restart the browser** (all windows and background processes), check `edge://policy` / `chrome://policy` shows `ExtensionSettings`, then live-test both directions.

### macOS (Edge + Chrome) — EXPERIMENTAL

```bash
cd ai-browser-lockdown/macos
./lockdown.sh
```

⚠️ The macOS path writes user-level `defaults`, which **some browser builds do not honor as mandatory policy** (they only trust MDM / Managed Preferences). The script therefore makes the browser-side verification step mandatory: if `ExtensionSettings` does not appear in `edge://policy` / `chrome://policy`, this approach does not work on your setup and you need an MDM profile instead. **Not yet verified on real hardware** — treat every claim on this path as unconfirmed until you have run the live test yourself.

## Design decisions

- **Exact hosts, never `*.domain` wildcards.** Blocking `*.esunbank.com.tw` would also kill `card.esunbank.com.tw` — the credit-card / event-registration subdomains are often exactly what you *want* automation to keep doing. Precision is the point.
- **Merge, don't clobber.** Existing `ExtensionSettings` content (other extensions, other settings on the same extension) is preserved; blocked-host lists are unioned. Every write is preceded by a timestamped backup under `~/.ai-browser-lockdown/backups/`.
- **Catalog entries are verified, or they don't ship.** Every host in `catalog/hosts.json` was confirmed by opening the real login page and copying the host from the address bar. Search-engine memory is not a source — stale indexes list dead hosts (we found one), and personal vs corporate banking often live on different hosts.

## Limitations — read this

- **A blacklist only blocks what you enumerate.** New bank account → come back and add its host. This is inherent to the mechanism.
- **Admin on the machine can undo it.** This protects against your AI agent wandering into your bank with your logged-in session; it does not protect against malicious local software or anyone with admin rights.
- The deeper residual risk of AI browser control is **prompt injection**: an agent reading a hostile page while your critical accounts are logged in elsewhere in the same browser. This tool removes the worst targets from its reach; the habit of not mixing untrusted browsing with logged-in critical sessions is still on you.
- An airtight alternative: run automation in a **separate browser profile that is never logged in** to anything critical. More setup friction, no enumeration problem.

## Contributing catalog entries

PRs adding bank/broker host groups are welcome, with one hard rule: **every host must be verified by actually opening the login page and copying the host from the address bar**, and the entry must carry the verification date. Please also note sibling subdomains that should stay open (credit-card portals, account opening, marketing sites).

## License

MIT
