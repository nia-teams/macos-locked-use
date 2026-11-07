# Security scope

Locked Use changes macOS authorization policy and uses private APIs. Treat it as
experimental; do not mistake opaque windows for an OS-enforced privacy boundary.
Review the signed installer, approval records, plug-in, broker, guardian and
watchdog together before deployment. Preserve recovery records until normal
unlock and safe teardown are observed.

Do not include credentials, Keychain contents, audit tokens, private signing keys,
or identifying logs in public reports. Coordinate suspected vulnerabilities
privately with the maintainers of the distribution you use; this extraction has
not established a separate security response service or support guarantee.
