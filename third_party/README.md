# Vendored packages

## bonsoir_darwin 7.1.1 (MIT, © Hugo Delaunay)

Copied from pub.dev with one change in
`darwin/bonsoir_darwin/Sources/bonsoir_darwin/Broadcast/BonsoirServiceBroadcast.swift`:
service registration delivers its reply on the main dispatch queue
(`DNSServiceSetDispatchQueue`) instead of calling `DNSServiceProcessResult`,
which blocked the main thread, and froze the app, until mDNSResponder answered.
Used through `dependency_overrides` in `pubspec.yaml`. Drop it once upstream
ships the same fix.
