# AGDnsProxy 2.8.45 合规清单

[English](../../en/compliance/agdnproxy-v2.8.45.md)

状态：二进制发布门禁未完成。本文件是技术清单，不构成法律意见，也不能替代必需 license 文本。

## 锁定产物

- SwiftPM revision：`5570e10e4883f9fe770a291b4025449127185f88`
- DnsLibs tag：`v2.8.45`，commit `e0654ab8c53109c6cca7a706b6c1166f96f0a3c4`
- `conandata.yml` 选择的源码 revision：`b178ef332ce193351951a3019a38d7a39152d9f8`
- Artifact：`AGDnsProxy-apple-2.8.45.zip`
- SHA-256：`f9d0495427909b19376bfe6fead93af6c9acc401880fddf29de3dd89244c552b`
- DnsLibs license：Apache-2.0

## 已识别的直接 Recipe 依赖

| Component | Recipe version | License evidence |
| --- | --- | --- |
| ada | 2.7.4 | Apache-2.0 OR MIT，精确上游 tag |
| cxxopts | 3.1.1 | MIT，精确上游 tag |
| klib | 2021-04-06 AdGuard recipe | MIT，已映射上游 commit |
| ldns | 2021-03-29 AdGuard recipe | BSD-3-Clause，已映射上游 commit |
| libevent | 2.1.11 AdGuard recipe | BSD-3-Clause 及文件级 notices，精确上游 tag |
| libsodium | 1.0.18 AdGuard recipe | ISC，recipe 版本；精确构建 checkout 未闭合 |
| libuv | 1.41.0 AdGuard recipe | MIT 及文件级 notices，精确上游 tag 并包含 AdGuard patches |
| magic_enum | 0.9.5 | MIT，精确上游 tag |
| native_libs_common | 8.0.27 AdGuard recipe | Apache-2.0，已映射 commit `9458af4b1cb0a1ac2302a3a02270ef013a286eed` |
| ngtcp2 | 1.0.1 AdGuard recipe | MIT，精确上游 tag |
| openssl | boring-2024-09-13 AdGuard recipe | BoringSSL 复合 license，上游 tag `0.20240913.0` |
| pcre2 | 10.37 AdGuard recipe | BSD-3-Clause，精确上游 tag |
| tldregistry | 2022-12-26 AdGuard recipe | BSD-3-Clause，已映射 Chromium snapshot |

Recipe 中出现不证明每个 component/version 都存在于每个 Apple slice。`THIRD-PARTY-NOTICES.md` 现已为上述全部直接 recipe component 记录保守 attribution、source 和 license 链接。

## 已识别的传递依赖候选

NativeLibsCommon 8.0.27 recipes 与静态 archive symbols 共同识别出 fmt、nghttp2 和 nghttp3。候选 recipe 版本分别为 fmt 12.1.0、nghttp2 1.56.0 和 nghttp3 1.0.0。发布 artifact 中的精确 package revisions 仍未闭合，因此 notices 将它们描述为候选项，而非已确认的 artifact 版本。

curl 和 zlib 仍是未闭合观察项。已审查的 strings 与通用压缩 symbols 无法证明 component presence 或精确版本，因此当前未将它们归属为已分发 component。

## 权威输入

- <https://github.com/AdguardTeam/DnsLibs/blob/v2.8.45/conanfile.py>
- <https://github.com/AdguardTeam/DnsLibs/blob/v2.8.45/conandata.yml>
- <https://github.com/AdguardTeam/DnsLibs/blob/5570e10e4883f9fe770a291b4025449127185f88/Package.swift>
