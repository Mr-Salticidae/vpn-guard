# vpn-guard · VPN Exit-Node Consistency / Anti-Leak Toolkit

![vpn-guard — VPN exit-node consistency / anti-leak toolkit](assets/social-preview.jpg)

**English** | [中文](README.md)

[![verify](https://github.com/Mr-Salticidae/vpn-guard/actions/workflows/verify.yml/badge.svg)](https://github.com/Mr-Salticidae/vpn-guard/actions/workflows/verify.yml)
[![version](https://img.shields.io/github/v/tag/Mr-Salticidae/vpn-guard?label=version)](https://github.com/Mr-Salticidae/vpn-guard/releases)
(every push runs on real cloud macOS + Linux: syntax / shellcheck / leak audit / real-Chrome `TZ` /
`app-vpn` process-scoped `TZ` injection verification / **exit-provenance classifier regression**
— a hard gate that diffs `.ps1` against `.sh` output byte for byte)

> A cross-platform toolkit (PowerShell for **Windows**, Bash for **macOS / Linux**) to
> **audit VPN leaks** (IP / DNS / WebRTC / IPv6) and keep your browser fingerprint
> (timezone / locale) **consistent with the exit-node country**, so your fingerprint stops
> contradicting your exit IP. (It does not stop a platform concluding you are on a VPN — the
> exit IP itself usually settles that; see the framing section below.)
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

## First, the honest framing: this preserves trust you already have — it cannot manufacture it

This is the most commonly misread thing about this repo, so it goes first.

Risk-control systems are almost always **cumulative scoring against a threshold**, not a single
kill switch. The factors that actually decide your fate, by weight:

| Weight | Factor | This toolkit |
|:---:|---|---|
| 1 | **Exit IP tenancy and reputation** — datacenter ranges; association bans when many accounts share one exit | ⚠️ half-covered: the provenance gate identifies datacenter ranges, but **nothing here can measure how many accounts sit behind an IP** |
| 2 | **Account provenance** — registration IP country, payment method country, account age, self-registered vs. bought/shared | ❌ **completely out of reach** |
| 3 | **Behavioral pattern** — country hopping (a client's auto-switch group creates impossible travel), one account on many devices, concurrency | ✅ exit-rotation detection |
| 4 | **Technical fingerprint** — timezone / locale / WebRTC / DNS inconsistency | ✅ `browse-vpn`, `app-vpn` |

**Layer 2 is the one high-weight factor no script can touch**, and it is precisely what explains
"same proxy, yet some people are never affected while others are banned repeatedly":

Risk control builds a **per-account baseline** for an aged account (what does normal look like *for
this account*), but can only fall back on a **population prior** for a new one (what are people with
these traits usually up to). For an account with years of continuous benign history, "logs in from a
proxy IP" was written into its baseline long ago and is not an anomaly. An account created last week
to sign up has no baseline to compare against, so it is judged against population priors — and the
prior for datacenter ranges is dreadful. **Identical exit IP, identical fingerprint, wildly
different outcome.**

So: installing these scripts will not make a fresh account safe. Their value is **keeping an already
clean account from bleeding score through technical sloppiness**. If your account keeps getting
banned and this toolkit doesn't help, the problem is probably in layer 2 — which no script
can fix.

---

## Scope — browser? desktop app? CLI?

A common misconception is that this toolkit only covers the browser. Here's the actual split:

| | Browser (Chrome) | Desktop apps (Claude / ChatGPT / Cursor — Electron) | CLIs (Codex CLI / Claude Code / git / curl) |
|---|---|---|---|
| `vpn-leak-audit` | ✅ all 8 checks | ✅ all but #7 (WebRTC) | ✅ all but #7 (WebRTC) |
| `browse-vpn` session | ✅ built for it | ❌ out of reach | ❌ out of reach |
| `app-vpn` session | — (use `browse-vpn`) | ✅ proxy / locale; timezone: see below | ✅ proxy / timezone / locale, all of it |
| `auto-select-node` | ✅ picks a safe + fast node and switches to it | same (it switches the global exit) | same |

**Desktop apps have a leak path the browser doesn't** — which is the whole reason `app-vpn` exists:

> Browsers and .NET programs read the OS proxy settings automatically. But **CLIs written in
> Node / Rust / Go (Codex CLI, Claude Code CLI) and Electron's Node main process do not** —
> they only honor the `HTTP_PROXY` / `HTTPS_PROXY` environment variables.
> So on a machine with **system proxy on but no TUN**: the browser is fine, while those
> programs connect directly and expose your real IP.
> **Check #2** of the audit tests exactly this path (it replays a "proxy-unaware program" with
> `curl --noproxy '*'` and compares the result against the browser's exit IP).

**Whether the timezone can be scoped per-process depends on the runtime, not the platform**
(all verdicts below are measured, not assumed):

| Target program | Honors `TZ` on Windows? | What the toolkit does |
|---|---|---|
| Node / Rust / Go CLIs | ✅ yes | `app-vpn.ps1` injects `TZ` directly — **system clock untouched** |
| Chromium / Electron GUI | ❌ no | needs `app-vpn.ps1 -SystemTz` to switch the system timezone temporarily, auto-restored on exit |
| **Anything** on macOS / Linux | ✅ yes (Chromium included) | always process-scoped `TZ`; system timezone never changes |

> In one line: **to cover every program in one shot, turn on your client's TUN mode.**
> `app-vpn` is the per-application answer when you don't have TUN (or when you also want a
> single program's timezone / locale aligned).

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
powershell -ExecutionPolicy Bypass -File .\vpn-leak-audit.ps1 -NoDnsLeak    # skip the networked DNS test
powershell -ExecutionPolicy Bypass -File .\vpn-leak-audit.ps1 -NoSpeedTest  # skip the link-quality test
```
```bash
# macOS / Linux
./vpn-leak-audit.sh
./vpn-leak-audit.sh --no-dns-leak     # skip the networked DNS test
./vpn-leak-audit.sh --no-speed-test   # skip the link-quality test
```

Reports with red / yellow / green: **detected proxy client and traffic-takeover mode**
(TUN / system proxy / none — each with its leak surface), public IP + geolocation,
proxy flag, **exit provenance** (residential/consumer vs datacenter/hosting),
**desktop-app / CLI exit consistency**, IPv6 leak surface,
**timezone consistency** (system vs exit IP), locale consistency, DNS resolution path
(static config + **active DNS-leak test**), a **WebRTC active-detection entry point**, and
**link quality** (handshake + throughput — is this node fast enough to watch video).
Re-run after switching nodes or countries.

> **Exit provenance** (check #1): `hosting=false` only means ip-api has no record for that
> range — it does **not** mean residential. In a real run, three small hosting shops
> (`IPS INC`, `Pittqiao Network Information`, `Mejiro Network Limited`) all reported
> `hosting=false`, and the old code told the user "reads like a residential / ordinary ISP" —
> which was simply wrong. The verdict is now three-state, decided by **ASN allocation era**, and
> **`unrecognized` is the default**: when the evidence is insufficient it says so, and never
> claims safety.
>
> **Note the two verdicts are not the same criterion**: the audit uses only allocation era plus
> the shared `residential-asn.txt` list; `auto-select-node` (§6) layers name-based signals on top
> as a weighted score. **The same exit can therefore get different verdicts from the two tools** —
> measured examples: a 32-bit ASN whose org name carries a carrier word reads `unrecognized` in
> the selector but "inferred datacenter" in the audit; a 16-bit ASN whose org name contains
> `Hosting` goes the other way. All the two share is the ASN list, and `verify-unix.sh` check #11
> mechanically proves that list has not drifted.

> **Desktop-app / CLI exit test** (check #2): fires a request via `curl --noproxy '*'` to
> replay what a *completely proxy-unaware program* would do, then compares it against the
> browser exit IP from check #1. **A mismatch means Claude / Codex-class programs are
> bypassing the proxy and connecting directly.** Passive inspection can't see this: the
> system proxy is enabled in the registry and the browser is perfectly fine, while the
> Node / Electron main process simply never reads it. On a leak verdict it prints both fixes
> (enable TUN, or launch via `app-vpn`).
>
> The same check doubles as **exit-rotation detection**. Under TUN, `--noproxy` only disables
> *proxy settings* — it does not change *routing* — so both observations still go through the
> tunnel. If the two IPs differ but share an ASN, the node sits behind a load-balanced pool
> rather than leaking: that prints a yellow "exit is rotating", not a red leak. This applies
> **only when the outbound route genuinely goes through the TUN adapter**; under system-proxy
> / PAC / no takeover, `curl` really is direct, so a differing IP *is* a real leak and stays red.

> **Active DNS-leak test** (on by default): triggers real resolution of random subdomains and
> checks *which resolvers actually answered* (with country / ASN), comparing them to the exit
> country — catching leaks that passive config-reading misses (config *looks* tunneled but
> resolution actually leaks to your local ISP). Uses the free [bash.ws](https://bash.ws) API
> (same one dnsleaktest.com's official CLI uses); it only sends random subdomains, no personal
> data. Skip it with `--no-dns-leak` / `-NoDnsLeak`.

> **Link-quality test** (on by default): the first seven checks answer *"am I safe?"*; this one
> answers *"is this node actually usable?"* It measures the TLS handshake time and real
> throughput **through the proxy**, then maps it to a 480p / 720p / 1080p verdict.
> **Don't use `ping` to judge speed** — under fake-ip every hostname resolves to `198.18.x.x`
> and ICMP is answered locally, so ping stays instant no matter how dead the node is. Your
> client's latency panel is no better: it measures one handshake round-trip and says nothing
> about bandwidth — a low-latency node can easily be a low-bandwidth one. Costs ~20MB; skip
> with `--no-speed-test` / `-NoSpeedTest`.

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
2) Desktop app / CLI exit
  Proxy env vars : not set — these programs won't use a proxy on their own; only TUN covers them
  [FAIL] proxy-unaware programs exit via <real IP> (China / <your ISP>),
         which differs from the browser exit <exit IP> (Japan) — real IP is leaking!
         Affected: Codex CLI, Claude Code CLI, the Node main process of Claude/ChatGPT desktop…
3) IPv6 leak surface   [ OK ] public IPv6 belongs to exit country (tunneled, no leak)
4) Timezone check      [FAIL] system UTC+8 vs exit UTC+9, off by +1h  ← #1 giveaway
5) Language / locale   [WARN] browser default language doesn't match exit country
6) DNS resolution path [ OK ] fake-ip tunnel resolution (static config)
   Active DNS-leak test [FAIL] resolvers in China but exit is Japan — DNS leaking to local ISP
7) WebRTC leak surface [ OK ] test page ready — run: browse-vpn --webrtc
8) Link quality        [ OK ] TLS handshake 0.27s — node responds fast
                       [ OK ] 167.8 Mbps down — smooth 1080p
```
</details>

### 2. `browse-vpn` — consistent browsing session (**the main tool**)

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File .\browse-vpn.ps1            # auto-detect exit country
powershell -ExecutionPolicy Bypass -File .\browse-vpn.ps1 -DryRun    # preview only, change nothing
powershell -ExecutionPolicy Bypass -File .\browse-vpn.ps1 -Country US  # force a country preset
powershell -ExecutionPolicy Bypass -File .\browse-vpn.ps1 -WebRTC     # open the WebRTC leak test inside the tunnel
powershell -ExecutionPolicy Bypass -File .\browse-vpn.ps1 -LockOnly  # only write the profile's locale/DoH prefs, don't launch
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
./browse-vpn.sh --lock-only                      # rewrite language/locale prefs only, don't launch
```
(`browse-vpn.ps1 -WebRTC` / `-LockOnly` on Windows do the same.)

> **Leak checkers still report browser language `zh-CN` / Intl locale `zh-CN`?** That was a
> known v1.0 pitfall: `--lang` / `--accept-lang` only apply when a profile is **first created**.
> The settings that actually decide the fingerprint — `intl.accept_languages`
> (`navigator.languages` / the `Accept-Language` header) and `intl.app_locale` in `Local State`
> (`navigator.language` / Intl locale) — live on disk, so a profile once created under a Chinese
> system keeps the residue forever. **Since v1.1 every launch rewrites these keys** — just upgrade
> and run once to purge them; no need to delete the profile. `-LockOnly` / `--lock-only` rewrites
> without launching the browser. (If a Chrome window using that profile is still open, the script
> refuses — Chrome would overwrite the fix with its in-memory old prefs on exit.)

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

### 3. `app-vpn` — consistent session for desktop apps / CLIs (**use this for Claude, Codex…**)

`browse-vpn` only affects the one Chrome it launches. **Claude desktop / Codex CLI /
Claude Code / Cursor are entirely out of its reach** — this script is for them.

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File .\app-vpn.ps1 -List      # list known app aliases
powershell -ExecutionPolicy Bypass -File .\app-vpn.ps1 codex      # run Codex CLI in a consistent env
powershell -ExecutionPolicy Bypass -File .\app-vpn.ps1 claude     # Claude Code CLI
powershell -ExecutionPolicy Bypass -File .\app-vpn.ps1 claude-desktop -SystemTz
    # Claude desktop (Electron): -SystemTz is required for the timezone to follow; auto-restored on exit
powershell -ExecutionPolicy Bypass -File .\app-vpn.ps1 "D:\any\app.exe"   # any executable
powershell -ExecutionPolicy Bypass -File .\app-vpn.ps1 -Print     # just print the env vars for another terminal
powershell -ExecutionPolicy Bypass -File .\app-vpn.ps1 codex -DryRun
```
```bash
# macOS / Linux
./app-vpn.sh --list
./app-vpn.sh codex
./app-vpn.sh claude-desktop          # Chromium honors TZ on Unix, so GUI apps need no extra flag
./app-vpn.sh --print
./app-vpn.sh codex --dry-run
./app-vpn.sh codex -- --model o3     # everything after -- is passed through verbatim
```

What it does: **probes the current exit country** → injects, **scoped to that one process**,
`HTTPS_PROXY` / `HTTP_PROXY` / `ALL_PROXY` (both cases, since language ecosystems disagree on
which they read), `NO_PROXY=localhost,127.0.0.1,::1,*.local` (local MCP servers and dev
servers must not be proxied), `TZ`, and `LANG` / `LC_ALL` → launches it → restores on exit.

**Built-in aliases**: `codex` · `claude` (Claude Code CLI) · `claude-desktop` · `cursor` ·
`code` · `chatgpt` — or pass any path or PATH command name. On Windows, when the hard-coded
paths miss, it looks up the real install location in the registry uninstall keys (so
non-C-drive installs are found).

> **Passing arguments to the target program**: just append them — anything this script doesn't
> recognize is forwarded verbatim (`app-vpn.ps1 node -e "..."`, `./app-vpn.sh codex resume --last`).
> The exception is on Windows, where a short option that happens to be a unique prefix of one of
> this script's parameters (`-c` → `-Country`, `-s` → `-SystemTz`, `-d` → `-DryRun`, `-l` → `-List`)
> gets swallowed by PowerShell. Pass the whole command via `-Run` instead:
> `app-vpn.ps1 -Run "codex -c model=gpt-5 -s workspace-write"`.
> (PowerShell's `-File` mode does not support a `--` separator, hence `-Run` on Windows and plain
> `--` on Unix.)

> **No system settings are changed**: environment variables are injected only into the launched
> process and restored before the script exits; user-level and machine-level environment
> variables are never written. The single exception is an explicit `-SystemTz` on Windows, which
> temporarily switches the system timezone (Chromium ignores `TZ`, there is no alternative) and
> restores it in a `finally` block.

### 4. `webrtc-leak-test.html` — active WebRTC leak detection

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

### 5. Per-country shortcuts (Windows, double-click / no arguments to remember)

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

### 6. `auto-select-node` — automatic node selection and deployment (Windows)

Finds the best proxy node *subject to security constraints* and switches to it. Talks to
mihomo over its named-pipe API, filtering progressively:

1. **Latency pre-filter**: every node in the group → sorted by latency, keep Top N
2. **Security test**: switch to each → probe the exit IP **multiple times** → drop nodes flagged
   `proxy` / `hosting`, plus **rotating exits** and exits **inferred to be datacenter**
   (an `unrecognized` verdict never drops a node)
3. **Bandwidth test**: survivors → TLS handshake + throughput against a Cloudflare endpoint
4. **Auto-deploy**: switch to the highest composite score (bandwidth 60% + latency 25% + TLS 15%)

> ⚠️ Before v1.1.0 that latency 25% **was silently dead**: `delay` lives in a hashtable key,
> and `Measure-Object` only sees PSObject properties, so max/min came back `$null` and the term
> degenerated to a constant — what actually ran was "bandwidth 80% + TLS 20%". Fixed.
>
> The latency term now genuinely counts, but **whether that changes the ranking depends on the
> data**: in a 2026-08-19 run the order flipped (TW-07 at 142 ms fell from 100 to 75, HK-03 at
> 101 ms rose from 98.2 to 88.3, changing the winner), while the `auto-select-live.txt` run in
> this repo (2026-08-11) keeps its order and only moves the scores (HK-03 92.8 → 67.7). Both
> outcomes are normal — the point is that a high-latency node no longer collects those 25 points
> for free.

```powershell
powershell -ExecutionPolicy Bypass -File .uto-select-node.ps1                    # defaults: group "国外默认", Top10 -> Top5
powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1 -DryRun            # test only; restores the original node
powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1 -TopN 15 -TopM 3   # how many survive each round
powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1 -Group "国外媒体"
powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1 -AllowHosting      # allow datacenter IPs
powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1 -IpProbes 3        # probe each exit 3x (default 2; 1 = off)
powershell -ExecutionPolicy Bypass -File .uto-select-node.ps1 -AllowRotating     # allow rotating exits
powershell -ExecutionPolicy Bypass -File .uto-select-node.ps1 -ProbeGapMs 5000    # gap between exit probes (default 2500 ms)
powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1 -AllowDatacenter   # don't drop on exit provenance
powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1 -PreferResidential # rank residential exits first
powershell -ExecutionPolicy Bypass -File .\auto-select-node.ps1 -NoSpeedTest       # skip bandwidth; rank by latency + security
```

> **Security-first policy**: nodes flagged `proxy` or `hosting` are dropped outright and never
> reach scoring. High-risk-control platforms (Claude et al.) are sensitive to datacenter ranges;
> a residential-IP node is the safe choice. `-AllowProxy` / `-AllowHosting` relax the gate at
> your own risk.
>
> **Exit-rotation detection (on by default)**: probes the exit IP twice per node (each `curl`
> is its own process and its own connection — no pooling), and a mismatch means the node sits
> behind a **load-balanced / multi-exit pool**, so it is dropped. Such nodes do two kinds of
> damage and are **indistinguishable from ordinary nodes in the client's UI**:
>
> 1. **The exit is shared by many accounts** — platforms cluster by IP, so one bad account
>    takes the whole cluster down with it;
> 2. **Your own session drifts across IPs / countries** — straight into impossible-travel checks.
>
> Cross-country rotation (the two probes land in different countries) is worse than same-country
> rotation, and the two are reported separately.
> **A failed re-probe never drops a node**: a timeout or an ip-api rate limit is treated as
> "not tested" — better to miss one than to kill a good node by mistake.
> `-IpProbes 1` turns the check off entirely (restores the old behaviour); `-AllowRotating`
> detects but does not drop.
>
> **Nodes already doomed skip the re-probe**: if a node is out on `proxy` / `hosting`, whether
> it rotates cannot change the outcome, so the probe is pure waste and is short-circuited.
> In a real run with `-IpProbes 3`, 6 of the Top 10 were datacenter IPs, cutting probes from 30
> to 18 (at the default `-IpProbes 2` it is 20 → 14). The side
> effect is that such a node's drop reason reads "datacenter IP" rather than "rotating" — both
> are hard drops with identical outcomes, so only the diagnostic label is lost; with
> `-AllowHosting` those nodes stay in the running and the re-probe runs as usual, losing nothing.
>
> **Exit provenance classification (on by default)**: ip-api's `hosting=false` only means "not
> in its records" — it does **not** mean residential. In a real run, of the 4 nodes that cleared
> every earlier gate only 1 was a genuine residential range (Chunghwa Telecom); the other three
> (`IPS INC` / `Pittqiao Network Information` / `Mejiro Network Limited`) were small hosting shops.
>
> The criterion is a **structural fact**, not what the name looks like: the 16-bit ASN space
> (1–65535) was exhausted at every registry around 2014, and running mass-market consumer
> broadband takes enormous address holdings and years of operating history — so every incumbent
> carrier holds a low number (Chunghwa AS3462, KT AS4766, SoftBank AS17676, HKT AS4760,
> Comcast AS7922…). Conversely, 32-bit ASNs (≥ 65536) are overwhelmingly small hosting shops
> registered after 2014. IPv4 and the 16-bit ASN space are both exhausted, so **this boundary
> itself cannot move again**.
> The data comes from the `as` / `asname` fields — **the same single request as before, zero
> extra quota**.
>
> **The classifier is not only that rule**, though — don't let the paragraph above mislead you.
> It is a weighted score, datacenter declared at a total of 3: allocation era +3 (another +1
> above AS200000), a hosting word in the org name +3 (**enough on its own**), a European RIPE
> range landing in APAC +2, an unregistered RIR placeholder AS-NAME +1, a carrier word **−3**.
> The allocation-era term cannot rot; **the two word lists can** — which is why
> `verify-classifier.sh` keeps dedicated sentinels for them. Run it before touching either list.
>
> **The drop is *relative***: a datacenter node is removed only while the pool still holds a
> non-datacenter one. If everything classifies as datacenter the gate stands down entirely,
> drops nothing, and suggests changing providers — **emptying the candidate pool is
> structurally impossible**. Of the three verdicts, `unrecognized` means *missing information*,
> not a negative finding, and never contributes to a drop.
>
> `-AllowDatacenter` disables the drop (the classification is still printed);
> `-PreferResidential` ranks residential exits first — it is a **lexicographic tier**, not a
> score bonus: whenever the surviving pool is a single tier the ordering is identical to not
> passing it at all; combined with `-AllowDatacenter`, unknown-tier nodes still rank ahead of
> datacenter ones (which is the intent). If it gets one wrong, add the ASN to `residential-asn.txt` (the script prints
> `ASN : AS<n> <org>` for every node, so you harvest entries from your own run log) — no need
> to edit the script.
>
> ⚠️ **Sign out of high-risk-control sessions before running this.** It is the operational fact
> this section's readers most need: steps 2 and 3 switch your **global exit** to each candidate
> in turn — up to roughly a dozen switches by default (one per Top-10 security test, one per
> Top-5 bandwidth test, one final deploy or restore), each held for seconds, **including the
> nodes that are about to be rejected as proxy / datacenter / rotating**. With Claude or ChatGPT
> open, your session hops across several countries in a few minutes — exactly the layer-3
> "country hopping / impossible travel" from the framing table at the top of this README.
> **`-DryRun` switches too**; it merely skips deploying a winner and restores the original node
> at the end.
>
> **Prerequisites**: Clash Verge Rev (mihomo) running with TUN mode on. The script talks to
> mihomo over the `\\.\pipe\verge-mihomo` named pipe, so it does not need the TCP external
> controller port.
>
> **Don't pick nodes by the latency number in your client's UI** — that measures one handshake
> round trip, reflects nothing about bandwidth, checks no IP reputation, and cannot tell you
> whether the node is a load-balanced pool. The lowest-latency node in the panel is usually the
> one *everybody* is on, which is exactly the one with the highest shared-exit density and
> association risk. This script's security checks (proxy/hosting flags + exit rotation +
> provenance) are dimensions the panel does not have at all.

## How it works

| Signal | Windows | macOS / Linux |
|---|---|---|
| Timezone (browser) | `tzutil /s` temporarily switches the system timezone (Chrome ignores `TZ`), auto-restored via `finally` when the session ends | Chrome launched with `TZ=<IANA timezone>` — process-scoped, system timezone untouched |
| Timezone (desktop/CLI) | Node / Rust / Go programs **do honor `TZ`**, so `app-vpn` injects it per-process; Electron GUIs don't, hence the explicit `-SystemTz` | always process-scoped `TZ` (Chromium honors it on Unix too); system timezone never touched |
| Proxy (desktop/CLI) | `app-vpn` injects `HTTP(S)_PROXY` / `ALL_PROXY` / `NO_PROXY` (both cases); address from `-Proxy` or the system-proxy registry key | same, address from `--proxy` or macOS `scutil --proxy` / existing Linux env vars |
| Desktop-app leak test | `curl --noproxy '*'` replays a "completely proxy-unaware program" and its exit IP is compared against the browser-side one (.NET, which does use the system proxy); a mismatch is a leak | same (curl doesn't read system proxy settings on macOS/Linux either, so the logic is identical) |
| Language | Chrome `--lang` / `--accept-lang` + **rewritten on every launch**: `intl.accept_languages` / `intl.selected_languages` in the profile and `intl.app_locale` in `Local State` (Chinese residue from older profiles is force-overwritten); system locale untouched. Desktop/CLI get `LANG` / `LC_ALL` from `app-vpn` | same |
| DNS (static) | "Secure DNS (DoH)" disabled in the isolated Chrome profile, forcing system DNS (TUN mode = fake-ip tunnel; in system-proxy mode hostnames are resolved remotely by the proxy), so the browser can't leak its own lookups | same |
| DNS (active test) | Triggers real connections to random subdomains to force recursive resolution, then uses bash.ws to look up which resolvers actually answered (country/ASN) and compares to the exit country | same (curl-triggered, identical logic) |
| IP | Taken over by TUN / system proxy / `--proxy`; the toolkit audits the takeover mode | same |
| IPv6 | Fetches the public IPv6 and **compares its geolocation to the exit country**: match = also tunneled (no leak); mismatch = bypassing the VPN and exposing your real ISP (real leak). Avoids the "any IPv6 = alarm" false positive | same |
| WebRTC | `webrtc-leak-test.html` active detection: real STUN probe, compares srflx vs exit IP for a leak verdict; `browse-vpn --webrtc` runs it inside the real tunnel | same (pure front-end, identical cross-platform) |
| Link quality | Pulls 20MB from the Cloudflare speed endpoint through the active takeover path (TUN directly / system proxy via `-x`), reads `time_appconnect` and `speed_download`, maps to 480p/720p/1080p tiers ; PAC mode is skipped to avoid a misleading number | same (on macOS the proxy address comes from `scutil --proxy`, skipped when it cannot be read). PAC mode is **not** detected separately on Unix — it measures as if there were no takeover |

> Isolated Chrome profiles live in `chrome-<country>-profile/` (git-ignored, never committed).
> Both platforms share the same directory naming.

## Caveats

- **Checkers flagging UTC+8 itself as "looks like a China user"**: Singapore / Malaysia nodes
  genuinely sit in UTC+8 — matching the exit IP exactly, so it is not a leak; it is a generic
  warning about sharing China's offset. Timezone name and language are already aligned to the
  exit country; the only way to dodge the hint is a node outside the +8 zone.
- **Datacenter IPs (IDC/hosting flag) and risk scores depend on node quality**: audit check #1
  surfaces the proxy/hosting flag (and `browse-vpn` / `app-vpn` warn about it before starting a
  session, including small hosting shops ip-api has no record of but whose ASN range gives them
  away — those two only warn, never block, and do not produce the full verdict), but no script
  can change an IP's attributes — platforms with
  strict risk control (e.g. Claude) are sensitive to datacenter ranges; switch to a residential
  ("native") IP node to fix that.
- **A "residential" verdict is a heuristic, not proof — and "residential" is not the same as
  "safe"**: this is the largest remaining blind spot. The residential-proxy industry sells
  exactly this — real residential IPs on real incumbent-carrier ASNs. Such an exit reports
  `hosting=false`, holds a 16-bit ASN and a famous carrier name, clears every gate in this
  toolkit and is labelled "residential/consumer", while potentially being
  shared with hundreds of other users. A sticky-session residential proxy defeats the rotation
  check too.
- **It targets one specific failure — "new small hosting shops holding 32-bit ASNs" — and is
  not a general datacenter detector**: established large datacenters hold 16-bit ranges, which
  the ASN rule cannot see. That is a division of labour rather than a defect; the two mechanisms
  are complementary along the allocation-era axis, verified against real data:

  | Mechanism | Covers | Evidence from a real run |
  |---|---|---|
  | ip-api `hosting=true` | Established clouds (old 16-bit ranges) | AWS AS16509, DigitalOcean AS14061, Oracle AS31898 — 6/6 caught |
  | ASN allocation era | New small hosting shops (32-bit ranges) | IPS INC AS131939, Pittqiao AS131642, Mejiro AS209642 — 3/3 caught, all three missed by ip-api |

  On its own the ASN rule misses all 6 big clouds, but none of them is misclassified as
  **residential** (the only unacceptable direction) and all were already stopped by the earlier
  gate. By the same token, a legitimate regional broadband provider founded after 2014 whose
  name carries no carrier word will be misjudged — costing one candidate (never the whole pool);
  add its ASN to `residential-asn.txt` to fix it permanently.
- **The built-in residential ASN list has not been verified entry by entry**: a wrong entry
  naming a nonexistent ASN is harmless (it never matches). The one genuinely unsafe direction
  is naming a real *hosting* ASN, which would exempt it from the provenance gate. The mitigation
  is structural: ip-api's own `hosting=true` verdict runs independently at an earlier gate, so
  the list only ever influences nodes ip-api did **not** flag as datacenter.
- **Exit-rotation detection is sampling, not proof**: by default it probes twice within a few
  seconds, which catches per-connection and short-cycle rotation but **not slow rotation** (an
  exit that changes every 10 minutes passes as "stable"). A "stable" verdict means only *this
  time we did not catch it*, not that the exit is exclusively yours. Raise `-IpProbes` and
  `-ProbeGapMs` for more confidence, at a linear cost in time.
- This only fixes *technical* signals. Account-level behavior (login history, payment
  region, shipping addresses) is not covered — keep those consistent yourself. See the
  framing section at the top: **account provenance is the highest-weight factor no script can
  touch.**
- **Windows only**: switching the system timezone makes **every program's** clock follow the
  exit country during the session; local-time-triggered scheduled tasks shift accordingly —
  expected, and auto-restored when the browser closes. The macOS / Linux version never
  touches the system timezone. (`app-vpn.ps1` only switches it when you explicitly pass
  `-SystemTz`; the CLI path never does.)
- **`app-vpn` works by convention, not by force**: it injects `HTTPS_PROXY` and friends, which
  only helps if the target program bothers to read them. Nearly everything in the Node / Rust /
  Go / Python ecosystems does — but **a program that hard-codes direct connections, or ships a
  network stack that ignores these variables entirely, is beyond its reach**. The only way to
  cover arbitrary programs is TUN mode (kernel-level takeover). Audit check #2 measures exactly
  that worst case — a green there is what proves TUN is really covering you.
- **Electron apps get partial timezone coverage**: on Windows the injected `TZ` only reaches the
  Node main process; the Chromium renderer (the web content you actually see in the app) still
  reads the system timezone, so `-SystemTz` is required for consistency. Not an issue on
  macOS / Linux.
- **`-Print` output contains the proxy address** — usually just `127.0.0.1:<port>` with no
  credentials, but use your judgment before pasting it somewhere public.
- The macOS / Linux scripts rely on the local tzdata database to resolve IANA timezone names
  (present on mainstream systems; minimal container images may need `tzdata` installed —
  the script warns when it can't find it).
- The leak audit classifies by **takeover mode** (TUN / system proxy / local port only) and
  applies to all mainstream clients (Clash/Mihomo, V2Ray/Xray, sing-box, SS, WireGuard,
  OpenVPN); the `198.18.x` fake-ip signature covers Clash/Mihomo/sing-box/Xray fakedns.
- In system-proxy mode the browser is safe, but UDP/WebRTC and proxy-unaware apps may
  bypass the proxy — enable your client's TUN mode for full coverage.
- The active DNS-leak test relies on the third-party [bash.ws](https://bash.ws) service (a
  default network call like ip-api / ipify): it only sends random subdomain probes, uploads no
  personal data, and the service only sees your resolver IPs (which is the point). Pass
  `--no-dns-leak` to skip. Under fake-ip, if resolvers still show up as local, it's usually the
  client's DNS using a domestic upstream — follow the hint to route DNS through the tunnel.
- **Link quality is a quick check, not a speed-test suite**: a single 20MB / 8-second sample.
  It reliably separates "can I watch 720p / 1080p" tiers, but it has poor resolution on fast
  links (>100 Mbps) and will vary between runs on the same node. To **rank** several nodes,
  use a dedicated speed-test tool — don't compare these numbers finely. It depends on the
  Cloudflare endpoint (`speed.cloudflare.com`) and skips gracefully when unreachable — which
  is itself a signal that the node is unstable.
- **Reachable ≠ usable**: under fake-ip every hostname resolves to `198.18.x.x` and ICMP is
  answered by your own machine, so `ping` succeeds instantly with ~0ms regardless of node
  health — `ping` / `tracert` / `nslookup` carry no diagnostic value here. Likewise your
  client's "latency test" only measures one handshake round-trip and **says nothing about
  bandwidth**: in real testing a node ranking mid-pack on latency came dead last on
  throughput (2.72 Mbps — not even enough for 480p). Judge speed by check 8 instead.

## License

MIT, see [LICENSE](LICENSE).
