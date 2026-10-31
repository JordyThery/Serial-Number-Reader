# Serial Number Reader: watchlist

What this app is waiting for from Apple, Jamf or Microsoft, or must recheck. Check each item when the vendor ships an update.

- **Opaque DFU, "Debug USB" 0x1881 (Apple):** access needs a private Apple entitlement, so the app can only detect presence. If a phantom "Apple Device (DFU)" row ever appears next to a phone in normal mode, 0x1881 also appears outside DFU and the classification needs refining.
- **TLS on the lockdown socket (Apple):** Secure Transport is used because Network.framework can’t start TLS on an open socket. Recheck with each macOS SDK; if Network.framework gains it, move off Secure Transport.
- **Client identity from PEM (Apple):** built with `SecIdentityCreate` via `dlsym`, because no public API builds one from PEM. Recheck with each macOS SDK; if a public API appears, use it.
