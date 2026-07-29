# Mach XPC Acceptance Probe

This source is compiled into a disposable directory and signed separately for authenticated Mach XPC security tests. It is intentionally not an Xcode target and must not be embedded in DNSPilot.

Compile with the pinned toolchain:

```bash
export DEVELOPER_DIR="/Applications/Xcode-26.4.0.app/Contents/Developer"
OUT="${TMPDIR:-/tmp}/DNSPilotMachXPCProbe"

xcrun swiftc \
  -swift-version 6 \
  -strict-concurrency=complete \
  -target arm64-apple-macos15.0 \
  -parse-as-library \
  DNSPilot/Contracts/IPAddress.swift \
  DNSPilot/Contracts/ActiveProxyConfiguration.swift \
  DNSPilot/Contracts/ProxyConfigurationFingerprint.swift \
  DNSPilot/Contracts/ProxyRuntimeStatus.swift \
  DNSPilot/Contracts/DNSProxyXPCProtocol.swift \
  Tools/MachXPCProbe/main.swift \
  -o "$OUT"
```

The test operator records the signing identity and identifier outside the repository for each positive or negative case. A DebugLocal positive request has this shape:

```bash
"$OUT" \
  --service group.ABCDE12345.org.example.DNSPilot.dev.ipc.status \
  --server-team ABCDE12345 \
  --server-identifier org.example.DNSPilot.dev.DNSProxy \
  --request both \
  --timeout-seconds 5
```

Exit `0` means the requested payloads were decoded. Exit `64` indicates invalid arguments, `65` an invalid server requirement, `69` service rejection/unavailability, `70` an invalid payload, and `124` a timeout.
