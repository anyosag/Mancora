// Runs ImageJ's own filters over deterministic test images, so Mancora's
// filter tests compare against ImageJ itself rather than against code written
// alongside the port.
//
//   java -Djava.awt.headless=true -cp ij.jar FilterFixtures.java <repo-root>
//
// Writes Tests/Fixtures/process/filters.json:
//   "inputs": SHA-256 of every input image, so the Swift tests can check that
//             they rebuild exactly the same pixels (see Inputs below);
//   "cases":  one entry per filter run: the filter, its parameters, the input,
//             the SHA-256 of the output pixels and a few sample values.
//
// Pixel byte layout hashed (row-major, no padding):
//   gray8   1 byte per pixel
//   gray16  2 bytes per pixel, little-endian
//   float   4 bytes per pixel, the IEEE-754 bits little-endian; every NaN is
//           hashed as 0x7FC00000 (Float.floatToIntBits), because the sign and
//           payload of a NaN produced by arithmetic differ between CPUs
//   rgb     3 bytes per pixel: red, green, blue (alpha is ignored)
// Samples map a pixel index to its value: decimal for gray8/16, Java's
// Float.toString for float, and "rrggbb" hex for RGB.
//
// The input formulas must match Tests/MancoraProcessTests/FilterInputs.swift.
//
// Filters are called through the same methods ImageJ's commands use, set up as
// the commands set them up:
//   Gaussian Blur  GaussianBlur.blurGaussian(ip, sigmaX, sigmaY, accuracy)
//   rank filters   RankFilters.rank(ip, radius, type, whichOutliers, threshold)
//                  (Despeckle is the median with radius 1)
//   3x3 filters    ip.smooth(), ip.sharpen(), ip.findEdges()
//   Convolve       Convolver.convolve on each channel converted to float, as
//                  PlugInFilterRunner does for its CONVERT_TO_FLOAT flag
//   Binary         Binary.run(ip) with Prefs.blackBackground, Prefs.padEdges
//                  and Binary's iterations and count set, and no snapshot, as
//                  for stack slices. On a single image PlugInFilterRunner takes
//                  a snapshot for Undo first, and Outline with a black
//                  background then reads that stale snapshot instead of the
//                  inverted pixels; one "outlineSnapshotQuirk" case records it.
//
// Not recorded, because ImageJ fails: Outline of a one-pixel-wide image
// (ArrayIndexOutOfBoundsException in BinaryProcessor.process).

import ij.IJ;
import ij.ImagePlus;
import ij.Prefs;
import ij.plugin.filter.Binary;
import ij.plugin.filter.Convolver;
import ij.plugin.filter.GaussianBlur;
import ij.plugin.filter.RankFilters;
import ij.process.*;
import java.io.File;
import java.lang.reflect.Field;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

public class FilterFixtures {

    // MARK: Inputs

    /** A 31-bit integer hash of a pixel position (Java int arithmetic wraps). */
    static int hash(int x, int y, int seed) {
        int h = x * 0x27d4eb2d + y * 0x165667b1 + seed * 0x9e3779b9;
        h ^= h >>> 15;
        h *= 0x85ebca6b;
        h ^= h >>> 13;
        return h & 0x7fffffff;
    }

    /** True inside the disc in the middle of the image. */
    static boolean disc(int x, int y, int w, int h) {
        int dx = x - w / 2, dy = y - h / 2, r = h / 4;
        return dx * dx + dy * dy <= r * r;
    }

    /** A constant band at the top, a 0/255 checkerboard at the right, a bright disc, and a noisy gradient elsewhere. */
    static int gray8(int x, int y, int w, int h) {
        if (y < h / 6) return 100;
        if (x >= w - w / 6) return ((x + y) & 1) == 0 ? 0 : 255;
        if (disc(x, y, w, h)) return 230;
        return Math.min(255, x * 4 + y * 3 + (hash(x, y, 1) & 63));
    }

    static int gray16(int x, int y, int w, int h) {
        if (y < h / 6) return 1000;
        if (x >= w - w / 6) return ((x + y) & 1) == 0 ? 0 : 65535;
        if (disc(x, y, w, h)) return 50000;
        return Math.min(65535, x * 1500 + y * 700 + (hash(x, y, 2) & 4095));
    }

