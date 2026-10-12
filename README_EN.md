# SKYBYTE sing-box Manager V2.1 — Bilingual manager (test candidate)

**Status:** The Bash syntax and basic language-switching menus have been locally tested. This has **not** passed an end-to-end live VPS deployment, protocol handshake, firewall, update or rollback test. Use a fresh test VPS with a snapshot, not a production server.

## Start

Requirements: Debian/Ubuntu, root, systemd, network access. Hysteria2 requires your own domain plus a **valid trusted TLS certificate** and private key in PEM form. Open TCP 443 and UDP 443 in the hosting-provider firewall. For optional hopping, also allow your chosen UDP port range. Keep SSH access safe.

Upload `singbox-v2.sh` and run:

```bash
chmod 700 singbox-v2.sh
sudo bash ./singbox-v2.sh
```

At first interactive launch, choose `1` for Simplified Chinese or `2` for English. The selection persists at `/etc/singbox-v2/language.conf`, and menu option `15` changes it. The unattended update job does not prompt for a language. Core menus, legal/privacy notices, important confirmations, and new-server initialization are translated. Some lower-level diagnostic messages and third-party tool output may still appear in Chinese or the system language.

## Main functions

- Install VLESS + Reality + Vision on TCP 443 and Hysteria2 on UDP 443 (fresh VPS only; existing deployments are protected from overwrite).
- Show node URIs and export sing-box outbound JSON **fragments** (not full client configurations). Mihomo YAML and QR codes are not yet implemented.
- Optional BBR + FQ, affecting host-wide TCP settings.
- Optional IPv4 UDP port hopping (disabled by default). nftables rules are persisted by a dedicated systemd unit. Provider firewall rules must also be adjusted. Client port hopping must be configured explicitly.
- Manual and opt-in weekly stable release updates with backups and attempted rollback. Package-manager side effects and endpoint availability cannot be fully rolled back or tested by this script.
- Optional IP information query via ipinfo.io and simple network checks. These are **not** IP reputation, streaming-unlock, UDP-loss, throughput, or China-carrier-route tests.
- Reports saved locally under `/etc/singbox-v2/reports` and pruned after 30 days. Backups are not automatically deleted.
- Option `14` initializes a fresh server after explicit confirmation: updates apt packages, installs common administration tools, checks time synchronization, DNS, HTTPS, SSH and UFW. Does **not** enable UFW, change SSH ports, enable BBR, or reboot.

## Privacy and legal disclosure

The manager is for lawful networking education and server administration, subject to applicable laws and service terms. Provided as-is to the extent permitted by law; back up before making changes. It does not intentionally transmit node secrets or telemetry to the script author. Third-party services can see your source IP: installation/updates may access sing-box.app, github.com, api.github.com and GitHub CDNs; installation may use api.ipify.org; optional IP lookup uses ipinfo.io. Auto-updates are opt-in. HY2 does not disable TLS verification by default.

Review the source before executing. See the Chinese `README.md` for further warnings and official documentation links.

## New install modes (testing build)
Menu 1 now offers Reality only, HY2 only, or dual protocol. HY2 accepts an existing TLS cert or can create a self-signed certificate with an IP SAN. The public certificate must be transferred securely and explicitly trusted by supported clients; a HY2 URI alone does not establish trust. Menus are bold green, and confirmation accepts YES regardless of case.

**This is an unverified testing build. Bash syntax validation is not equivalent to a real VPS installation, client connectivity, upgrade, or rollback test. Do not deploy to production.**

## SKYBYTE V2.1 additions

YouTube channel: https://www.youtube.com/@SKYBYTE9119

- Menu 1/2/3: install Reality, HY2, or both. Menu 4: node info. Menu 5: local subscription exports. Bold green menu, cyan headings, bold red credential links, yellow warnings where ANSI is supported. Case-insensitive `yes` confirmation.
- Menu 6: UFW installation/enable/disable/rule management. Verify the real SSH port and ensure out-of-band VPS console access before enabling UFW. Provider firewall is separate.
- Menu 8: service status and start/restart/stop/boot enable/config check. An active service does not establish end-to-end client availability.
- Menu 9: optional vnStat installation and VPS interface traffic monitoring (daily, monthly, live). **Does not count Reality and HY2 separately.**
- Local exports in `/etc/singbox-v2/` (chmod 600): `nodes.txt`, `subscription-base64.txt`, `mihomo-proxies.yaml` (proxy fragment), `outbounds.json` (outbound fragment), `subscription-notes.txt`. Never publish credentials. This does **not** create a remote HTTPS subscription URL.
- Self-signed HY2 requires securely distributing and trusting the certificate on each client. Replace `REPLACE_WITH_TRUSTED_CLIENT_CERT_PATH` with a real trusted client-side certificate path. Client support varies.

This remains an **untested VPS candidate**: only Bash syntax and static checks were performed. Test on a disposable VPS with a snapshot and console before public release.
