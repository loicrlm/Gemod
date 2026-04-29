Libbox.xcframework (public Git snapshot)
----------------------------------------
This repo ships only the ios-arm64 (device) slice to stay under GitHub’s 100MB
per-file limit. The Packet Tunnel / Network Extension target is not usable on
the iOS Simulator anyway for VPN workflows.

To restore a full xcframework (including ios-arm64_x86_64-simulator), replace
this folder with your private build of Libbox, or re-copy from your original
archives.
