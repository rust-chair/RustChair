# RustChair branding boundary

RustChair is a derivative build of RustDesk 1.4.9. The RustDesk license and upstream attribution remain unchanged.

| Surface | RustChair value |
| --- | --- |
| Product name | `RustChair` |
| Rust executable/package | `rustchair` |
| Embedded native library | `librustchair` |
| Apple bundle identifier | `com.rustchair.RustChair` |
| Android application identifier | `com.rustchair.app` |
| Deep-link scheme | `rustchair://` |
| Native platform channel | `com.rustchair.RustChair/*` |

The following upstream identifiers are intentionally retained because changing them would break compatibility or attribution:

- RustDesk rendezvous/relay protocol fields and server API contracts.
- RustDesk dependency repository URLs and Cargo package names owned upstream.
- Historical references in upstream documentation, comments, tests, and the license.
- Private Rust-to-Flutter ABI symbol names such as `rustdesk_core_main`.

RustChair is treated as a custom client by the upstream runtime. This keeps translated UI strings branded as RustChair and prevents the official RustDesk updater from replacing the derivative application.
