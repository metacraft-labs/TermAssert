# Package
version       = "0.1.0"
author        = "Metacraft Labs"
description   = "Standalone TUI test harness library combining nim-pty and nim-libvterm with the 12 capabilities of tui-testing plus modern-protocol assertions"
license       = "MIT"
srcDir        = "src"

# Dependencies
requires "nim >= 2.0.0"
# Path-based deps - resolved through `--path:../nim-pty/src` etc. in the
# Justfile. When published to Nimble, these become version requirements.
