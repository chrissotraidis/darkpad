# Security policy

## Reporting a vulnerability

Please use a private
[GitHub security advisory](https://github.com/chrissotraidis/darkpad/security/advisories/new)
for vulnerabilities involving code execution, unsafe file import, archive
extraction, path escape, network exposure, credentials or sensitive local data.

Do not open a public issue containing an exploit, ROM data, extracted assets,
private filesystem paths, certificates, provisioning profiles or secrets.

Ordinary build, rendering, input or gameplay defects without security impact
can be filed through GitHub Issues.

## Supported version

DarkPad is a source-available developer preview. Security fixes target the
latest commit on `main`; no older release line is maintained.

Development builds include a test console on TCP 8775 that listens on the
device itself only. Builds made with `PD_PUBLIC=1` leave it out entirely.
