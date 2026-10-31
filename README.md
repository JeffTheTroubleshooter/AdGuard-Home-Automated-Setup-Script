# AdGuard Home Automated Setup Script

Builds [AdGuard Home](https://github.com/AdguardTeam/AdGuardHome) from source and installs it as a systemd service. The script installs Go (1.25 or newer), Node.js (24 or newer) and the build tools for you.

## Automatic Install

```bash
bash adguard-install.sh
```

The script asks for an install directory (default `/opt/adguardhome`) and a web setup port (default `3000`). When it finishes, open `http://<server-ip>:3000` to finish the first-time setup.

AdGuard Home serves DNS on port 53. If something else on the machine already uses port 53 (for example `systemd-resolved`), free it up first.

## Service

```bash
sudo systemctl status adguardhome
sudo systemctl restart adguardhome
sudo systemctl stop adguardhome
```

## Uninstall

```bash
bash adguard-install.sh uninstall
```

This removes the service and files, and can also remove the build packages if you choose to.

## Supported Distros

| Distro | Status |
|---|---|
| Fedora | Tested, works |
| Debian / Ubuntu (and Mint, Pop!_OS, Zorin, elementary) | Not tested, need feedback |
| RHEL / Rocky / AlmaLinux / CentOS | Not tested, need feedback |
| Arch / Manjaro / EndeavourOS / Garuda | Not tested, need feedback |
| openSUSE / SLES | Not tested, need feedback |
| Alpine | Not tested, need feedback |

If you try it on a distro that isn't tested, please open an issue and say how it went.
