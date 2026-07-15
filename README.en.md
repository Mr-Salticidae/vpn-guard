# vpn-guard · VPN Exit-Node Consistency / Anti-Leak Toolkit

![vpn-guard — VPN exit-node consistency / anti-leak toolkit](assets/social-preview.jpg)

**English** | [中文](README.md)

[![verify](https://github.com/Mr-Salticidae/vpn-guard/actions/workflows/verify.yml/badge.svg)](https://github.com/Mr-Salticidae/vpn-guard/actions/workflows/verify.yml)
(every push runs on real cloud macOS + Linux: syntax / shellcheck / leak audit / real-Chrome `TZ` verification)

> A cross-platform toolkit (PowerShell for **Windows**, Bash for **macOS / Linux**) to
> **audit VPN leaks** (IP / DNS / WebRTC / IPv6) and keep your browser fingerprint
> (timezone / locale) **consistent with the exit-node country**, so geo-fingerprinting
> doesn't flag "this user is on a VPN".
>
> Works with all mainstream proxy clients — **Clash / Mihomo, V2Ray / Xray (v2rayN),
> sing-box, Shadowsocks, Hysteria, WireGuard, OpenVPN** — by detecting *how* traffic is
> taken over (TUN interface / system proxy / local port only) instead of hard-coding any
> specific client.

**Why**: A VPN changes your IP, but your browser still reports the **local system timezone
and language**. When your IP says Tokyo but JavaScript reports UTC+8 with `zh-CN`, any
serious geo-fingerprinting system knows you're on a proxy — the IP is right, but the
fingerprint gives you away. This toolkit aligns IP / DNS / WebRTC / timezone / locale to
the same country.

> ⚠️ Intended for legitimate use: accessing academic / research / public resources blocked
> by regional restrictions, and personal privacy protection. Follow the laws of your
> jurisdiction and the terms of service of the platforms you visit.

---

## Requirements

| | Windows | macOS / Linux |
|---|---|---|
| Script runtime | Windows PowerShell 5.1 (built into Win10/11) | bash 3.2+ / curl (built in) |
| Browser | Google Chrome | Google Chrome or Chromium |
| Proxy / VPN | Clash / Mihomo, V2Ray / Xray (v2rayN etc.), sing-box, Shadowsocks, Hysteria, WireGuard, OpenVPN… | same |
| Network | Access to `ip-api.com` (free, no API key) for exit-node probing | same |

> The toolkit adapts to the **traffic-takeover mode**, decoupled from any client brand:
>
> | Takeover mode | Typical setup | Toolkit behavior |
> |---|---|---|
> | **TUN / virtual NIC** | Clash Verge TUN, sing-box tun, WireGuard, OpenVPN | Global takeover (incl. UDP/WebRTC) — audit reports OK |
> | **System proxy / PAC** | v2rayN default, Clash system proxy | Browser is fine, but audit warns "proxy-unaware apps and UDP/WebRTC may bypass" |
> | **Local port only** | v2ray with just a SOCKS/HTTP inbound | Audit warns loudly; browsing session takes a `--proxy` flag to route Chrome through the port |

## Install

```bash
git clone https://github.com/<you>/vpn-guard.git
cd vpn-guard
chmod +x *.sh        # macOS / Linux only (git usually preserves the executable bit)
```

The scripts use **their own directory** as the working directory — clone anywhere and run
directly, no path edits needed.

## Usage

### 1. `vpn-leak-audit` — one-shot leak audit (read-only, changes nothing)

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File .\vpn-leak-audit.ps1
```
```bash
# macOS / Linux
./vpn-leak-audit.sh
```

Reports with red / yellow / green: **detected proxy client and traffic-takeover mode**
(TUN / system proxy / none — each with its leak surface), public IP + geolocation,
proxy/hosting flags, IPv6 leak surface, **timezone consistency** (system vs exit IP),
locale consistency, whether DNS resolution leaks to your local ISP, and a
**WebRTC active-detection entry point**. Re-run after switching nodes or countries.

<details>
<summary>Sample output (illustrative, not real data)</summary>

```
0) Proxy client & traffic-takeover mode
  Client processes : verge-mihomo
  [ OK ] TUN mode — all traffic (incl. UDP/WebRTC) is taken over
1) Public exit IP & geolocation
  Location  : <City> / <Country> (XX)
  [ OK ] not flagged as proxy
  [ OK ] not flagged as hosting/datacenter IP
