# Audit and testing / 审计与测试

## Reviewed baseline / 检查范围

All four baseline files were read: `singbox-v2.sh`, `install.sh`, `README.md`, `README_EN.md`. The user's Desktop copies were compared byte-for-byte and match the original GitHub revision.

## Problems and fixes / 问题与修复

| Original problem | Change |
| --- | --- |
| Function `install()` shadowed the system executable; enabling auto-update called the protocol installer | Renamed to `install_protocol`; system file installation explicitly uses `command install` |
| Backup config directory and binary shared the same pathname | Separate `config/` and `sing-box.bin`; snapshot external TLS files; restore with rollback |
| Binary copy could copy onto itself | Install official release directly into the managed binary path |
| Update executed a package installer that could alter config/service | Download only a checksum-verified binary; validate candidate before replacing; shared manual/automatic update path |
| Self-signed exports only had placeholders; links failed certificate trust | Embed public cert in sing-box JSON and Mihomo trust settings; export PEM and fingerprint; preserve certificate verification |
| Existing TLS files were accepted without validation | Check expiry, hostname/IP, and public/private key matching |
| HY2 URI did not encode arbitrary credentials | Percent-encode authentication before creating the URI |
| Protocol selection trusted stale metadata | Detect active protocol types from actual server inbounds |
| SSH port detection relied on manual entry | Detect listener/config/current connection ports and require verification; preserve detected SSH rules |
| Enabling UFW omitted existing hopping ranges | Include active UDP range and provide explicit UDP firewall audits |
| Leading-zero/oversized ports could break arithmetic | Bound input length and use base-10 conversion |
| Actions could end the whole menu on failure/cancellation | Isolate actions under strict mode and return to the menu; keep error output visible |
| Installing chrony could replace active timesyncd | Avoid installing chrony when an existing time-sync service is active |
| README menu numbers and feature claims contradicted each other | Rewritten bilingual docs matching implemented behavior |
| No automated regression suite | Add unittest suite and Ubuntu/Debian CI |

## Automated tests / 自动化测试

The regression suite invokes actual Bash functions with isolated filesystem paths. Only OS-mutating commands (apt, systemctl, UFW, nftables, sysctl) are mocked; real crypto, configuration export, backup filesystem operations and protocol engine processes run where applicable.

- YES case variants, port boundaries, language persistence and both branded menus.
- Three actual server configurations and protocol detection with stale cached mode.
- Base64/URI encoding, private file permissions, self-signed cert embedding and fingerprint.
- Certificate hostname/IP mismatch and mismatched private key rejection.
- External TLS backup/restore and update rejection/rollback.
- SSH detection, UFW allow rules, UDP audit and hopping systemd persistence.
- Initialization, BBR/FQ, daily/monthly vnStat and service restart config checks.
- Legacy owned weekly-timer retirement and private unit backups.
- Matching release digest accepted; corrupted digest rejected without replacing target.
- Real sing-box client → HY2 server → local HTTP forwarding; removing certificate trust fails.
- Real Mihomo YAML validation and Mihomo client → sing-box HY2 server → local HTTP forwarding.

Local development result: 58 tests passed, including real HY2 forwarding with both clients and rejection without certificate trust; `bash -n`, ShellCheck and `git diff --check` passed.

Local development validation: macOS arm64, Bash 3.2, ShellCheck 0.11.0, OpenSSL 3.6.2, sing-box 1.14.3, Mihomo 1.19.32. CI pins the same protocol engine releases on Ubuntu 24.04 / Debian 12 with the distributions' Bash/OpenSSL/ShellCheck.

```bash
for file in install.sh singbox-v2.sh src/*.sh; do bash -n "$file"; done
shellcheck install.sh singbox-v2.sh
SING_BOX_BIN=/path/to/sing-box MIHOMO_BIN=/path/to/mihomo python3 -m unittest discover -s tests -v
```

Without engine paths, engine-specific tests are skipped. PyYAML is required for Mihomo tests. All credentials, keys, certificates and generated exports stay in temporary directories.

## Remaining live validation / 真实 VPS 验收

No production VPS was provided. The automated suite does not claim to test real apt upgrades, systemd boot persistence, kernel BBR behavior, UFW/nftables packet processing, provider firewalls or Shadowrocket/v2rayN GUI imports.

On a disposable Ubuntu/Debian VPS, verify all three installation modes, real certificate chain validation, trusted self-signed client imports, IPv4 hopping through UFW and cloud security groups, legacy timer retirement, restart/restore failure handling and reboots. Keep provider console access and a snapshot throughout. These checks should precede production rollout.

