// Checks that ImageJ reopens TIFFs saved by Mancora exactly as it opens the
// originals: same hyperstack layout and type, pixels, calibration, display
// ranges and LUTs, composite mode, slice labels, Info, properties, selection
// and overlay.
//
//   java -Djava.awt.headless=true -cp ij.jar TiffReopen.java make <dir>
//       saves a varied set of images with ImageJ's FileSaver into <dir>
//   java -Djava.awt.headless=true -cp ij.jar TiffReopen.java compare <originals> <copies> [strict-prefix ...]
//       opens <originals>/X.tif and <copies>/X.tif with ImageJ and compares
//       them; files starting with a strict prefix must match, others are
//       reported (ImageJ's own reader may fail or differ on them)
//
// Run both through Tools/parity/tiff-reopen.sh.

import ij.CompositeImage;
import ij.IJ;
import ij.ImagePlus;
import ij.ImageStack;
import ij.Prefs;
import ij.gui.*;
import ij.io.FileSaver;
import ij.io.Opener;
import ij.io.RoiEncoder;
import ij.measure.Calibration;
import ij.plugin.LutLoader;
import ij.process.*;
import java.awt.Color;
import java.io.File;
import java.util.*;

public class TiffReopen {
    static final int W = 45, H = 31;

    public static void main(String[] args) throws Exception {
        if (args.length >= 2 && args[0].equals("make")) {
            make(new File(args[1]));
        } else if (args.length >= 3 && args[0].equals("compare")) {
            List<String> strict = Arrays.asList(args).subList(3, args.length);
            System.exit(compare(new File(args[1]), new File(args[2]), strict));
        } else {
            System.err.println("usage: TiffReopen make <dir> | compare <originals> <copies> [strict-prefix ...]");
            System.exit(2);
        }
    }

    // MARK: Originals

    static void make(File dir) {
        dir.mkdirs();
        save(dir, "8bit-selection-overlay", gray8WithRois(), true);
        save(dir, "8bit-fire-range", withLut(gray8(0), "Fire", 20, 200), true);
        ImagePlus inverted = gray8(1);
        inverted.getProcessor().invertLut();
        save(dir, "8bit-inverted-lut", inverted, false);
        save(dir, "16bit-microns-inexact", calibrated(gray16(2), 0.3, 0.7, "µm"), true);
        save(dir, "16bit-inch", calibrated(gray16(3), 1.0 / 300, 1.0 / 300, "inch"), false);
        save(dir, "16bit-cm-range", ranged(calibrated(gray16(4), 0.01, 0.02, "cm"), 1000, 20000), true);
        ImagePlus signed = gray16(5);
        signed.getCalibration().setSigned16BitCalibration();
        save(dir, "16bit-signed", signed, true);
        save(dir, "32bit-nan-inf-vunit", float32(), false);
        save(dir, "rgb-overlay", rgbWithOverlay(), true);
        save(dir, "stack-8bit-labels-fps", stack8(), true);
        save(dir, "timeseries-16bit-minutes", timeSeries16(), false);
        save(dir, "hyperstack-16bit-3c-custom", composite16(), true);
        save(dir, "hyperstack-16bit-3c-custom-be", composite16(), false);
        save(dir, "composite-8bit-grayscale", composite8(), true);
        save(dir, "composite-32bit-color", composite32(), true);
        System.out.println("ImageJ " + IJ.getVersion() + " originals written to " + dir);
    }

    static void save(File dir, String name, ImagePlus imp, boolean intelByteOrder) {
        boolean saved = Prefs.intelByteOrder;
        Prefs.intelByteOrder = intelByteOrder;
        if (!new FileSaver(imp).saveAsTiff(new File(dir, name + ".tif").getPath()))
            throw new RuntimeException("ImageJ could not save " + name);
        Prefs.intelByteOrder = saved;
    }

    /** A deterministic pattern with a little noise, so every plane differs. */
    static double pattern(int x, int y, int k) {
        long h = (x * 73856093L) ^ (y * 19349663L) ^ (k * 83492791L);
        return x * 3 + y * 5 + k * 17 + (h & 7);
    }

