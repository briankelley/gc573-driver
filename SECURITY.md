# Security policy

## Reporting a vulnerability

Please report security problems privately through GitHub: open this repository's **Security** tab and choose **Report a vulnerability**. Please don't open a public issue for them.

A useful report says:
- the driver commit or release, and the kernel version;
- what an attacker needs, for example a local program that can open the card's video or audio devices, or a malicious HDMI source;
- how to reproduce it, and what happens.

## Scope

- **The kernel module (`src/`):** anything reachable by an unprivileged program that can open the card's V4L2 or ALSA devices, or by an HDMI source connected to the card. Examples are memory corruption, information leaks, privilege escalation, and hangs.
- **The install scripts** (`tools/install.sh`, `tools/uninstall.sh`, `tools/card-release.sh`), which run as root on users' machines.

The developer tooling in `tests/` and the rest of `tools/` (virtual machines, test sources, the reference setup) is not meant for end users' machines. Report problems there as normal issues, unless they can affect a user's machine.

## Supported versions

The latest release, and `main`.

## What to expect

This is a small project, and reports are handled on a best-effort basis. A confirmed problem is fixed on `main` and in the next release, with credit to the reporter if they want it.