    /** Finite floats: negative, fractional and large values. */
    static float gray32(int x, int y, int w, int h) {
        if (y < h / 6) return 12.5f;
        if (x >= w - w / 6) return ((x + y) & 1) == 0 ? -2.5e4f : 1.0e5f;
        if (disc(x, y, w, h)) return -7.25f;
        return (float) (hash(x, y, 3) & 0xffff) / 256f - 100f + x * 0.37f;
    }

    /** gray32 with NaN, infinities, -0, near-overflow and subnormal values sprinkled in. */
    static float floatSpecial(int x, int y, int w, int h) {
        switch (hash(x, y, 4) % 97) {
            case 0: return Float.NaN;
            case 1: return Float.POSITIVE_INFINITY;
            case 2: return Float.NEGATIVE_INFINITY;
            case 3: return -0.0f;
            case 4: return 3.0e38f;
            case 5: return -3.0e38f;
            case 6: return 1.0e-40f;
            default: return gray32(x, y, w, h);
        }
    }

    static int rgb(int x, int y, int w, int h) {
        return gray8(x, y, w, h) << 16 | gray8(w - 1 - x, h - 1 - y, w, h) << 8 | (hash(x, y, 5) & 255);
    }

    /** 0/255 objects: a ring with a hole, a block with a hole, a bar and a block on the edges, a diagonal line, specks. */
    static int binary(int x, int y, int w, int h) {
        int cx = w / 3, cy = h / 2, dx = x - cx, dy = y - cy, d2 = dx * dx + dy * dy;
        boolean on = (d2 >= 9 && d2 < 30)
            || (x >= w / 2 + 2 && x < w / 2 + 11 && y >= 2 && y < 10 && !(x >= w / 2 + 5 && x < w / 2 + 8 && y >= 5 && y < 7))
            || (x < 4 && y > h / 2 && y < h - 3)
            || (x >= w - 5 && y >= h - 4)
            || (x - y == w / 2 && x > w / 2)
            || hash(x, y, 7) % 23 == 0;
        return on ? 255 : 0;
    }