    static ImagePlus gray8(int k) {
        ByteProcessor bp = new ByteProcessor(W, H);
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++)
                bp.set(x, y, (int) pattern(x, y, k) & 255);
        return new ImagePlus("gray8", bp);
    }

    static ImagePlus gray16(int k) {
        ShortProcessor sp = new ShortProcessor(W, H);
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++)
                sp.set(x, y, ((int) pattern(x, y, k) * 97) & 0xffff);
        sp.resetMinAndMax();
        return new ImagePlus("gray16", sp);
    }

    static ImagePlus withLut(ImagePlus imp, String lut, double min, double max) {
        imp.getProcessor().setColorModel(LutLoader.getLut(lut));
        imp.setDisplayRange(min, max);
        return imp;
    }

    static ImagePlus ranged(ImagePlus imp, double min, double max) {
        imp.setDisplayRange(min, max);
        return imp;
    }

    static ImagePlus calibrated(ImagePlus imp, double pw, double ph, String unit) {
        Calibration cal = imp.getCalibration();
        cal.pixelWidth = pw;
        cal.pixelHeight = ph;
        cal.setUnit(unit);
        return imp;
    }

    static ImagePlus gray8WithRois() {
        ImagePlus imp = gray8(6);
        imp.setRoi(new PolygonRoi(new float[] {2.5f, 30.25f, 12f}, new float[] {3f, 9.5f, 25.75f}, Roi.POLYGON));
        Overlay overlay = new Overlay();
        Roi oval = new OvalRoi(5, 6, 13, 9);
        oval.setName("nucleus");
        oval.setStrokeColor(Color.cyan);
        oval.setStrokeWidth(2);
        overlay.add(oval);
        overlay.add(new Line(1.5, 2.5, 40.25, 28.75));
        overlay.add(new PointRoi(new int[] {3, 9, 27}, new int[] {4, 15, 20}, 3));
        imp.setOverlay(overlay);
        imp.setProperty("Info", "Selection and overlay test\néè ☃");
        imp.setProp("sample", "S-17");
        return imp;
    }

    static ImagePlus float32() {
        FloatProcessor fp = new FloatProcessor(W, H);
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++)
                fp.setf(x, y, (float) (pattern(x, y, 7) * 0.013 - 1.5));
        fp.setf(0, 0, Float.NaN);
        fp.setf(1, 0, Float.POSITIVE_INFINITY);
        fp.setf(2, 0, Float.NEGATIVE_INFINITY);
        fp.setLut(new LUT(LutLoader.getLut("Ice"), 0, 0));
        ImagePlus imp = new ImagePlus("float", fp);
        imp.getCalibration().setValueUnit("mOD");
        imp.setDisplayRange(-1.25, 2.5);
        return imp;
    }

    static ImagePlus rgbWithOverlay() {
        ColorProcessor cp = new ColorProcessor(W, H);
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++)
                cp.set(x, y, ((int) pattern(x, y, 8) & 255) << 16 | ((x * 5) & 255) << 8 | ((y * 7) & 255));
        ImagePlus imp = new ImagePlus("rgb", cp);
        Overlay overlay = new Overlay(new Roi(3, 3, 20, 10, 6));  // rounded rectangle
        imp.setOverlay(overlay);
        return imp;
    }

    static ImagePlus stack8() {
        ImageStack stack = new ImageStack(W, H);
        for (int k = 0; k < 6; k++)
            stack.addSlice(k == 3 ? null : "z=" + k + (k == 1 ? " µ" : ""), gray8(10 + k).getProcessor());
        ImagePlus imp = new ImagePlus("stack", stack);
        Calibration cal = imp.getCalibration();
        cal.pixelWidth = cal.pixelHeight = 0.5;
        cal.pixelDepth = 1.75;
        cal.setUnit("micron");
        cal.fps = 12.5;
        cal.loop = true;
        cal.zOrigin = -2;
        return imp;
    }

    static ImagePlus timeSeries16() {
        ImageStack stack = new ImageStack(W, H);
        for (int k = 0; k < 5; k++)
            stack.addSlice(null, gray16(20 + k).getProcessor());
        ImagePlus imp = new ImagePlus("time", stack);
        imp.setDimensions(1, 1, 5);
        Calibration cal = imp.getCalibration();
        cal.frameInterval = 0.25;
        cal.setTimeUnit("min");
        imp.setDisplayRange(500, 30000);
        return imp;
    }

    static ImagePlus composite16() {
        int c = 3, z = 4, t = 2;
        ImageStack stack = new ImageStack(W, H);
        for (int k = 0; k < c * z * t; k++)
            stack.addSlice("plane " + k, gray16(30 + k).getProcessor());
        ImagePlus imp = new ImagePlus("composite", stack);
        imp.setDimensions(c, z, t);
        imp.setOpenAsHyperStack(true);
        Calibration cal = imp.getCalibration();
        cal.pixelWidth = 0.065;
        cal.pixelHeight = 0.065;
        cal.pixelDepth = 0.3;
        cal.setUnit("µm");
        cal.setYUnit("nm");
        cal.setZUnit("mm");
        cal.frameInterval = 30;
        cal.xOrigin = 12.5;
        cal.yOrigin = -3;
        cal.setInvertY(true);
        CompositeImage ci = new CompositeImage(imp, IJ.COMPOSITE);
        ci.setChannelLut(new LUT(LutLoader.getLut("Fire"), 0, 0), 1);
        ci.setChannelLut(LUT.createLutFromColor(Color.orange), 2);
        ci.setChannelLut(LUT.createLutFromColor(Color.white), 3);
        double[][] ranges = {{100, 40000}, {0, 65535}, {2000, 2100}};
        for (int ch = 1; ch <= c; ch++) {
            ci.setPosition(ch, 1, 1);
            ci.setDisplayRange(ranges[ch - 1][0], ranges[ch - 1][1]);
        }
        ci.setPosition(1, 1, 1);
        ci.setProperty("Info", "Three-channel test\nline two");
        ci.setProp("Instrument", "Mancora parity rig");
        ci.setProp("Gain", "2.5");
        return ci;
    }

    static ImagePlus composite8() {
        ImageStack stack = new ImageStack(W, H);
        for (int k = 0; k < 2; k++)
            stack.addSlice(null, gray8(40 + k).getProcessor());
        ImagePlus imp = new ImagePlus("gray composite", stack);
        imp.setDimensions(2, 1, 1);
        CompositeImage ci = new CompositeImage(imp, IJ.GRAYSCALE);
        ci.setPosition(2, 1, 1);
        ci.setDisplayRange(30, 90);
        ci.setPosition(1, 1, 1);
        return ci;
    }

    static ImagePlus composite32() {
        ImageStack stack = new ImageStack(W, H);
        for (int k = 0; k < 4; k++) {
            FloatProcessor fp = new FloatProcessor(W, H);
            for (int y = 0; y < H; y++)
                for (int x = 0; x < W; x++)
                    fp.setf(x, y, (float) (pattern(x, y, 50 + k) / 7.0));
            stack.addSlice(null, fp);
        }
        ImagePlus imp = new ImagePlus("float composite", stack);
        imp.setDimensions(2, 2, 1);
        imp.setOpenAsHyperStack(true);
        CompositeImage ci = new CompositeImage(imp, IJ.COLOR);
        ci.setPosition(1, 1, 1);
        ci.setDisplayRange(-0.5, 20.25);
        ci.setPosition(2, 1, 1);
        ci.setDisplayRange(3, 7);
        ci.setPosition(1, 1, 1);
        return ci;
    }

    // MARK: Comparison

    static int compare(File originals, File copies, List<String> strict) {
        File[] files = copies.listFiles((d, n) -> n.endsWith(".tif"));
        Arrays.sort(files);
        int failures = 0, matched = 0, rescued = 0, differing = 0;
        for (File copyFile : files) {
            String name = copyFile.getName();
            boolean isStrict = strict.isEmpty() || strict.stream().anyMatch(name::startsWith);
            ImagePlus original = quietOpen(new File(originals, name));
            ImagePlus copy = quietOpen(copyFile);
            if (copy == null) {
                System.out.println("FAIL  " + name + ": ImageJ cannot open Mancora's copy");
                failures++;
                continue;
            }
            if (original == null) {
                System.out.println("NEW   " + name + ": ImageJ cannot open the original; Mancora's copy opens as "
                    + copy.getWidth() + "x" + copy.getHeight() + " " + copy.getBitDepth() + "-bit, "
                    + copy.getNChannels() + "c " + copy.getNSlices() + "z " + copy.getNFrames() + "t");
                rescued++;
                continue;
            }
            List<String> diffs = differences(original, copy);
            if (diffs.isEmpty()) {
                System.out.println("OK    " + name);
                matched++;
            } else if (isStrict) {
                System.out.println("FAIL  " + name + ": " + String.join("; ", diffs));
                failures++;
            } else {
                System.out.println("DIFF  " + name + " (ImageJ reads the original differently): "
                    + String.join("; ", diffs));
                differing++;
            }
        }
        System.out.println(matched + " identical, " + rescued + " ImageJ could only open via Mancora, "
            + differing + " read differently by ImageJ, " + failures + " failures");
        return failures == 0 ? 0 : 1;
    }

    static ImagePlus quietOpen(File f) {
        try {
            return new Opener().openImage(f.getPath());
        } catch (Throwable e) {
            return null;
        }
    }

    static List<String> differences(ImagePlus a, ImagePlus b) {
        List<String> d = new ArrayList<>();
        check(d, "size", a.getWidth() + "x" + a.getHeight(), b.getWidth() + "x" + b.getHeight());
        check(d, "type", a.getType(), b.getType());
        check(d, "dimensions", Arrays.toString(a.getDimensions()), Arrays.toString(b.getDimensions()));
        check(d, "composite", a.isComposite(), b.isComposite());
        if (a.isComposite() && b.isComposite())
            check(d, "mode", ((CompositeImage) a).getModeAsString(), ((CompositeImage) b).getModeAsString());
        if (!d.isEmpty()) return d;

        ImageStack sa = a.getStack(), sb = b.getStack();
        for (int i = 1; i <= sa.size(); i++) {
            if (!samePixels(sa.getPixels(i), sb.getPixels(i))) d.add("pixels of plane " + i);
            check(d, "label " + i, sa.getSliceLabel(i), sb.getSliceLabel(i));
        }

        Calibration ca = a.getCalibration(), cb = b.getCalibration();
        close(d, "pixelWidth", ca.pixelWidth, cb.pixelWidth);
        close(d, "pixelHeight", ca.pixelHeight, cb.pixelHeight);
        check(d, "pixelDepth", ca.pixelDepth, cb.pixelDepth);
        check(d, "unit", ca.getUnit(), cb.getUnit());
        check(d, "yunit", ca.getYUnit(), cb.getYUnit());
        check(d, "zunit", ca.getZUnit(), cb.getZUnit());
        check(d, "frameInterval", ca.frameInterval, cb.frameInterval);
        check(d, "timeUnit", ca.getTimeUnit(), cb.getTimeUnit());
        check(d, "fps", ca.fps, cb.fps);
        check(d, "loop", ca.loop, cb.loop);
        check(d, "origin", ca.xOrigin + "," + ca.yOrigin + "," + ca.zOrigin, cb.xOrigin + "," + cb.yOrigin + "," + cb.zOrigin);
        check(d, "invertY", ca.getInvertY(), cb.getInvertY());
        check(d, "function", ca.getFunction(), cb.getFunction());
        check(d, "coefficients", Arrays.toString(ca.getCoefficients()), Arrays.toString(cb.getCoefficients()));
        check(d, "valueUnit", ca.getValueUnit(), cb.getValueUnit());

        if (a.isComposite()) {
            CompositeImage xa = (CompositeImage) a, xb = (CompositeImage) b;
            for (int c = 1; c <= a.getNChannels(); c++) {
                LUT la = xa.getChannelLut(c), lb = xb.getChannelLut(c);
                if (!Arrays.equals(la.getBytes(), lb.getBytes())) d.add("LUT of channel " + c);
                check(d, "range of channel " + c, la.min + "-" + la.max, lb.min + "-" + lb.max);
            }
        } else if (a.getType() != ImagePlus.COLOR_RGB) {
            if (!Arrays.equals(a.getProcessor().getLut().getBytes(), b.getProcessor().getLut().getBytes()))
                d.add("LUT");
            check(d, "range", a.getDisplayRangeMin() + "-" + a.getDisplayRangeMax(),
                b.getDisplayRangeMin() + "-" + b.getDisplayRangeMax());
            check(d, "invertedLut", a.isInvertedLut(), b.isInvertedLut());
        }

        check(d, "Info", a.getInfoProperty(), b.getInfoProperty());
        check(d, "properties", props(a), props(b));
        check(d, "selection", roiBytes(a.getRoi()), roiBytes(b.getRoi()));
        Overlay oa = a.getOverlay(), ob = b.getOverlay();
        check(d, "overlay size", oa == null ? 0 : oa.size(), ob == null ? 0 : ob.size());
        if (oa != null && ob != null && oa.size() == ob.size())
            for (int i = 0; i < oa.size(); i++)
                check(d, "overlay element " + i, roiBytes(oa.get(i)), roiBytes(ob.get(i)));
        return d;
    }

    static void check(List<String> d, String what, Object a, Object b) {
        if (!Objects.equals(a, b)) d.add(what + " " + a + " vs " + b);
    }

    /** Pixel sizes go through TIFF's rational resolution fields; allow their rounding. */
    static void close(List<String> d, String what, double a, double b) {
        if (Math.abs(a - b) > 1e-6 * Math.abs(a)) d.add(what + " " + a + " vs " + b);
    }

    static boolean samePixels(Object a, Object b) {
        if (a instanceof float[] && b instanceof float[]) {
            float[] x = (float[]) a, y = (float[]) b;
            if (x.length != y.length) return false;
            for (int i = 0; i < x.length; i++)
                if (Float.floatToIntBits(x[i]) != Float.floatToIntBits(y[i])) return false;
            return true;
        }
        if (a instanceof byte[]) return Arrays.equals((byte[]) a, (byte[]) b);
        if (a instanceof short[]) return Arrays.equals((short[]) a, (short[]) b);
        if (a instanceof int[]) return Arrays.equals((int[]) a, (int[]) b);
        return false;
    }

    static String props(ImagePlus imp) {
        String[] p = imp.getPropertiesAsArray();
        if (p == null) return "{}";
        TreeMap<String, String> map = new TreeMap<>();
        for (int i = 0; i + 1 < p.length; i += 2) map.put(p[i], p[i + 1]);
        return map.toString();
    }

    static String roiBytes(Roi roi) {
        if (roi == null) return "none";
        byte[] bytes = RoiEncoder.saveAsByteArray(roi);
        return bytes == null ? "unencodable" : Base64.getEncoder().encodeToString(bytes);
    }
}