## Shadowrocket follow-up

Added per-protocol separators, translated trust notes, PEM/DER public certificate exports and iOS root profiles for CA certificates. Profiles contain no passwords or private keys. Leaf-only certificates do not get root profiles, and stale trust exports are removed. Existing server certificates and credentials are preserved.

The earlier Menu 4 → 9 checked configuration, service, actual UDP listener, certificate identity/key/expiry and UFW; that diagnostic menu is removed in V2.4. It prints timeout/auth/trust guidance without printing node passwords. Tests cover profile schema, public DER content, CA-versus-leaf behavior, translated separators, changed ports and stopped services.

User evidence confirms an active sing-box service and a UDP 443 listener. This does not establish external UDP reachability or client TLS trust. Shadowrocket screenshots show TLS enabled but not its inner trust settings. The user later reported working connectivity; the exact cause of the earlier failure was not established.

## Managed uninstall

Menu 6 → 3 requires confirmation and a successful backup before removing owned services/files. Tests cover cancellation, changed unit ownership, symlinked binaries, backup/stop failures, auxiliary service cleanup, script-copy identification and retention of external certificates, unrelated files, unowned hopping tables and backups. System mutations are mocked in these tests; no development-host or production VPS services are actually uninstalled.

## Client-specific exports

Terminal sections show v2rayN URIs, full Clash Verge/Mihomo YAML, full sing-box client JSON and Shadowrocket native links (V2.3.1 removes the duplicate Base64 display), each separated with dashed lines. Legacy exports remain. New exports are private files, carry only installed protocols, retain verified TLS trust and are removed during managed uninstall. YAML/JSON are checked by actual Mihomo/sing-box binaries for all three protocol combinations. Real HY2 forwarding tests now load the complete generated client configurations, rather than constructing their own client routing. No Shadowrocket/v2rayN GUI compatibility claim is made.

## Custom names and output colors

Installation and menu 2 → 3 accept a persisted node-name prefix, defaulting to SKYBYTE on Enter. Protocol suffixes keep names unique. Tests cover Chinese/spaces/URI punctuation, all exported names and routing references, unchanged server config, reset to default, length/control-character rejection and real engine config validation. Node metadata and instructions use yellow ANSI styles while credential/config content stays red; NO_COLOR/non-terminal output remains plain.

## Argo and grouped menus

58 tests cover both tunnel modes, token-file privacy, registration/address lifecycle, removal/backup/restore, ownership guards, download verification, unchanged credentials and bilingual grouped dispatch. Actual sing-box and Mihomo clients passed local verified TLS/WebSocket forwarding. A separate live Quick Tunnel check with cloudflared 2026.10.0 passed HTTPS/WebSocket forwarding. The local resolver returned NXDOMAIN for the new hostname; public DNS supplied the address while original SNI/Host and TLS verification were retained. Named account routes were not live-tested. Systemd mutations are mocked; VPS startup and graphical client imports remain deployment checks.

## Shadowrocket terminal QR codes

60 local tests passed. New tests verify that each exact exported Shadowrocket URI is fed to qrencode through stdin, separated and named in the terminal, with no credentials in encoder arguments; encoder failure is propagated and the bilingual submenu dispatches the new action. The QR renderer is mocked in these regression tests; physical phone scanning has not been tested. bash -n, ShellCheck and git diff --check passed.

## Shadowrocket native VLESS links

62 tests passed locally. Dedicated native exports preserve standard exports; roundtrip checks cover Base64 authority, Unicode/punctuation names, Vision, Reality public key/short ID/fingerprint, WS host/path and enabled certificate verification. QR input tests now use native files. Schema follows the Xboard Shadowrocket exporter linked in both READMEs; actual Shadowrocket GUI import/scanning still needs user verification.

## Startup summary

64 tests passed locally. The bilingual green startup summary reads local OS/kernel/architecture/virtualization/interface addresses and checks real service state, with fallbacks for missing probes. Tests cover translated output, running/inactive/uninstalled distinctions and lack of startup network requests. New changes are consolidated into PR #7.

## Per-account quotas and expiry

