// MancoraViewer: shows TIFF images and stacks with ImageJ LUTs.
//
//   MancoraViewer.exe [image.tif]
//   MancoraViewer.exe --smoke-test image.tif   (exit code 0 if it can open
//                                               and render the image)

#if os(Windows)
runViewer(arguments: Array(CommandLine.arguments.dropFirst()))
#else
print("MancoraViewer is the Windows app; on macOS use Apps/macOS.")
#endif
