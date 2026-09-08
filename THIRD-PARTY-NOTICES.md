# Third-Party Notices

DriveStitch's own code and assets are licensed under the repository's MIT
license (see [LICENSE](LICENSE)). The third-party components below are
governed by their own licenses, which are unaffected by that MIT license.

## PySide6 and shiboken6 (Qt for Python)

- License: LGPL-3.0-only (alternatively GPL-2.0/3.0 or The Qt Company
  commercial license) - full text: [LICENSES/LGPL-3.0.txt](LICENSES/LGPL-3.0.txt)
- Copyright: The Qt Company Ltd and contributors
- Use: GUI toolkit. Runtime dependency, dynamically linked via Python
  imports; not modified.
- Source: https://www.qt.io/qt-for-python

The app is MIT-licensed and merely *uses* PySide6/Qt; the LGPL terms above
apply to the Qt components themselves. If you redistribute a packaged build
that bundles PySide6, keep the Qt libraries separable so users can swap them,
and include this license text alongside the distribution.

## Pillow

- License: MIT-CMU (open source, HPND-style)
- Copyright: Jeffrey A. Clark (Amethyst) and contributors
- Use: image generation for the application icon (`make_icon.py`) -
  development tool only, not required at runtime.
- Source: https://python-pillow.github.io
- License text: https://raw.githubusercontent.com/python-pillow/Pillow/main/LICENSE