New accounts use isolated official sing-box instances with loopback authenticated Clash controllers. Actual Reality (with a local TLS 1.3 decoy) and HY2 forwarding are metered. Tests verify independent credentials/ports/totals, upload and download accounting, live reset without recounting old bytes, quota exhaustion while another account continues, persisted totals after supervisor restart, expiry rejection, controller failure and corrupted-ledger shutdown. Additional cases cover account caps, disabled/deleted records, atomic creation failures, private files/exports, current-policy/usage retention on restore, ownership/symlink safeguards, bilingual dispatch, firewall rules and hopping conflicts. Existing admin/Argo nodes are deliberately outside account quotas.

Validation uses the bundled Python with TLS 1.3 for the Reality decoy test; older Apple Python skips that test. Enforcement is periodic and not byte-exact: sampling/shutdown/crash gaps and traffic overshoot remain practical limits. Systemd/UFW/nftables mutations are mocked; live VPS deployment and graphical client imports remain user checks.

Local result: 80 tests passed with the bundled Python/TLS 1.3 runtime, sing-box 1.14.3 and Mihomo 1.19.32. bash -n, ShellCheck 0.11.0 and git diff --check passed. User live tests bind proxy and controller listeners only to loopback.

## V2.3 manager operations

93 tests passed locally. The additional operations suite verifies current module/bundle consistency and rootless self-check, stable release metadata and asset digest rejection, owned/atomic script updates with untouched node configuration/usage, rollback when the active supervisor cannot restart, independent quota/validity edits, safe fault diagnostics and validated recovery, direct main-menu access, scoped process/RSS reporting, expiry warnings, fingerprint-based domain-certificate reload selection, manual self-signed handling, certificate/key synchronization and client export regeneration, mismatched key rejection, and opt-in owned certificate timers. The real controller failure test additionally verifies persisted authentication reasons and secret-free diagnostics.

The source modules are assembled with `python3 scripts/build.py`. CI requires `python3 scripts/build.py --check`, bundle `--self-check`, Bash syntax checks for every source shell file, ShellCheck of the complete installer/bundle, and the full test suite. Keys and passwords are generated in temporary fixtures; no customer data is checked in. Release network responses, systemd service updates and resource snapshots use mocks; cryptography and filesystem operations are real. Actual VPS renewal hooks, service restart/rollback, daily timer execution and resource capacity still require deployment validation.

## V2.3.1 interaction styling and exports

93 tests passed after centralizing interactive prompts and selection hints, including unchanged confirmation/input behavior and native-link/QR exports. Updated export checks require the native Shadowrocket section and reject the removed duplicate Base64 display section. A manual pseudo-terminal check verified bold green prompts/options, reset before typed input, hidden token entry, mixed-case YES, and NO_COLOR plain output. Compatibility files remain on disk. All Bash source syntax, generated-bundle consistency and ShellCheck checks passed.


## V2.4 WARP, media probes and menu cleanup

Local result: all 128 tests passed (93 prior cases plus 35 network-feature cases), including the real encrypted gateway forwarding tests. Generated-bundle consistency, rootless self-check, Bash syntax, ShellCheck 0.11.0 and `git diff --check` passed. It covers anonymous-page evidence classification, HTTP 200 remaining unknown, explicit restrictions, challenges/denials/timeouts, TLS/proxy/address-family flags, private secret-free reports, all three WARP modes, unchanged node credentials and individual quotas, newly added user/Argo inheritance, custom-route/symlink refusal, candidate validation before writes, route rollback on failed restart, backup reconciliation for post-snapshot accounts, native gateway profile/ownership guards, gateway restore/import rollback, external-profile retention on uninstall, signed apt/modern WARP CLI installation through mocks, and exact trace-family validation.

Real sing-box processes verify that only a selected domain traverses a shared local SOCKS proxy, that HY2 account traffic remains independently metered while using it, and that two encrypted WireGuard peers carry IPv4 HTTP, IPv6 HTTP and UDP echo through one shared gateway. All peers/listeners stay on loopback; benchmark destination addresses are overridden at the local peer and no customer traffic is sent. SOCKS tests include fragmented responses and TCP-only rejection. The hopping tests check actual non-443 HY2 targets, large-range exports, account conflicts, changed unit ownership, failed enable/partial-rule cleanup and preservation of unrelated nftables tables when uninstalling an iptables deployment.

The four requested menu entries are removed and both languages renumbered. Owned legacy update units are privately backed up and retired; foreign units remain. YouTube invitations are checked immediately after the channel link. IPv6 URI authorities and IP SAN verification have regression coverage.

