# Third-Party Notices

DNSPilot includes the following third-party software.

The pinned AGDnsProxy artifact is a prebuilt binary containing static
third-party components in addition to DnsLibs. The upstream DnsLibs recipe
identifies direct dependency versions, but the release archive does not
provide an authoritative artifact-level SBOM or complete transitive notice
bundle. DNSPilot must not publish a binary release until the inventory in
`docs/en/compliance/agdnproxy-v2.8.45.md` is reconciled with authoritative
license texts and all required notices are added here. This source repository
does not claim that the transitive binary notice audit is complete.

The inventory below deliberately over-includes components declared by the
upstream runtime recipe. Recipe inclusion is evidence that a component was a
build input, not proof that its code is present in every Apple binary slice.
License links identify the reviewed upstream text but do not replace license
texts that a binary distribution may be required to carry.

## Identified Runtime Recipe Components

- **ada 2.7.4** - Apache-2.0 OR MIT. Copyright 2023 Yagiz Nizipli and Daniel Lemire. [Source](https://github.com/ada-url/ada/tree/v2.7.4), [MIT](https://github.com/ada-url/ada/blob/v2.7.4/LICENSE-MIT), [Apache-2.0](https://github.com/ada-url/ada/blob/v2.7.4/LICENSE-APACHE).
- **cxxopts 3.1.1** - MIT. Copyright (c) 2014 Jarryd Beck. [Source](https://github.com/jarro2783/cxxopts/tree/v3.1.1), [license](https://github.com/jarro2783/cxxopts/blob/v3.1.1/LICENSE).
- **klib, AdGuard recipe 2021-04-06** - MIT. Upstream commit `e1b2a40de8e2a46c05cc5dac9c6e5e8d15ae722c`. Copyright (c) 2008- Attractive Chaos. [Source](https://github.com/attractivechaos/klib/tree/e1b2a40de8e2a46c05cc5dac9c6e5e8d15ae722c), [license](https://github.com/attractivechaos/klib/blob/e1b2a40de8e2a46c05cc5dac9c6e5e8d15ae722c/LICENSE.txt).
- **ldns, AdGuard recipe 2021-03-29** - BSD-3-Clause. Upstream commit `7128ef56649e0737f236bc5d5d640de38ff0036d`. Copyright (c) 2005, 2006 NLnet Labs. [Source](https://github.com/NLnetLabs/ldns/tree/7128ef56649e0737f236bc5d5d640de38ff0036d), [license](https://github.com/NLnetLabs/ldns/blob/7128ef56649e0737f236bc5d5d640de38ff0036d/LICENSE).
- **libevent 2.1.11** - BSD-3-Clause with additional file-level notices. Copyright (c) 2000-2007 Niels Provos; Copyright (c) 2007-2012 Niels Provos and Nick Mathewson; additional authors are listed in the license. [Source](https://github.com/libevent/libevent/tree/release-2.1.11-stable), [license](https://github.com/libevent/libevent/blob/release-2.1.11-stable/LICENSE).
- **libsodium, AdGuard recipe 1.0.18** - ISC. Copyright (c) 2013-2019 Frank Denis. [Source](https://github.com/jedisct1/libsodium/tree/1.0.18-RELEASE), [license](https://github.com/jedisct1/libsodium/blob/1.0.18-RELEASE/LICENSE).
- **libuv 1.41.0** - MIT with additional BSD and ISC file-level notices. Copyright (c) 2015-present libuv project contributors; additional authors are listed in the license. [Source](https://github.com/libuv/libuv/tree/v1.41.0), [license](https://github.com/libuv/libuv/blob/v1.41.0/LICENSE).
- **magic_enum 0.9.5** - MIT. Copyright (c) 2019-2023 Daniil Goncharov. [Source](https://github.com/Neargye/magic_enum/tree/v0.9.5), [license](https://github.com/Neargye/magic_enum/blob/v0.9.5/LICENSE).
- **NativeLibsCommon, AdGuard recipe 8.0.27** - Apache-2.0. Commit `9458af4b1cb0a1ac2302a3a02270ef013a286eed`. Copyright 2022 Adguard Software Ltd. [Source](https://github.com/AdguardTeam/NativeLibsCommon/tree/9458af4b1cb0a1ac2302a3a02270ef013a286eed), [license](https://github.com/AdguardTeam/NativeLibsCommon/blob/9458af4b1cb0a1ac2302a3a02270ef013a286eed/LICENSE.md).
- **ngtcp2 1.0.1** - MIT. Copyright (c) 2016 ngtcp2 contributors. [Source](https://github.com/ngtcp2/ngtcp2/tree/v1.0.1), [license](https://github.com/ngtcp2/ngtcp2/blob/v1.0.1/COPYING).
- **BoringSSL, AdGuard recipe boring-2024-09-13** - OpenSSL, Original SSLeay, ISC, MIT, and BSD-family notices. Upstream tag `0.20240913.0`. Copyright holders include the OpenSSL Project, Eric Young, Google Inc., fiat-crypto authors, and other contributors listed in the license. [Source](https://boringssl.googlesource.com/boringssl/+/refs/tags/0.20240913.0), [license](https://boringssl.googlesource.com/boringssl/+/refs/tags/0.20240913.0/LICENSE).
- **PCRE2 10.37** - BSD-3-Clause. Copyright (c) 1997-2021 University of Cambridge; Copyright (c) 2009-2021 Zoltan Herczeg. [Source](https://github.com/PCRE2Project/pcre2/tree/pcre2-10.37), [license](https://github.com/PCRE2Project/pcre2/blob/pcre2-10.37/LICENCE).
- **tldregistry, AdGuard snapshot 2022-12-26** - BSD-3-Clause. Copyright 2015 The Chromium Authors. [Recipe source](https://github.com/AdguardTeam/NativeLibsCommon/tree/9458af4b1cb0a1ac2302a3a02270ef013a286eed/conan/recipes/tldregistry), [license](https://github.com/AdguardTeam/NativeLibsCommon/blob/9458af4b1cb0a1ac2302a3a02270ef013a286eed/conan/recipes/tldregistry/chromium/LICENSE).

## Identified Transitive Candidates

The following components are present in the NativeLibsCommon 8.0.27 recipe
and have matching static-archive symbol evidence in the reviewed AGDnsProxy
macOS slice. Their exact package revisions remain unverified, so the versions
below are recipe candidates rather than an artifact-level claim.

- **fmt, candidate 12.1.0** - MIT with binary-object exception. Copyright (c) 2012-present Victor Zverovich and fmt contributors. [Source](https://github.com/fmtlib/fmt/tree/12.1.0), [license](https://github.com/fmtlib/fmt/blob/12.1.0/LICENSE).
- **nghttp2, candidate 1.56.0** - MIT. Copyright (c) 2012, 2014, 2015, 2016 Tatsuhiro Tsujikawa and nghttp2 contributors. [Source](https://github.com/nghttp2/nghttp2/tree/v1.56.0), [license](https://github.com/nghttp2/nghttp2/blob/v1.56.0/COPYING).
- **nghttp3, candidate 1.0.0** - MIT. Copyright (c) 2019 nghttp3 contributors. [Source](https://github.com/ngtcp2/nghttp3/tree/v1.0.0), [license](https://github.com/ngtcp2/nghttp3/blob/v1.0.0/COPYING).

curl and zlib remain unresolved observations: available strings and generic
compression symbols do not establish component presence or an exact version.
They are intentionally not attributed as distributed components here.

## AdGuard DnsLibs / AGDnsProxy

- Version: 2.8.45 (`v2.8.45@swift-5`)
- Source: <https://github.com/AdguardTeam/DnsLibs>
- Copyright: Copyright 2022 Adguard Software Ltd
- License: Apache License 2.0

```text
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright 2022 Adguard Software Ltd

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
```
