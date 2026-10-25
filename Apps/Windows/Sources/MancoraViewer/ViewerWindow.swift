#if os(Windows)
import MancoraCore
import MancoraIO
import WinSDK

/// The open image and the position being shown.
final class ViewerState {
    var window: HWND?
    var image: Hyperstack?
    var fileName = ""
    var channel = 0
    var slice = 0
    var frame = 0
    /// DisplayMapper output for the current position: BGRA, top-down.
    var pixels: [UInt32] = []

    func open(path: String) throws(MancoraIOError) {
        image = try TIFFImporter.read(path: path)
        fileName = String(path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last ?? Substring(path))
        channel = 0
        slice = 0
        frame = 0
        render()
    }

    func render() {
        guard let image else {
            pixels = []
            return
        }
        pixels = DisplayMapper.render(image, channel: channel, slice: slice, frame: frame)
    }

    func step(channel dc: Int = 0, slice ds: Int = 0, frame df: Int = 0) {
        guard let dims = image?.dimensions else { return }
        channel = min(max(channel + dc, 0), dims.channels - 1)
        slice = min(max(slice + ds, 0), dims.slices - 1)
        frame = min(max(frame + df, 0), dims.frames - 1)
        render()
    }

    func apply(_ lut: LUT) {
        guard var image, image.pixelType.usesLUT else { return }
        var display = image.channels[channel]
        display.lut = lut
        image.setDisplay(display, forChannel: channel)
        self.image = image
        render()
    }

    var title: String {
        guard let image else { return "Mancora" }
        let dims = image.dimensions
        var parts = [fileName]
        if dims.channels > 1 { parts.append("c \(channel + 1)/\(dims.channels)") }
        if dims.slices > 1 { parts.append("z \(slice + 1)/\(dims.slices)") }
        if dims.frames > 1 { parts.append("t \(frame + 1)/\(dims.frames)") }
        parts.append("\(image.width)×\(image.height) \(image.pixelType.bitDepth)-bit")
        return parts.joined(separator: " — ") + " — Mancora"
    }
}

// Win32 calls the window procedure on the UI thread only, so this state is
// confined to that thread.
nonisolated(unsafe) let viewer = ViewerState()
nonisolated(unsafe) let backgroundBrush = CreateSolidBrush(colorRef(0x1B, 0x22, 0x2A))

enum MenuID {
    static let open = 100
    static let openLUT = 101
    static let exit = 102
    static let about = 103
    static let builtInLUT = 1000
}

func runViewer(arguments: [String]) {
    _ = SetProcessDPIAware()

    if let i = arguments.firstIndex(of: "--smoke-test") {
        ExitProcess(smokeTest(path: i + 1 < arguments.count ? arguments[i + 1] : "") ? 0 : 1)
    }

    guard let window = createMainWindow() else {
        showMessage("Mancora could not create its window.", title: "Mancora", owner: nil, isError: true)
        ExitProcess(1)
    }
    if let path = arguments.first(where: { !$0.hasPrefix("--") }) {
        openImage(path: path)
    }
    _ = ShowWindow(window, SW_SHOWDEFAULT)
    _ = UpdateWindow(window)

    var message = MSG()
    while GetMessageW(&message, nil, 0, 0) {
        _ = TranslateMessage(&message)
        _ = DispatchMessageW(&message)
    }
    ExitProcess(UINT(truncatingIfNeeded: message.wParam))
}

/// Opens an image and creates (but never shows) the window, for CI.
func smokeTest(path: String) -> Bool {
    do {
        try viewer.open(path: path)
    } catch {
        return false
    }
    guard let image = viewer.image, viewer.pixels.count == image.width * image.height,
        let window = createMainWindow()
    else { return false }
    _ = DestroyWindow(window)
    return true
}