2) IPv6 leak surface   [ OK ] no public IPv6 egress
3) Timezone check      [FAIL] system UTC+8 vs exit UTC+9, off by +1h  ← #1 giveaway
4) Language / locale   [WARN] browser default language doesn't match exit country
5) DNS resolution path [ OK ] fake-ip tunnel resolution
6) WebRTC leak surface [ OK ] test page ready — run: browse-vpn --webrtc
```
</details>

### 2. `browse-vpn` — consistent browsing session (**the main tool**)

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File .\browse-vpn.ps1            # auto-detect exit country
powershell -ExecutionPolicy Bypass -File .\browse-vpn.ps1 -DryRun    # preview only, change nothing
powershell -ExecutionPolicy Bypass -File .\browse-vpn.ps1 -Country US  # force a country preset
powershell -ExecutionPolicy Bypass -File .\browse-vpn.ps1 -Proxy http://127.0.0.1:10809
    # client only exposes a local port (no system proxy / TUN)? route Chrome through it
    # (v2rayN's default HTTP port is 10809)
```
```bash
# macOS / Linux
./browse-vpn.sh                                  # auto-detect exit country
./browse-vpn.sh --dry-run                        # preview only
./browse-vpn.sh US                               # force a country preset
./browse-vpn.sh --proxy=socks5://127.0.0.1:1080  # local-port-only setups: probe and Chrome both use it
./browse-vpn.sh --webrtc                         # also open the WebRTC leak test page
```
(`browse-vpn.ps1 -WebRTC` on Windows does the same.)

> Before launching, the script checks the takeover mode: with no TUN, no system proxy and
> no `--proxy`, it **warns in red** — in that state Chrome would connect directly and expose
> your real IP. v2ray-family users without system proxy enabled should pass `--proxy`.
> (On Windows PS5.1 the exit probe only supports `http://` proxies — v2rayN users should use
> the HTTP port 10809; curl on macOS/Linux supports `socks5://` natively.)

What it does: **probes the current exit country** → launches an isolated Chrome profile with
matching timezone and language, browser DoH disabled so DNS goes through the tunnel.
**One script adapts to every exit country** — after switching nodes, just run it again.

Platform difference (where the Unix version is nicer):

- **Windows**: Chrome ignores the `TZ` environment variable, so the script temporarily
  switches the system timezone via `tzutil` and restores it automatically when you close
  that Chrome window (guaranteed by `finally`). The system clock follows the exit country
  during the session — that's expected.
- **macOS / Linux**: Chrome honors `TZ`, so the script just launches Chrome with
  `TZ=<exit IANA timezone>` — **only that browser process is affected; the system timezone
  is never touched**, so there's nothing to restore.

> Key design: the timezone always follows the **real exit IP** (not the country argument),
> so you never end up with a new contradiction like "IP in Tokyo, timezone set to New York".

### 3. `webrtc-leak-test.html` — active WebRTC leak detection

To punch through NATs, WebRTC sends UDP to a STUN server and gets back "the public IP the world
sees for you". **If that UDP doesn't go through the VPN tunnel, it reveals your real IP** — even
though the page's HTTP requests show the exit IP. System-proxy mode can't stop it; only TUN mode
can. Since this is a browser API that command-line audits can't reach, it ships as a dedicated
active test page:

- **Recommended**: `browse-vpn.ps1 -WebRTC` / `./browse-vpn.sh --webrtc` — opens the test page
  inside the consistency session (the real tunnel), closest to real use.