    static ImageProcessor make(String pattern, int w, int h) {
        ImageProcessor ip;
        switch (pattern) {
            case "gray8": case "binary": ip = new ByteProcessor(w, h); break;
            case "gray16": ip = new ShortProcessor(w, h); break;
            case "float": case "floatSpecial": ip = new FloatProcessor(w, h); break;
            case "rgb": ip = new ColorProcessor(w, h); break;
            default: throw new IllegalArgumentException(pattern);
        }
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                switch (pattern) {
                    case "gray8": ip.set(x, y, gray8(x, y, w, h)); break;
                    case "binary": ip.set(x, y, binary(x, y, w, h)); break;
                    case "gray16": ip.set(x, y, gray16(x, y, w, h)); break;
                    case "float": ip.setf(x, y, gray32(x, y, w, h)); break;
                    case "floatSpecial": ip.setf(x, y, floatSpecial(x, y, w, h)); break;
                    case "rgb": ip.set(x, y, rgb(x, y, w, h)); break;
                }
            }
        return ip;
    }

    // MARK: Hashing and JSON

    static byte[] bytes(ImageProcessor ip) {
        int n = ip.getWidth() * ip.getHeight();
        Object px = ip.getPixels();
        if (px instanceof byte[]) return ((byte[]) px).clone();
        if (px instanceof short[]) {
            short[] s = (short[]) px;
            byte[] b = new byte[2 * n];
            for (int i = 0; i < n; i++) { b[2 * i] = (byte) s[i]; b[2 * i + 1] = (byte) (s[i] >> 8); }
            return b;
        }
        if (px instanceof float[]) {
            float[] f = (float[]) px;
            byte[] b = new byte[4 * n];
            for (int i = 0; i < n; i++) {
                int bits = Float.floatToIntBits(f[i]);  // canonical NaN
                for (int k = 0; k < 4; k++) b[4 * i + k] = (byte) (bits >> (8 * k));
            }
            return b;
        }
        int[] c = (int[]) px;
        byte[] b = new byte[3 * n];
        for (int i = 0; i < n; i++) { b[3 * i] = (byte) (c[i] >> 16); b[3 * i + 1] = (byte) (c[i] >> 8); b[3 * i + 2] = (byte) c[i]; }
        return b;
    }

    static String sha256(ImageProcessor ip) throws Exception {
        byte[] d = MessageDigest.getInstance("SHA-256").digest(bytes(ip));
        StringBuilder sb = new StringBuilder();
        for (byte v : d) sb.append(String.format("%02x", v & 0xff));
        return sb.toString();
    }

    static String sample(ImageProcessor ip, int i) {
        Object px = ip.getPixels();
        if (px instanceof byte[]) return Integer.toString(((byte[]) px)[i] & 0xff);
        if (px instanceof short[]) return Integer.toString(((short[]) px)[i] & 0xffff);
        if (px instanceof float[]) return Float.toString(((float[]) px)[i]);
        return String.format("%06x", ((int[]) px)[i] & 0xffffff);
    }

    static String num(double v) {
        if (v == Math.rint(v) && Math.abs(v) < 1e15) return Long.toString((long) v);
        return Double.toString(v);
    }

    static final List<String> cases = new ArrayList<>();
    static final Map<String, String> inputs = new LinkedHashMap<>();

    /** Runs `filter` on a fresh copy of the input and records the result. */
    static void record(String filter, String pattern, int w, int h, String params, Filter op) throws Exception {
        String inputName = pattern + "-" + w + "x" + h;
        if (!inputs.containsKey(inputName)) inputs.put(inputName, sha256(make(pattern, w, h)));
        ImageProcessor ip = make(pattern, w, h);
        op.run(ip);
        int n = w * h;
        int[] at = {0, w - 1, n / 2, n - w, n - 1, hash(w, h, cases.size()) % n};
        StringBuilder s = new StringBuilder();
        for (int i = 0; i < at.length; i++) {
            if (i > 0) s.append(", ");
            s.append('"').append(at[i]).append("\": \"").append(sample(ip, at[i])).append('"');
        }
        cases.add("    {\"filter\": \"" + filter + "\", \"input\": \"" + inputName + "\", \"params\": {" + params
            + "}, \"sha256\": \"" + sha256(ip) + "\", \"samples\": {" + s + "}}");
    }

    interface Filter { void run(ImageProcessor ip) throws Exception; }

    // MARK: Cases

    static final String[] TYPES = {"gray8", "gray16", "float", "floatSpecial", "rgb"};
    static final int W = 37, H = 23;

    public static void main(String[] args) throws Exception {
        Locale.setDefault(Locale.ROOT);
        gaussian();
        rank();
        threeByThree();
        convolve();
        binaryOps();
        File out = new File(args[0], "Tests/Fixtures/process/filters.json");
        out.getParentFile().mkdirs();
        StringBuilder sb = new StringBuilder();
        sb.append("{\n  \"imagej\": \"").append(IJ.getVersion()).append("\",\n  \"inputs\": {\n");
        int k = 0;
        for (Map.Entry<String, String> e : inputs.entrySet())
            sb.append("    \"").append(e.getKey()).append("\": \"").append(e.getValue()).append('"')
              .append(++k < inputs.size() ? ",\n" : "\n");
        sb.append("  },\n  \"cases\": [\n").append(String.join(",\n", cases)).append("\n  ]\n}\n");
        Files.write(out.toPath(), sb.toString().getBytes(StandardCharsets.UTF_8));
        System.out.println("ImageJ " + IJ.getVersion() + ": " + cases.size() + " filter cases written");
        System.exit(0);  // ImageJ's worker threads would keep the JVM alive
    }

    static void gaussian() throws Exception {
        double[][] sigmas = {{0.4, 0.4}, {1, 1}, {1.5, 1.5}, {2.7, 2.7}, {5, 5}, {2, 0.8}, {0, 3}, {3, 0},
            {8.6, 8.6}, {12, 4}};
        for (String t : TYPES)
            for (double[] s : sigmas) {
                if (t.equals("floatSpecial") && s[0] > 1) continue;  // NaNs would cover everything
                gaussianCase(t, W, H, s[0], s[1], defaultAccuracy(t));
            }
        for (String t : new String[] {"gray8", "gray16", "float", "rgb"})
            for (double[] s : new double[][] {{9, 9}, {12.5, 12.5}, {30, 30}, {20, 3}, {60, 60}})
                gaussianCase(t, 150, 97, s[0], s[1], defaultAccuracy(t));
        gaussianCase("gray16", W, H, 8, 8, 1e-12);   // kernel longer than the line (maxRadius)
        gaussianCase("float", W, H, 2, 2, 0.01);
        gaussianCase("gray8", W, H, 1.2, 1.2, 0.0002);
        gaussianCase("gray8", 1, 9, 1.5, 1.5, 0.002);
        gaussianCase("float", 9, 1, 2.5, 2.5, 0.0002);
    }

    static double defaultAccuracy(String t) {
        return t.equals("gray8") || t.equals("rgb") ? 0.002 : 0.0002;
    }

    static void gaussianCase(String t, int w, int h, double sx, double sy, double acc) throws Exception {
        record("gaussian", t, w, h, "\"sigmaX\": " + num(sx) + ", \"sigmaY\": " + num(sy) + ", \"accuracy\": " + num(acc),
            ip -> new GaussianBlur().blurGaussian(ip, sx, sy, acc));
    }

    static void rank() throws Exception {
        String[] names = {"mean", "minimum", "maximum", "variance", "median"};
        int[] types = {RankFilters.MEAN, RankFilters.MIN, RankFilters.MAX, RankFilters.VARIANCE, RankFilters.MEDIAN};
        double[] radii = {0.5, 1, 1.5, 2, 2.5, 3.3, 6, 14};
        for (String t : TYPES)
            for (int f = 0; f < names.length; f++)
                for (double r : radii)
                    rankCase(names[f], types[f], t, W, H, r, 0, 0);
        for (String t : TYPES)
            for (int which = 0; which < 2; which++)
                for (double r : new double[] {1, 2.5})
                    for (double threshold : new double[] {0, outlierThreshold(t)})
                        rankCase(which == 0 ? "outliersBright" : "outliersDark", RankFilters.OUTLIERS, t, W, H, r, which, threshold);
        for (double r : new double[] {0.5, 1, 2, 5})
            rankCase("removeNaNs", RankFilters.REMOVE_NAN, "floatSpecial", W, H, r, 0, 0);
        rankCase("removeNaNs", RankFilters.REMOVE_NAN, "float", W, H, 2, 0, 0);
        for (String t : TYPES)
            rankCase("despeckle", RankFilters.MEDIAN, t, W, H, 1, 0, 0);
        rankCase("median", RankFilters.MEDIAN, "gray16", 150, 97, 3, 0, 0);
        rankCase("mean", RankFilters.MEAN, "float", 150, 97, 5, 0, 0);
        rankCase("variance", RankFilters.VARIANCE, "gray8", 150, 97, 4, 0, 0);
        rankCase("maximum", RankFilters.MAX, "rgb", 150, 97, 7.5, 0, 0);
        rankCase("median", RankFilters.MEDIAN, "gray8", 1, 9, 2, 0, 0);
        rankCase("mean", RankFilters.MEAN, "float", 9, 1, 2, 0, 0);
    }

    static double outlierThreshold(String t) {
        switch (t) {
            case "gray16": return 3000;
            case "float": case "floatSpecial": return 15.5;
            default: return 20;
        }
    }

    static void rankCase(String name, int type, String t, int w, int h, double r, int which, double threshold) throws Exception {
        String params = "\"radius\": " + num(r);
        if (type == RankFilters.OUTLIERS) params += ", \"threshold\": " + num(threshold);
        record(name, t, w, h, params, ip -> new RankFilters().rank(ip, r, type, which, (float) threshold));
    }

    static void threeByThree() throws Exception {
        int[][] sizes = {{W, H}, {1, 5}, {5, 1}, {2, 2}, {3, 3}, {4, 2}};
        for (String t : TYPES)
            for (int[] s : sizes) {
                if (t.equals("floatSpecial") && s[0] != W) continue;
                record("smooth", t, s[0], s[1], "", ImageProcessor::smooth);
                record("sharpen", t, s[0], s[1], "", ImageProcessor::sharpen);
                record("findEdges", t, s[0], s[1], "", ImageProcessor::findEdges);
            }
    }

    static void convolve() throws Exception {
        Object[][] kernels = {
            {3, 3, new float[] {1, 2, 1, 2, 4, 2, 1, 2, 1}},
            {5, 5, new float[] {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, 24, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1}},
            {7, 1, new float[] {1, 2, 3, 4, 3, 2, 1}},
            {1, 7, new float[] {0.5f, -1, 2.25f, 3, 2.25f, -1, 0.5f}},
            {3, 5, new float[] {0.1f, 0.2f, 0.3f, -0.4f, 1.5f, 0.25f, 0, 0.7f, -0.05f, 0.33f, 0.66f, 0.99f, -1, 0.5f, 0.125f}},
            {1, 1, new float[] {2.5f}},
        };
        for (String t : TYPES)
            for (Object[] k : kernels)
                for (boolean normalize : new boolean[] {true, false})
                    convolveCase(t, W, H, (Integer) k[0], (Integer) k[1], (float[]) k[2], normalize);
        // Kernels larger than the image.
        convolveCase("gray8", 1, 5, 5, 5, (float[]) kernels[1][2], false);
        convolveCase("float", 5, 1, 3, 5, (float[]) kernels[4][2], true);
        convolveCase("gray16", 2, 3, 5, 5, (float[]) kernels[1][2], true);
    }

    static void convolveCase(String t, int w, int h, int kw, int kh, float[] kernel, boolean normalize) throws Exception {
        StringBuilder k = new StringBuilder();
        for (int i = 0; i < kernel.length; i++) k.append(i > 0 ? ", " : "").append(Float.toString(kernel[i]));
        String params = "\"kernelWidth\": " + kw + ", \"kernel\": [" + k + "], \"normalize\": " + normalize;
        record("convolve", t, w, h, params, ip -> {
            Convolver cv = new Convolver();
            cv.setNormalize(normalize);
            for (int c = 0; c < ip.getNChannels(); c++) {   // as PlugInFilterRunner's CONVERT_TO_FLOAT
                FloatProcessor fp = ip.toFloat(c, null);
                fp.snapshot();
                cv.convolve(fp, kernel, kw, kh);
                ip.setPixels(c, fp);
            }
        });
    }

    static void setStatic(String name, int value) throws Exception {
        Field f = Binary.class.getDeclaredField(name);
        f.setAccessible(true);
        f.setInt(null, value);
    }

    static Filter binaryOp(String op, boolean blackBackground, int iterations, int count, boolean padEdges, boolean snapshot) {
        return ip -> {
            Prefs.blackBackground = blackBackground;
            Prefs.padEdges = padEdges;
            setStatic("iterations", iterations);
            setStatic("count", count);
            Binary b = new Binary();
            b.setup(op, new ImagePlus("mask", ip));
            if (snapshot) ip.snapshot();
            b.run(ip);
        };
    }

    static void binaryCase(String op, int w, int h, boolean bb, int iterations, int count, boolean pad) throws Exception {
        String params = "\"blackBackground\": " + bb + ", \"iterations\": " + iterations + ", \"count\": " + count
            + ", \"padEdges\": " + pad;
        record(op, "binary", w, h, params, binaryOp(op, bb, iterations, count, pad, false));
    }

    static void binaryOps() throws Exception {
        int[][] sizes = {{W, H}, {64, 48}};
        for (int[] s : sizes)
            for (boolean bb : new boolean[] {true, false}) {
                for (String op : new String[] {"erode", "dilate", "open", "close"})
                    for (int iterations : new int[] {1, 3})
                        for (int count : new int[] {1, 4})
                            for (boolean pad : new boolean[] {false, true}) {
                                if (op.equals("dilate") && pad) continue;  // padEdges only affects erosion
                                binaryCase(op, s[0], s[1], bb, iterations, count, pad);
                            }
                for (String op : new String[] {"outline", "fill", "skeletonize"})
                    binaryCase(op, s[0], s[1], bb, 1, 1, false);
            }
        for (int[] s : new int[][] {{1, 6}, {6, 1}, {2, 2}, {3, 4}})
            for (boolean bb : new boolean[] {true, false})
                for (String op : new String[] {"erode", "dilate", "outline", "fill", "skeletonize"}) {
                    if (op.equals("outline") && s[0] == 1) continue;  // ImageJ throws ArrayIndexOutOfBounds
                    binaryCase(op, s[0], s[1], bb, 1, 1, false);
                }
        // ImageJ's single-image Outline with a black background reads a stale snapshot (see the top).
        record("outlineSnapshotQuirk", "binary", W, H, "\"blackBackground\": true, \"iterations\": 1, \"count\": 1, \"padEdges\": false",
            binaryOp("outline", true, 1, 1, false, true));
    }
}