func createMainWindow() -> HWND? {
    let className = "MancoraViewerWindow".wide
    let instance = GetModuleHandleW(nil)
    var windowClass = WNDCLASSEXW()
    windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
    windowClass.style = UINT(CS_HREDRAW | CS_VREDRAW)
    windowClass.lpfnWndProc = windowProcedure
    windowClass.hInstance = instance
    windowClass.hIcon = LoadIconW(instance, appIconResource)
    windowClass.hCursor = LoadCursorW(nil, arrowCursor)
    windowClass.hbrBackground = backgroundBrush
    let registered = className.withUnsafeBufferPointer { name in
        windowClass.lpszClassName = name.baseAddress
        return RegisterClassExW(&windowClass)
    }
    guard registered != 0 else { return nil }

    let window = CreateWindowExW(
        acceptFilesExStyle,
        className,
        "Mancora".wide,
        overlappedWindowStyle,
        cwUseDefault, cwUseDefault, 1100, 800,
        nil,
        makeMenuBar(),
        instance,
        nil
    )
    viewer.window = window
    return window
}

func makeMenuBar() -> HMENU? {
    let bar = CreateMenu()
    let file = CreatePopupMenu()
    _ = AppendMenuW(file, UINT(MF_STRING), UINT_PTR(MenuID.open), "&Open…\tCtrl+O".wide)
    _ = AppendMenuW(file, UINT(MF_STRING), UINT_PTR(MenuID.openLUT), "Open &LUT File…".wide)
    _ = AppendMenuW(file, UINT(MF_SEPARATOR), 0, nil)
    _ = AppendMenuW(file, UINT(MF_STRING), UINT_PTR(MenuID.exit), "E&xit".wide)

    let luts = CreatePopupMenu()
    for (i, lut) in LUT.builtIn.enumerated() {
        _ = AppendMenuW(luts, UINT(MF_STRING), UINT_PTR(MenuID.builtInLUT + i), lut.name.wide)
    }

    let help = CreatePopupMenu()
    _ = AppendMenuW(help, UINT(MF_STRING), UINT_PTR(MenuID.about), "&About Mancora".wide)

    _ = AppendMenuW(bar, UINT(MF_POPUP), UINT_PTR(UInt(bitPattern: file)), "&File".wide)
    _ = AppendMenuW(bar, UINT(MF_POPUP), UINT_PTR(UInt(bitPattern: luts)), "&LUT".wide)
    _ = AppendMenuW(bar, UINT(MF_POPUP), UINT_PTR(UInt(bitPattern: help)), "&Help".wide)
    return bar
}

func windowProcedure(_ window: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    switch Int32(truncatingIfNeeded: message) {
    case WM_COMMAND:
        handleCommand(Int(wParam & 0xFFFF))
        return 0
    case WM_KEYDOWN:
        handleKey(Int32(truncatingIfNeeded: wParam))
        return 0
    case WM_DROPFILES:
        let drop = HDROP(bitPattern: UInt(wParam))
        var path = [WCHAR](repeating: 0, count: 4096)
        if DragQueryFileW(drop, 0, &path, UINT(path.count)) > 0 {
            openImage(path: String(wide: path))
        }
        DragFinish(drop)
        return 0
    case WM_SIZE:
        _ = InvalidateRect(window, nil, false)
        return 0
    case WM_ERASEBKGND:
        return 1  // WM_PAINT fills the whole client area
    case WM_PAINT:
        paint(window)
        return 0
    case WM_DESTROY:
        PostQuitMessage(0)
        return 0
    default:
        return DefWindowProcW(window, message, wParam, lParam)
    }
}

