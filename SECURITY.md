# Security policy

## Supported versions

Security fixes target the latest released minor version only. Upgrade to its
latest patch before reporting an issue. Older minor versions do not receive
backports. The current release is v0.1.0, whose precompiled artifact requires
Mojo 1.0.0; the development branch requires Mojo 1.1.0. Compiler versions are
pinned in each revision's Pixi manifest and lockfile.

Supported targets are Linux x86_64, Linux aarch64, and macOS arm64, all with
64-bit ABIs. Windows, 32-bit ABIs, and other targets are outside the support
matrix. Reports may cover the core package or optional TLS, HTTP/2, and HTTP/3
providers available in the affected revision.

## Reporting a vulnerability

Use GitHub's [private vulnerability reporting form](https://github.com/hirokazumiyaji/net-mojo/security/advisories/new)
to report a suspected vulnerability. Do not disclose vulnerabilities in public
issues or pull requests before coordinated disclosure.

Include the affected revision or release, Mojo version, OS and architecture,
enabled providers, reproduction steps, and expected impact. Provide a minimal
reproducer where possible; omit credentials and private application data.

The maintainer aims to acknowledge reports within 72 hours and complete initial
triage within 30 days. These are response targets, not guaranteed fix deadlines.
Fix timing and disclosure are coordinated privately with the reporter after
the impact and affected versions have been established.
