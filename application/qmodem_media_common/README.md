# Shared media contracts

Canonical IPC, media types and codecs consumed by SIP and voice builds. Runtime
services do not depend on each other's packages. Compatibility headers in
`voipd/src` include these definitions; both OpenWrt builds copy this directory
into their own build directory. No generated feed package or runtime dependency
is needed for a header-only contract.
