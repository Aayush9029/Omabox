# Third-party notices

The root [LICENSE](LICENSE) applies to Omabox’s original source code. Separately credited code and artwork retain their own terms. The Linux guest contains additional packages with their own licenses; Omabox does not relicense them.

## Original design resources and artwork

Omabox’s settings components and original design resources are reused at the request of their owner, Aayush Pokharel. The original source identifies its copyright as © 2026 Aayush Pokharel, all rights reserved, and has no standalone license file. Permission to reuse those components and assets in Omabox does not grant a blanket license to the artwork under this repository’s MIT license.

The copied resources include the Icon Composer artwork, Bolt SVG, settings illustrations, GIFs, desktop thumbnail, and provider icon collection. The desktop thumbnail is identified in the original source as an Unsplash photograph. That photograph and the provider marks retain their original terms. See [asset provenance](Omabox/Resources/AssetProvenance.md).

## Omarchy

The Omarchy mark, guest desktop configuration, and desktop shown in screenshots come from Omarchy, pinned to commit `346e69e1cec6c4e8924531874af6ba010a1bc99e`. Separately licensed packages and artwork within the Linux guest retain their original terms.

[Upstream repository](https://github.com/omacom/omarchy) · [License source](https://raw.githubusercontent.com/omacom/omarchy/346e69e1cec6c4e8924531874af6ba010a1bc99e/LICENSE)

```text
Copyright (c) David Heinemeier Hansson

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## Try Omarchy

The guest preparation pipeline uses the Try Omarchy v0.3.0 ARM Linux factory, pinned to source commit `6aced581ad991b0a1495b74907f8a41c8a58d0b6`. The factory disk is downloaded during preparation and is excluded from this source repository.

[Upstream repository](https://github.com/omacom/try-omarchy) · [License source](https://raw.githubusercontent.com/omacom/try-omarchy/6aced581ad991b0a1495b74907f8a41c8a58d0b6/LICENSE)

```text
MIT License

Copyright (c) 2026 Try Omarchy contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## LobeHub icons

The provider marks in `Omabox/Resources/ProviderIcons.xcassets` were copied with the original design resources. Their original source is LobeHub’s static SVG collection. The provider names and marks belong to their respective owners and do not imply affiliation or integration.

[Upstream repository](https://github.com/lobehub/lobe-icons) · [License source](https://raw.githubusercontent.com/lobehub/lobe-icons/master/LICENSE)

```text
MIT License

Copyright (c) 2023 LobeHub

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Linux Virtio sound driver

`Guest/virtio-sound-source` contains the unmodified Linux v7.2.2 Virtio sound driver from commit `52c36105f76e96b638152a42e735f2e7767ed946`. The source files preserve their SPDX `GPL-2.0+` identifiers and OpenSynergy GmbH copyright notices. The driver is licensed under GPL-2.0-or-later, separately from Omabox’s original host code.

The subtree includes [COPYING](Guest/virtio-sound-source/COPYING), the [GPL license text](Guest/virtio-sound-source/LICENSES/preferred/GPL-2.0), and [file-level source provenance](Guest/virtio-sound-source/provenance.json). See the [driver documentation](Guest/virtio-sound-source/README.md) for source and build details.

## Swift package dependencies

Swift packages are resolved during the build and are not vendored in this repository. Their source repositories, versions, and revisions are recorded in [Tuist/Package.swift](Tuist/Package.swift) and [Tuist/Package.resolved](Tuist/Package.resolved). Each dependency retains its upstream license.
