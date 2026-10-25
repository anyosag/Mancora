# Mancora for Windows

The Windows app shell arrives in Phase 5 (see `docs/ROADMAP.md`). It will be
a WinUI 3 app written in Swift with
[swift-winrt](https://github.com/thebrowsercompany/swift-winrt), rendering
through Direct3D 11 into a `SwapChainPanel`, on top of the same
`MancoraCore` and `MancoraIO` packages the macOS app uses.

Phase 1 includes a time-boxed test of that stack. Until then, CI builds and
tests the shared packages on Windows on every push.