CI additionally installs the official Cloudflare signed package on Ubuntu 24.04 and Debian 12 to inspect modern CLI help schemas without registration, terms acceptance or connection. Official installation and systemd/UFW/NAT mutations use mocks in the regression suite. Local encrypted WireGuard coverage establishes forwarding behavior, not real Cloudflare account acceptance, egress availability or media unlocking. Anonymous probes never claim actual playback, full catalogs, account/payment eligibility or AI availability. Real provider UDP rules, systemd persistence, WARP service registration/dual-stack and media playback still require a disposable VPS deployment.


## V2.5 reliability, certificates and private subscriptions

The final suite contains 167 cases, including missing-state restoration rollback, custom-port firewall allowance and listener status. Local macOS skips only the GnuPG case; Linux CI runs it with the distribution package.

[CI run 38333796525](https://github.com/skylink9119/sing-box-v2/actions/runs/38333796525) passed on 2026-10-13 for commit `e42ca3e`: all 167 cases on both Ubuntu 24.04 and Debian 12, Bash syntax, ShellCheck, generated-source consistency and disposable 10/30/50-account benchmarks. Certificate identity tests include OpenSSL implementations that exit zero while reporting a hostname mismatch; validation checks the reported match as well as the exit status.

The suite adds installation staging/exclusive commits/rollback/retry, preservation of files created concurrently, admin/user port/address/SNI edits, invalid/conflicting settings, multi-file restart rollback, protocol add/remove with unchanged credentials/ledgers, automatic self-signed HY2 addition and real engine validation of bandwidth/Salamander exports. It checks tested/latest/specified version selection, ownership guards, isolated Certbot HTTP/DNS flags, hidden token-file privacy, failed/successful issuance, opt-in owned renewal timers and failed renewal preserving current certificates.

Actual local TLS requests fetch personal exports and quota/expiry headers, reject traversal/unknown formats/invalid or revoked tokens, exclude controller/private keys, and enforce current eligibility. Further cases cover symlink/rate rejection, untrusted subscription certificates, owned full uninstall with intact private snapshots, manifest tampering before mutation, safe archive roundtrips/traversal rejection, retention scopes, and preflight never executing an imported binary. Real GnuPG encryption/decryption runs in Ubuntu/Debian CI with an isolated GNUPGHOME; local macOS lacks GnuPG and skips only this case. Release packaging verifies the public asset allowlist/digests. Main-menu idle-lock release has a regression test.

A ten-core live test checks simultaneous readiness/sampling, disables/expires two accounts while others continue, and bounds observed sample age. The separate disposable benchmark runs10/30/50 actual HY2 cores with loopback listeners and no OS service/firewall changes. Local idle snapshots are in `docs/benchmarks/local-idle-v2.5.json`; they are not throughput, VPS capacity or byte-exact accounting claims. CI uploads credential-free Linux RSS/PSS/sample-age results.

Certbot and Cloudflare CLI help schemas are checked against distribution/signed official packages without actual issuance, registration or DNS modification. Public CA issuance, domain propagation, provider ports, reboot persistence, real WARP routing and graphical subscription imports need deployment validation on the operator's own VPS/domain. ACME account/DNS state and subscription tokens remain private and are backed up, never release assets. Changes are prepared on a development branch, dependent on the unmerged V2.4 PR, without a main merge or release.

## V2.6 residential landing relay

Twenty new relay cases passed locally with sing-box 1.14.3. Real two-hop client → HY2 entry → HY2/Reality landing → loopback HTTP/UDP echo tests verify both landing protocols, XUDP forwarding and refusal to fall back to direct after stopping the landing server. A live account test verifies that forwarded traffic is still metered independently and an idle second account does not inherit another account's usage. Negative real HY2 tests reject untrusted certificates, wrong names and wrong passwords.

Import checks cover standard/native Reality URIs, IPv6 HY2, encoded passwords, public certificate fingerprint matching, hopping/Salamander fields and single-outbound JSON. Unsafe TLS, unknown file/network directives, duplicate URI parameters, private keys, symlinks and malformed inputs are rejected. Pasted URI credentials are absent from terminal output/process arguments, and temporary input files are cleaned on return/exit. Routing tests cover existing/new accounts, original direct baselines, custom-rule refusal, obvious self-loops, restart/probe rollback, Argo reconciliation, WARP switching and backup restoration without usage/credential resets or landing credentials in client exports.

The HTTPS probe validates reachability and reports the observed landing egress IP; tests mock its external Cloudflare response while real encrypted forwarding stays on loopback. No operator residential VPS or optimized mainland route was provided. These tests do not establish residential IP classification, public UDP reachability, provider-specific bandwidth or actual speed improvements; measure both network links on the deployment.
