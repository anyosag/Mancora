#if os(Windows)
import WinSDK

// Values of Win32 macros that Swift can't import because they're defined
// with casts or MAKEINTRESOURCE.
let cwUseDefault = Int32(bitPattern: 0x8000_0000)
let overlappedWindowStyle: DWORD = 0x00CF_0000  // WS_OVERLAPPEDWINDOW
let acceptFilesExStyle: DWORD = 0x0000_0010  // WS_EX_ACCEPTFILES
let sourceCopy: DWORD = 0x00CC_0020  // SRCCOPY
var arrowCursor: UnsafePointer<WCHAR>? { UnsafePointer(bitPattern: 32512) }  // IDC_ARROW
/// The application icon linked into the executable from mancora.rc.
var appIconResource: UnsafePointer<WCHAR>? { UnsafePointer(bitPattern: 1) }
let messageBoxOK: UINT = 0x0000_0000
let messageBoxIconError: UINT = 0x0000_0010
let messageBoxIconInformation: UINT = 0x0000_0040
let messageBoxYesNo: UINT = 0x0000_0004
let dialogYes: Int32 = 6  // IDYES
var waitCursor: UnsafePointer<WCHAR>? { UnsafePointer(bitPattern: 32514) }  // IDC_WAIT

extension String {
    /// NUL-terminated UTF-16, for the Win32 "W" functions.
    var wide: [WCHAR] { Array(utf16) + [0] }

    /// Decodes a NUL-terminated UTF-16 buffer.
    init(wide buffer: [WCHAR]) {
        self = String(decoding: buffer.prefix { $0 != 0 }, as: UTF16.self)
    }
}

func colorRef(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> COLORREF {
    COLORREF(red) | COLORREF(green) << 8 | COLORREF(blue) << 16
}

/// The directory holding the running executable, without a trailing slash.
func executableDirectory() -> String {
    var buffer = [WCHAR](repeating: 0, count: 4096)
    let length = Int(GetModuleFileNameW(nil, &buffer, DWORD(buffer.count)))
    let path = String(decoding: buffer.prefix(length), as: UTF16.self)
    guard let slash = path.lastIndex(where: { $0 == "\\" || $0 == "/" }) else { return "." }
    return String(path[..<slash])
}

/// Shows the standard Open dialog; `filter` uses "\0" between
/// description/pattern pairs, as `OPENFILENAMEW` expects.
func chooseFile(owner: HWND?, title: String, filter: String, initialDirectory: String? = nil) -> String? {
    var path = [WCHAR](repeating: 0, count: 4096)
    let filterChars = Array(filter.utf16) + [0, 0]
    let titleChars = title.wide
    let directoryChars = (initialDirectory ?? "").wide
    var dialog = OPENFILENAMEW()
    dialog.lStructSize = DWORD(MemoryLayout<OPENFILENAMEW>.size)
    dialog.hwndOwner = owner
    dialog.Flags = DWORD(OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR)
    let chosen = filterChars.withUnsafeBufferPointer { filterPointer in
        titleChars.withUnsafeBufferPointer { titlePointer in
            directoryChars.withUnsafeBufferPointer { directoryPointer in
                path.withUnsafeMutableBufferPointer { pathPointer in
                    dialog.lpstrFilter = filterPointer.baseAddress
                    dialog.lpstrTitle = titlePointer.baseAddress
                    dialog.lpstrInitialDir = initialDirectory == nil ? nil : directoryPointer.baseAddress
                    dialog.lpstrFile = pathPointer.baseAddress
                    dialog.nMaxFile = DWORD(pathPointer.count)
                    return GetOpenFileNameW(&dialog)
                }
            }
        }
    }
    return chosen ? String(wide: path) : nil
}

func showMessage(_ text: String, title: String, owner: HWND?, isError: Bool) {
    let icon = isError ? messageBoxIconError : messageBoxIconInformation
    _ = MessageBoxW(owner, text.wide, title.wide, messageBoxOK | icon)
}
#endif