func handleCommand(_ id: Int) {
    switch id {
    case MenuID.open:
        if let path = chooseFile(
            owner: viewer.window, title: "Open Image",
            filter: "TIFF images (*.tif, *.tiff)\0*.tif;*.tiff\0All files (*.*)\0*.*")
        {
            openImage(path: path)
        }
    case MenuID.openLUT:
        guard viewer.image?.pixelType.usesLUT == true else { return }
        if let path = chooseFile(
            owner: viewer.window, title: "Open LUT",
            filter: "Lookup tables (*.lut, *.txt)\0*.lut;*.txt\0All files (*.*)\0*.*",
            initialDirectory: executableDirectory() + "\\LUTs")
        {
            do {
                viewer.apply(try LUTReader.read(path: path))
                refresh()
            } catch {
                showMessage("\(error)", title: "Can't Open LUT", owner: viewer.window, isError: true)
            }
        }
    case MenuID.exit:
        _ = DestroyWindow(viewer.window)
    case MenuID.about:
        showMessage(
            "Mancora \(MancoraVersion.number)\n\nA native Swift port of Fiji (ImageJ).\n"
                + "Free software under the GNU GPL, version 3 or later.\n\n"
                + "Keys: ←/→ slice, ↑/↓ channel, Page Up/Down frame.",
            title: "About Mancora", owner: viewer.window, isError: false)
    case MenuID.builtInLUT..<(MenuID.builtInLUT + LUT.builtIn.count):
        viewer.apply(LUT.builtIn[id - MenuID.builtInLUT])
        refresh()
    default:
        break
    }
}

func handleKey(_ key: Int32) {
    let control = GetKeyState(VK_CONTROL) < 0
    switch key {
    case 0x4F where control:  // Ctrl+O
        handleCommand(MenuID.open)
    case VK_RIGHT: viewer.step(slice: 1)
    case VK_LEFT: viewer.step(slice: -1)
    case VK_UP: viewer.step(channel: 1)
    case VK_DOWN: viewer.step(channel: -1)
    case VK_NEXT: viewer.step(frame: 1)
    case VK_PRIOR: viewer.step(frame: -1)
    default: return
    }
    refresh()
}

func openImage(path: String) {
    do {
        try viewer.open(path: path)
    } catch {
        showMessage("\(error)", title: "Can't Open File", owner: viewer.window, isError: true)
    }
    refresh()
}

func refresh() {
    _ = SetWindowTextW(viewer.window, viewer.title.wide)
    _ = InvalidateRect(viewer.window, nil, false)
}

func paint(_ window: HWND?) {
    var paintInfo = PAINTSTRUCT()
    guard let dc = BeginPaint(window, &paintInfo) else { return }
    defer { _ = EndPaint(window, &paintInfo) }

    var client = RECT()
    _ = GetClientRect(window, &client)
    _ = FillRect(dc, &client, backgroundBrush)

    guard let image = viewer.image, !viewer.pixels.isEmpty else {
        _ = SetBkMode(dc, TRANSPARENT)
        _ = SetTextColor(dc, colorRef(0xC2, 0xEA, 0xFB))
        let hint = "Open a TIFF image with File ▸ Open (Ctrl+O), or drop one here."
        _ = DrawTextW(dc, hint.wide, -1, &client, UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE))
        return
    }

    // Fit the image in the window, keeping its aspect ratio.
    let margin = 16.0
    let availableWidth = max(Double(client.right - client.left) - 2 * margin, 1)
    let availableHeight = max(Double(client.bottom - client.top) - 2 * margin, 1)
    let scale = min(availableWidth / Double(image.width), availableHeight / Double(image.height))
    let width = max(Int32(Double(image.width) * scale), 1)
    let height = max(Int32(Double(image.height) * scale), 1)
    let x = (client.right - client.left - width) / 2
    let y = (client.bottom - client.top - height) / 2

    var bitmap = BITMAPINFO()
    bitmap.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
    bitmap.bmiHeader.biWidth = LONG(image.width)
    bitmap.bmiHeader.biHeight = -LONG(image.height)  // top-down rows
    bitmap.bmiHeader.biPlanes = 1
    bitmap.bmiHeader.biBitCount = 32
    bitmap.bmiHeader.biCompression = DWORD(BI_RGB)
    _ = SetStretchBltMode(dc, COLORONCOLOR)  // nearest neighbor, like ImageJ
    viewer.pixels.withUnsafeBytes { bytes in
        _ = StretchDIBits(
            dc, x, y, width, height,
            0, 0, Int32(image.width), Int32(image.height),
            bytes.baseAddress, &bitmap, UINT(DIB_RGB_COLORS), sourceCopy
        )
    }
}
#endif
