// Generates reference data with real ImageJ 1.x, so Mancora's tests compare
// against ImageJ itself rather than against code written alongside the reader.
//
//   java -Djava.awt.headless=true -cp ij.jar ImageJFixtures.java <repo-root>
//
// Writes:
//   Tests/Fixtures/luts-golden.json   every bundled LUT as ImageJ loads it,
//                                     plus ImageJ's built-in LUTs
//   Tests/Fixtures/tiff/ij-*.tif      TIFFs saved by ImageJ's TiffEncoder
//
// Pixel patterns must match Tests/MancoraIOTests/Patterns.swift.

import ij.IJ;
import ij.ImagePlus;
import ij.ImageStack;
import ij.CompositeImage;
import ij.io.FileSaver;
import ij.measure.Calibration;
import ij.plugin.LutLoader;
import ij.process.*;
import java.awt.image.IndexColorModel;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Arrays;

public class ImageJFixtures {
    static final int W = 32, H = 24;

    public static void main(String[] args) throws Exception {
        File root = new File(args[0]);
        writeLutGolden(root);
        File tiffDir = new File(root, "Tests/Fixtures/tiff");
        tiffDir.mkdirs();
        writeHyperstack(new File(tiffDir, "ij-hyperstack-16bit.tif"));
        writeFire8(new File(tiffDir, "ij-8bit-fire.tif"));
        writeStack8(new File(tiffDir, "ij-stack-8bit.tif"));
        writeFloat(new File(tiffDir, "ij-32bit-float.tif"));
        writeRGB(new File(tiffDir, "ij-rgb.tif"));
        System.out.println("ImageJ " + IJ.getVersion() + " fixtures written");
    }

    // MARK: LUTs

    static void writeLutGolden(File root) throws Exception {
        File lutDir = new File(root, "Resources/LUTs");
        File[] files = lutDir.listFiles((d, n) -> !n.equals("README.txt"));
        Arrays.sort(files);
        StringBuilder sb = new StringBuilder();
        sb.append("{\n  \"imagej\": \"").append(IJ.getVersion()).append("\",\n  \"files\": {\n");
        for (int i = 0; i < files.length; i++) {
            LUT lut = LutLoader.openLut("noerror:" + files[i].getPath());
            sb.append("    \"").append(files[i].getName()).append("\": ");
            sb.append(lut == null ? "null" : "\"" + hex(lut) + "\"");
            sb.append(i < files.length - 1 ? ",\n" : "\n");
        }
        sb.append("  },\n  \"builtin\": {\n");
        String[] names = {"Fire", "Grays", "Ice", "Spectrum", "3-3-2 RGB", "Red", "Green", "Blue",
            "Cyan", "Magenta", "Yellow", "Red/Green"};
        for (int i = 0; i < names.length; i++) {
            IndexColorModel cm = LutLoader.getLut(names[i]);
            sb.append("    \"").append(names[i]).append("\": \"").append(hex(cm)).append("\"");
            sb.append(i < names.length - 1 ? ",\n" : "\n");
        }
        sb.append("  }\n}\n");
        Files.write(new File(root, "Tests/Fixtures/luts-golden.json").toPath(),
            sb.toString().getBytes(StandardCharsets.UTF_8));
    }

    /** 768 bytes as hex: 256 reds, then greens, then blues. */
    static String hex(IndexColorModel cm) {
        byte[] r = new byte[256], g = new byte[256], b = new byte[256];
        cm.getReds(r);
        cm.getGreens(g);
        cm.getBlues(b);
        StringBuilder sb = new StringBuilder();
        for (byte[] channel : new byte[][] {r, g, b})
            for (byte v : channel) sb.append(String.format("%02x", v & 0xff));
        return sb.toString();
    }

    // MARK: TIFFs

    /** c=2, z=3, t=4 16-bit composite with spatial and time calibration. */
    static void writeHyperstack(File out) {
        int c = 2, z = 3, t = 4;
        ImagePlus imp = IJ.createHyperStack("hyperstack", W, H, c, z, t, 16);
        ImageStack stack = imp.getStack();
        for (int k = 0; k < c * z * t; k++) {
            short[] px = (short[]) stack.getPixels(k + 1);
            for (int y = 0; y < H; y++)
                for (int x = 0; x < W; x++)
                    px[y * W + x] = (short) hyper(k, x, y);
        }
        Calibration cal = imp.getCalibration();
        cal.pixelWidth = 0.25;
        cal.pixelHeight = 0.5;
        cal.pixelDepth = 2.0;
        cal.setUnit("µm");
        cal.frameInterval = 1.5;
        cal.setTimeUnit("sec");
        imp = new CompositeImage(imp, IJ.COMPOSITE);
        imp.setDisplayRange(10, 4000);
        new FileSaver(imp).saveAsTiff(out.getPath());
    }

    /** Value of plane k (channel fastest) at (x, y); see Patterns.hyperstack. */
    static int hyper(int k, int x, int y) {
        int ch = k % 2, sl = (k / 2) % 3, fr = k / 6;
        return ch * 1000 + sl * 100 + fr * 10 + x + y * 7;
    }

    static void writeFire8(File out) {
        ByteProcessor bp = new ByteProcessor(W, H);
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++)
                bp.set(x, y, (x * 7 + y * 13) & 255);
        bp.setColorModel(LutLoader.getLut("Fire"));
        new FileSaver(new ImagePlus("fire", bp)).saveAsTiff(out.getPath());
    }

    static void writeStack8(File out) {
        ImageStack stack = new ImageStack(W, H);
        for (int k = 0; k < 5; k++) {
            ByteProcessor bp = new ByteProcessor(W, H);
            for (int y = 0; y < H; y++)
                for (int x = 0; x < W; x++)
                    bp.set(x, y, (x * 7 + y * 13 + k * 50) & 255);
            stack.addSlice("slice " + (k + 1), bp);
        }
        new FileSaver(new ImagePlus("stack", stack)).saveAsTiff(out.getPath());
    }

    static void writeFloat(File out) {
        FloatProcessor fp = new FloatProcessor(W, H);
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++)
                fp.setf(x, y, x * 0.25f - y * 0.5f);
        fp.setf(3, 2, Float.NaN);
        ImagePlus imp = new ImagePlus("float", fp);
        Calibration cal = imp.getCalibration();
        cal.pixelWidth = 0.1;
        cal.pixelHeight = 0.1;
        cal.setUnit("mm");
        new FileSaver(imp).saveAsTiff(out.getPath());
    }

    static void writeRGB(File out) {
        ColorProcessor cp = new ColorProcessor(W, H);
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++)
                cp.set(x, y, ((x * 8) & 255) << 16 | ((y * 10) & 255) << 8 | ((x * 3 + y * 5) & 255));
        new FileSaver(new ImagePlus("rgb", cp)).saveAsTiff(out.getPath());
    }
}
