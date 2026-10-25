# Mancora for Windows

`MancoraViewer` is a small native Win32 app written in Swift on top of
`MancoraCore` and `MancoraIO`. It ships in the 0.1.0 installer and can:

- open TIFF images from **File ▸ Open**, by drag and drop, or with
  "Open with" in Explorer
- apply built-in and bundled LUTs
- step through slices (←/→), channels (↑/↓) and frames (Page Up/Down)

It draws with GDI (`StretchDIBits`) from the same BGRA output that
`DisplayMapper` produces for the macOS app.

It's an interim shell. The WinUI 3 app (swift-winrt, Direct3D 11 in a
`SwapChainPanel`) replaces it in Phase 5 (see `docs/ROADMAP.md`).

```powershell
swift build --package-path Apps/Windows
pwsh Tools/package/windows/package.ps1   # installer and portable zip in dist/
```
