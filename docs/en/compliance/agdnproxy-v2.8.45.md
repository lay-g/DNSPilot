# AGDnsProxy 2.8.45 Compliance Inventory

[中文](../../zh/compliance/agdnproxy-v2.8.45.md)

Status: incomplete binary-release gate. This is a technical inventory, not legal advice or a substitute for required license texts.

## Locked Artifact

- SwiftPM revision: `5570e10e4883f9fe770a291b4025449127185f88`
- DnsLibs tag: `v2.8.45`, commit `e0654ab8c53109c6cca7a706b6c1166f96f0a3c4`
- Source revision selected by `conandata.yml`: `b178ef332ce193351951a3019a38d7a39152d9f8`
- Artifact: `AGDnsProxy-apple-2.8.45.zip`
- SHA-256: `f9d0495427909b19376bfe6fead93af6c9acc401880fddf29de3dd89244c552b`
- DnsLibs license: Apache-2.0

## Identified Direct Recipe Dependencies

| Component | Recipe version | License evidence |
| --- | --- | --- |
| ada | 2.7.4 | Apache-2.0 OR MIT, exact upstream tag |
| cxxopts | 3.1.1 | MIT, exact upstream tag |
| klib | 2021-04-06 AdGuard recipe | MIT, mapped upstream commit |
| ldns | 2021-03-29 AdGuard recipe | BSD-3-Clause, mapped upstream commit |
| libevent | 2.1.11 AdGuard recipe | BSD-3-Clause plus file-level notices, exact upstream tag |
| libsodium | 1.0.18 AdGuard recipe | ISC, recipe version; exact build checkout unresolved |
| libuv | 1.41.0 AdGuard recipe | MIT plus file-level notices, exact upstream tag with AdGuard patches |
| magic_enum | 0.9.5 | MIT, exact upstream tag |
| native_libs_common | 8.0.27 AdGuard recipe | Apache-2.0, mapped commit `9458af4b1cb0a1ac2302a3a02270ef013a286eed` |
| ngtcp2 | 1.0.1 AdGuard recipe | MIT, exact upstream tag |
| openssl | boring-2024-09-13 AdGuard recipe | Compound BoringSSL license, upstream tag `0.20240913.0` |
| pcre2 | 10.37 AdGuard recipe | BSD-3-Clause, exact upstream tag |
| tldregistry | 2022-12-26 AdGuard recipe | BSD-3-Clause, mapped Chromium snapshot |

Recipe inclusion does not prove that every component or version is present in each Apple slice. `THIRD-PARTY-NOTICES.md` now records conservative attribution, source, and license pointers for every direct recipe component above.

## Identified Transitive Candidates

NativeLibsCommon 8.0.27 recipes and static-archive symbols jointly identify fmt, nghttp2, and nghttp3. The candidate recipe versions are fmt 12.1.0, nghttp2 1.56.0, and nghttp3 1.0.0. Their exact package revisions in the released artifact remain unresolved, so notices describe them as candidates rather than confirmed artifact versions.

curl and zlib remain unresolved observations. The reviewed strings and generic compression symbols do not establish component presence or exact versions, so they are not currently attributed as distributed components.

## Authoritative Inputs

- <https://github.com/AdguardTeam/DnsLibs/blob/v2.8.45/conanfile.py>
- <https://github.com/AdguardTeam/DnsLibs/blob/v2.8.45/conandata.yml>
- <https://github.com/AdguardTeam/DnsLibs/blob/5570e10e4883f9fe770a291b4025449127185f88/Package.swift>
