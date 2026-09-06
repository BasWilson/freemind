# Vendored terminal dependency

SwiftTerm v1.20.0, revision `5d14406844143538cd8f8851d2d8a67c1fe443e5`, from https://github.com/migueldeicaza/SwiftTerm.

The application compiles the library sources directly, avoiding its documentation and command-line tool dependencies. `FreemindBuildInfo.swift` replaces the upstream build-information generator. The upstream MIT license is retained in `SwiftTerm/LICENSE`.

tmux 3.5a and libevent 2.1.12 are built by `Scripts/build-backend.sh`. Their checksums are pinned there; licenses ship in the app bundle. libevent is statically linked. Only macOS system libraries remain dynamically linked.