- Or just open `webrtc-leak-test.html` directly in any browser.

The page runs a real STUN probe, compares the WebRTC reflexive candidate (srflx) against your exit
IP, and gives a verdict: **consistent** (safe) / **leak** (a public IP different from the exit is
exposed, highlighted in red) / **no srflx** (UDP is fully tunneled — no leak surface). Pure
front-end, no external dependencies beyond public STUN servers, uploads nothing.

> Fixing a leak: disable WebRTC via a browser extension, or have your client take over all UDP in
> **TUN mode**.

### 4. Per-country shortcuts (Windows, double-click / no arguments to remember)

`browse-jp` Japan · `browse-us` US · `browse-sg` Singapore · `browse-hk` Hong Kong ·
`browse-gb` UK · `browse-de` Germany · `browse-kr` Korea.
Each is equivalent to `browse-vpn.ps1 -Country XX` and supports `-DryRun`.
On macOS / Linux just pass the country code (`./browse-vpn.sh jp`) — no shortcut files needed.

**Built-in presets** (timezone + language): JP / KR / SG / HK / TW / GB / DE / FR / NL / US /
CA / AU. Multi-timezone countries (US / CA / AU) resolve to the exact region detected
(Eastern / Central / Pacific…). **Countries without a preset**: when probing succeeds, the
timezone comes straight from the exit's IANA timezone (native on Unix; mapped via a table /
UTC-offset match on Windows), the language falls back to `en-US` with a confirmation prompt.
To add a country, edit `$presets` at the top of `browse-vpn.ps1` / the `preset()` function
in `browse-vpn.sh`.

## How it works

| Signal | Windows | macOS / Linux |
|---|---|---|
| Timezone | `tzutil /s` temporarily switches the system timezone (Chrome ignores `TZ`), auto-restored via `finally` when the session ends | Chrome launched with `TZ=<IANA timezone>` — process-scoped, system timezone untouched |
| Language | Chrome `--lang` / `--accept-lang` + `intl.selected_languages` in the isolated profile; system locale untouched | same |
| DNS | "Secure DNS (DoH)" disabled in the isolated Chrome profile, forcing system DNS (TUN mode = fake-ip tunnel; in system-proxy mode hostnames are resolved remotely by the proxy), so the browser can't leak its own lookups | same |
| IP | Taken over by TUN / system proxy / `--proxy`; the toolkit audits the takeover mode and flags the IPv6 leak surface | same |
| WebRTC | `webrtc-leak-test.html` active detection: real STUN probe, compares srflx vs exit IP for a leak verdict; `browse-vpn --webrtc` runs it inside the real tunnel | same (pure front-end, identical cross-platform) |

> Isolated Chrome profiles live in `chrome-<country>-profile/` (git-ignored, never committed).
> Both platforms share the same directory naming.

## Caveats

- This only fixes *technical* signals. Account-level behavior (login history, payment
  region, shipping addresses) is not covered — keep those consistent yourself.
- **Windows only**: switching the system timezone makes **every program's** clock follow the
  exit country during the session; local-time-triggered scheduled tasks shift accordingly —
  expected, and auto-restored when the browser closes. The macOS / Linux version never
  touches the system timezone.
- The macOS / Linux scripts rely on the local tzdata database to resolve IANA timezone names
  (present on mainstream systems; minimal container images may need `tzdata` installed —
  the script warns when it can't find it).
- The leak audit classifies by **takeover mode** (TUN / system proxy / local port only) and
  applies to all mainstream clients (Clash/Mihomo, V2Ray/Xray, sing-box, SS, WireGuard,
  OpenVPN); the `198.18.x` fake-ip signature covers Clash/Mihomo/sing-box/Xray fakedns.
- In system-proxy mode the browser is safe, but UDP/WebRTC and proxy-unaware apps may
  bypass the proxy — enable your client's TUN mode for full coverage.

## License

MIT, see [LICENSE](LICENSE).
