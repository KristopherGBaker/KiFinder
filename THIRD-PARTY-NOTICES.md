# Third-Party Notices

KiFinder itself is licensed under GPL-3.0-or-later (see `LICENSE`). This file lists the
third-party components it builds on, their licenses, and where their notices are required.

There are two categories:

1. **Redistributed / linked components** — code that is compiled into or bundled with the
   app when you build it. These carry the full upstream license text below.
2. **Models downloaded at runtime** — face-embedding model weights that are **not** in this
   repository and are **not** redistributed by the author. `Scripts/bootstrap-fixtures.sh`
   (and the app's onboarding flow) fetch them into a local cache on your machine. Their
   licenses and provenance are listed for reference; you obtain them directly from upstream.

---

## Redistributed / linked components

### ONNX Runtime

- **Component:** ONNX Runtime (`libonnxruntime.1.27.0.dylib`)
- **Version:** 1.27.0
- **License:** MIT (SPDX: `MIT`)
- **Upstream:** https://github.com/microsoft/onnxruntime
- **How it is used:** The prebuilt macOS dynamic library is fetched by
  `Scripts/bootstrap-vendor.sh` (never committed to this repo) and bundled with the app to
  run the optional ArcFace ONNX embedder (`KionONNXEmbedder` / `KionORTShim`).

MIT license text:

```
MIT License

Copyright (c) Microsoft Corporation

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

---

## Models (downloaded at runtime, not redistributed)

No model weights live in this repository. Each backend fetches its weights from upstream
into a local cache (`~/Library/Application Support/KiFinder/models` or the app's sandbox
container). The licenses below govern the weights themselves; check them before using the
models for anything beyond personal / research use.

### ArcFace `arcfaceresnet100-8`

- **License:** Apache-2.0 (SPDX: `Apache-2.0`) as tagged in the ONNX Model Zoo
- **Source:** ONNX Model Zoo — https://huggingface.co/onnxmodelzoo/arcfaceresnet100-8
- **Provenance caveat:** The weights are trained on the **MS-Celeb-1M** dataset, which has
  been **withdrawn** by its original publisher. This is generally fine for personal or
  research use, but you should review the dataset's status before any other use.

### AdaFace IR-18 (CoreML)

- **License:** MIT (SPDX: `MIT`)
- **Source:** https://github.com/john-rocky/CoreML-Models — release `adaface-v1`
  (`AdaFace_IR18.mlpackage.zip`)
- **Provenance:** This is a CoreML conversion that, per its author, conforms to the license
  of the original project, `mk-minchul/AdaFace` — https://github.com/mk-minchul/AdaFace (MIT).

### Apple Vision FeaturePrint

- **What it is:** A face/image feature extractor provided by Apple's **Vision**
  system framework. It ships with macOS — there is no separate download, no weights in this
  repo, and nothing is redistributed by KiFinder. Its use is governed by the Apple SDK / OS terms.

---

## Build-time tools (not redistributed)

These tools are used to build or lint the project. They are not linked into or shipped with
the app, so no license text is reproduced here — see their own repositories.

- **XcodeGen** — https://github.com/yonaskolb/XcodeGen (generates `KiFinder.xcodeproj` from
  `project.yml`).
- **SwiftLint** — https://github.com/realm/SwiftLint (lint/format).
