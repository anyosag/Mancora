// Runs ImageJ's own interpolation and geometric operations over the test
// images of FilterFixtures.java, so Mancora's GeometryProcessor tests compare
// against ImageJ itself without needing Java at test time.
//
//   java -Djava.awt.headless=true -cp ij.jar GeometryFixtures.java <repo-root>
//
// Writes Tests/Fixtures/process/geometry.json:
//   "inputs": SHA-256 of every input image (hashed as in filters.json);
//   "cases":  one entry per operation on a fresh input: the operation, its
//             parameters, the output size, the SHA-256 of its pixels, its
//             display range (getMin/getMax, for 8-, 16- and 32-bit) and a few
//             sample pixels;
//   "points": interpolation at chosen coordinates: getInterpolatedPixel,
//             getBicubicInterpolatedPixel, getPixelInterpolated (float
//             bits for 32-bit) and getInterpolatedValue, as Double.toString.
//
// The processors are set up as ImageJ's commands set them up: interpolation
// method, rectangle ROI, background value, an inverted LUT (8-bit) or the
// signed 16-bit calibration table where a case says so. Inputs with a
// display range get setMinAndMax first.
//
// The input formulas must match Tests/MancoraProcessTests/FilterInputs.swift.
//
// Not recorded, because ImageJ fails: bilinear and bicubic rotation, scaling
// and translation of images one pixel wide (ArrayIndexOutOfBoundsException
// in the private getInterpolatedPixel).

import ij.IJ;
import ij.process.*;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

public class GeometryFixtures {

    // MARK: Inputs (as in FilterFixtures.java)

    static int hash(int x, int y, int seed) {
        int h = x * 0x27d4eb2d + y * 0x165667b1 + seed * 0x9e3779b9;
        h ^= h >>> 15;
        h *= 0x85ebca6b;
        h ^= h >>> 13;
        return h & 0x7fffffff;
    }

    static boolean disc(int x, int y, int w, int h) {
        int dx = x - w / 2, dy = y - h / 2, r = h / 4;
        return dx * dx + dy * dy <= r * r;
    }

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

    static float gray32(int x, int y, int w, int h) {
        if (y < h / 6) return 12.5f;
        if (x >= w - w / 6) return ((x + y) & 1) == 0 ? -2.5e4f : 1.0e5f;
        if (disc(x, y, w, h)) return -7.25f;
        return (float) (hash(x, y, 3) & 0xffff) / 256f - 100f + x * 0.37f;
    }

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

    static ImageProcessor make(String pattern, int w, int h) {
        ImageProcessor ip;
        switch (pattern) {
            case "gray8": ip = new ByteProcessor(w, h); break;
            case "gray16": ip = new ShortProcessor(w, h); break;
            case "float": case "floatSpecial": ip = new FloatProcessor(w, h); break;
            case "rgb": ip = new ColorProcessor(w, h); break;
            default: throw new IllegalArgumentException(pattern);
        }
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                switch (pattern) {
                    case "gray8": ip.set(x, y, gray8(x, y, w, h)); break;
                    case "gray16": ip.set(x, y, gray16(x, y, w, h)); break;
                    case "float": ip.setf(x, y, gray32(x, y, w, h)); break;
                    case "floatSpecial": ip.setf(x, y, floatSpecial(x, y, w, h)); break;
                    case "rgb": ip.set(x, y, rgb(x, y, w, h) | 0xff000000); break;
                }
            }
        if (ip instanceof ShortProcessor || ip instanceof FloatProcessor) ip.resetMinAndMax();
        return ip;
    }

    // MARK: Hashing and JSON (as in FilterFixtures.java)

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
                int bits = Float.floatToIntBits(f[i]);
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

    static final String[] METHODS = {"none", "bilinear", "bicubic"};
    static final List<String> cases = new ArrayList<>();
    static final List<String> points = new ArrayList<>();
    static final Map<String, String> inputs = new LinkedHashMap<>();

    /** The case's setup: method, ROI, background, display range, LUT and calibration. */
    static class Setup {
        int method;
        int[] roi;              // x, y, width, height
        Double background;
        double[] display;       // setMinAndMax
        boolean invertedLUT, signed16;

        Setup(int method) { this.method = method; }
        Setup roi(int x, int y, int w, int h) { roi = new int[] {x, y, w, h}; return this; }
        Setup background(double v) { background = v; return this; }
        Setup display(double lo, double hi) { display = new double[] {lo, hi}; return this; }
        Setup inverted() { invertedLUT = true; return this; }
        Setup signed() { signed16 = true; return this; }

        void apply(ImageProcessor ip) {
            if (display != null) ip.setMinAndMax(display[0], display[1]);
            if (invertedLUT) ip.invertLut();
            if (signed16) {
                float[] table = new float[65536];
                for (int i = 0; i < 65536; i++) table[i] = i - 32768;
                ip.setCalibrationTable(table);
            }
            ip.setInterpolationMethod(method);
            if (roi != null) ip.setRoi(roi[0], roi[1], roi[2], roi[3]);
            if (background != null) ip.setBackgroundValue(background);
        }

        String json() {
            StringBuilder s = new StringBuilder("\"method\": \"" + METHODS[method] + "\"");
            if (roi != null) s.append(", \"roi\": [" + roi[0] + ", " + roi[1] + ", " + roi[2] + ", " + roi[3] + "]");
            if (background != null) s.append(", \"background\": " + num(background));
            if (display != null) s.append(", \"display\": [" + num(display[0]) + ", " + num(display[1]) + "]");
            if (invertedLUT) s.append(", \"invertedLUT\": true");
            if (signed16) s.append(", \"signed16\": true");
            return s.toString();
        }
    }

    interface Op { ImageProcessor run(ImageProcessor ip); }

    static void record(String op, String pattern, int w, int h, Setup setup, String params, Op operation) throws Exception {
        String inputName = pattern + "-" + w + "x" + h;
        if (!inputs.containsKey(inputName)) inputs.put(inputName, sha256(make(pattern, w, h)));
        ImageProcessor ip = make(pattern, w, h);
        setup.apply(ip);
        ImageProcessor out = operation.run(ip);
        int n = out.getWidth() * out.getHeight();
        int[] at = {0, out.getWidth() - 1, n / 2, n - out.getWidth(), n - 1, hash(w, h, cases.size()) % n};
        StringBuilder s = new StringBuilder();
        for (int i = 0; i < at.length; i++) {
            if (i > 0) s.append(", ");
            s.append('"').append(at[i]).append("\": \"").append(sample(out, at[i])).append('"');
        }
        String range = out instanceof ColorProcessor ? "" : ", \"min\": \"" + Double.toString(out.getMin()) + "\", \"max\": \"" + Double.toString(out.getMax()) + "\"";
        cases.add("    {\"op\": \"" + op + "\", \"input\": \"" + inputName + "\", \"params\": {" + setup.json()
            + (params.isEmpty() ? "" : ", " + params) + "}, \"width\": " + out.getWidth() + ", \"height\": " + out.getHeight()
            + ", \"sha256\": \"" + sha256(out) + "\"" + range + ", \"samples\": {" + s + "}}");
    }

    static String d(double v) { return "\"" + Double.toString(v) + "\""; }

    /** Interpolated values at (x, y) with each method. */
    static void recordPoints(String pattern, int w, int h, double background, double[][] at) throws Exception {
        String inputName = pattern + "-" + w + "x" + h;
        if (!inputs.containsKey(inputName)) inputs.put(inputName, sha256(make(pattern, w, h)));
        for (int m = 0; m < 3; m++) {
            ImageProcessor ip = make(pattern, w, h);
            ip.setInterpolationMethod(m);
            ip.setBackgroundValue(background);
            for (double[] p : at) {
                double x = p[0], y = p[1];
                // The private bilinear kernel reads past the array for gray images a pixel wide.
                boolean overrun = (w == 1 || h == 1) && !(ip instanceof ColorProcessor);
                String interpolated = overrun ? "null" : d(ip.getInterpolatedPixel(x, y));
                String bicubic = overrun ? "null" : d(ip.getBicubicInterpolatedPixel(x, y, ip));
                String pixel = overrun && m == 2 ? "null" : Integer.toString(ip.getPixelInterpolated(x, y));
                String value = d(ip.getInterpolatedValue(x, y));
                String rgbValue = ip instanceof ColorProcessor ? Integer.toString(((ColorProcessor) ip).getInterpolatedRGBPixel(x, y)) : "null";
                points.add("    {\"input\": \"" + inputName + "\", \"method\": \"" + METHODS[m] + "\", \"background\": " + num(background)
                    + ", \"x\": " + d(x) + ", \"y\": " + d(y) + ", \"interpolatedPixel\": " + interpolated
                    + ", \"bicubic\": " + bicubic + ", \"pixelInterpolated\": " + pixel
                    + ", \"interpolatedValue\": " + value + ", \"interpolatedRGBPixel\": " + rgbValue + "}");
            }
        }
    }

    // MARK: Cases

    static final String[] TYPES = {"gray8", "gray16", "float", "floatSpecial", "rgb"};
    static final int W = 37, H = 23;

    public static void main(String[] args) throws Exception {
        Locale.setDefault(Locale.ROOT);
        resize();
        scale();
        rotate();
        translate();
        points();
        File out = new File(args[0], "Tests/Fixtures/process/geometry.json");
        out.getParentFile().mkdirs();
        StringBuilder sb = new StringBuilder();
        sb.append("{\n  \"imagej\": \"").append(IJ.getVersion()).append("\",\n  \"inputs\": {\n");
        int k = 0;
        for (Map.Entry<String, String> e : inputs.entrySet())
            sb.append("    \"").append(e.getKey()).append("\": \"").append(e.getValue()).append('"')
              .append(++k < inputs.size() ? ",\n" : "\n");
        sb.append("  },\n  \"cases\": [\n").append(String.join(",\n", cases)).append("\n  ],\n");
        sb.append("  \"points\": [\n").append(String.join(",\n", points)).append("\n  ]\n}\n");
        Files.write(out.toPath(), sb.toString().getBytes(StandardCharsets.UTF_8));
        System.out.println("ImageJ " + IJ.getVersion() + ": " + cases.size() + " geometry cases and " + points.size() + " points written");
        System.exit(0);
    }

    static void resize() throws Exception {
        int[][] sizes = {{50, 31}, {18, 11}, {37, 40}, {9, 30}, {74, 46}};
        for (String t : TYPES)
            for (int m = 0; m < 3; m++)
                for (int[] s : sizes)
                    for (boolean avg : new boolean[] {false, true}) {
                        int dw = s[0], dh = s[1];
                        record("resize", t, W, H, new Setup(m), "\"width\": " + dw + ", \"height\": " + dh + ", \"averaging\": " + avg,
                            ip -> ip.resize(dw, dh, avg));
                    }
        for (String t : new String[] {"gray8", "gray16", "float", "rgb"})
            for (int m = 0; m < 3; m++) {
                record("resize", t, W, H, new Setup(m).roi(5, 3, 20, 13), "\"width\": 33, \"height\": 9, \"averaging\": true",
                    ip -> ip.resize(33, 9, true));
                record("resize", t, W, H, new Setup(m).roi(30, 15, 12, 12), "\"width\": 20, \"height\": 30, \"averaging\": false",
                    ip -> ip.resize(20, 30, false));
                record("resize", t, W, H, new Setup(m).roi(0, 0, 37, 23), "\"width\": 37, \"height\": 23, \"averaging\": true",
                    ip -> ip.resize(37, 23, true));
            }
        // Display ranges carried to the new processor.
        record("resize", "gray16", W, H, new Setup(1).display(2000, 30000), "\"width\": 20, \"height\": 12, \"averaging\": true",
            ip -> ip.resize(20, 12, true));
        record("resize", "float", W, H, new Setup(2).display(-50.25, 70.5), "\"width\": 60, \"height\": 30, \"averaging\": false",
            ip -> ip.resize(60, 30, false));
        record("resize", "gray8", W, H, new Setup(1).display(30, 200), "\"width\": 20, \"height\": 30, \"averaging\": true",
            ip -> ip.resize(20, 30, true));
        // Images a pixel wide or high (resizeLinearly), and resizing to one pixel.
        int[][] thin = {{1, 9}, {9, 1}, {1, 1}};
        int[][] targets = {{1, 20}, {3, 18}, {20, 1}, {14, 5}, {2, 1}};
        for (String t : new String[] {"gray8", "gray16", "float", "rgb"})
            for (int[] size : thin)
                for (int m = 0; m < 3; m++)
                    for (int[] s : targets) {
                        if (size[0] == 1 && size[1] == 1 && (s[0] == 1 || s[1] == 1)) continue;  // 0/0 scale
                        if ((size[0] == 1 && s[1] == 1) || (size[1] == 1 && s[0] == 1)) continue;  // likewise
                        for (boolean avg : new boolean[] {false, true}) {
                            int dw = s[0], dh = s[1];
                            record("resize", t, size[0], size[1], new Setup(m), "\"width\": " + dw + ", \"height\": " + dh + ", \"averaging\": " + avg,
                                ip -> ip.resize(dw, dh, avg));
                        }
                    }
        for (int m = 0; m < 3; m++)
            for (boolean avg : new boolean[] {false, true}) {
                boolean a = avg;
                record("resize", "gray16", W, H, new Setup(m), "\"width\": 1, \"height\": 7, \"averaging\": " + a, ip -> ip.resize(1, 7, a));
                record("resize", "float", W, H, new Setup(m), "\"width\": 30, \"height\": 1, \"averaging\": " + a, ip -> ip.resize(30, 1, a));
            }
    }

    static void scale() throws Exception {
        double[][] factors = {{0.5, 0.5}, {0.37, 0.8}, {1.6, 1.3}, {2, 0.7}, {3.1, 2.2}};
        for (String t : TYPES)
            for (int m = 0; m < 3; m++)
                for (double[] f : factors) {
                    double fx = f[0], fy = f[1];
                    Op op = ip -> { ip.scale(fx, fy); return ip; };
                    String params = "\"x\": " + num(fx) + ", \"y\": " + num(fy);
                    record("scale", t, W, H, new Setup(m).background(0), params, op);
                    if (fx < 1 || fy < 1) {
                        double bg = t.equals("rgb") ? 0xff3366cc : t.equals("gray16") ? 5000 : t.startsWith("float") ? -3.5 : 77;
                        record("scale", t, W, H, new Setup(m).background(bg), params, op);
                    }
                    record("scale", t, W, H, new Setup(m).background(0).roi(6, 4, 21, 14), params, op);
                }
        // The display minimum fills 16- and 32-bit; an inverted LUT turns 8-bit's default white to black.
        for (int m = 0; m < 3; m++) {
            Op op = ip -> { ip.scale(0.6, 0.6); return ip; };
            String params = "\"x\": 0.6, \"y\": 0.6";
            record("scale", "gray16", W, H, new Setup(m).display(3000, 40000), params, op);
            record("scale", "float", W, H, new Setup(m).display(-20, 90), params, op);
            record("scale", "gray8", W, H, new Setup(m), params, op);
            record("scale", "gray8", W, H, new Setup(m).inverted(), params, op);
            record("scale", "rgb", W, H, new Setup(m), params, op);
        }
        record("scale", "gray8", 1, 9, new Setup(0).background(0), "\"x\": 0.5, \"y\": 0.5", ip -> { ip.scale(0.5, 0.5); return ip; });
        record("scale", "gray16", 9, 1, new Setup(0).background(0), "\"x\": 2, \"y\": 2", ip -> { ip.scale(2, 2); return ip; });
    }

    static void rotate() throws Exception {
        double[] angles = {15, -37.5, 90, 360, 123.4};
        for (String t : TYPES)
            for (int m = 0; m < 3; m++)
                for (double a : angles) {
                    Op op = ip -> { ip.rotate(a); return ip; };
                    String params = "\"angle\": " + num(a);
                    record("rotate", t, W, H, new Setup(m).background(0), params, op);
                    if (a == 15 || a == 123.4) {
                        double bg = t.equals("rgb") ? 0xff3366cc : t.equals("gray16") ? 5000 : t.startsWith("float") ? -3.5 : 77;
                        record("rotate", t, W, H, new Setup(m).background(bg), params, op);
                        record("rotate", t, W, H, new Setup(m).background(bg).roi(4, 2, 25, 17), params, op);
                    }
                }
        for (int m = 0; m < 3; m++) {
            Op op = ip -> { ip.rotate(20); return ip; };
            record("rotate", "gray8", W, H, new Setup(m), "\"angle\": 20", op);
            record("rotate", "gray8", W, H, new Setup(m).inverted(), "\"angle\": 20", op);
            record("rotate", "rgb", W, H, new Setup(m), "\"angle\": 20", op);
            record("rotate", "gray16", W, H, new Setup(m).background(100).signed(), "\"angle\": 20", op);
            record("rotate", "float", W, H, new Setup(m).background(2.5).display(-5, 5), "\"angle\": 20", op);
        }
        record("rotate", "gray8", 1, 9, new Setup(0).background(0), "\"angle\": 30", ip -> { ip.rotate(30); return ip; });
        record("rotate", "rgb", 9, 1, new Setup(0).background(0), "\"angle\": 30", ip -> { ip.rotate(30); return ip; });
    }

    static void translate() throws Exception {
        double[][] offsets = {{3, -2}, {2.5, 1.25}, {-3.7, 4.2}, {-40, 0}, {0, -0.5}};
        for (String t : TYPES)
            for (int m = 0; m < 3; m++)
                for (double[] o : offsets) {
                    double dx = o[0], dy = o[1];
                    Op op = ip -> { ip.translate(dx, dy); return ip; };
                    String params = "\"x\": " + num(dx) + ", \"y\": " + num(dy);
                    record("translate", t, W, H, new Setup(m), params, op);
                    if (dx == 2.5) record("translate", t, W, H, new Setup(m).roi(5, 5, 20, 10), params, op);
                }
        record("translate", "gray8", 1, 9, new Setup(0), "\"x\": 0, \"y\": 2", ip -> { ip.translate(0, 2); return ip; });
        record("translate", "rgb", 9, 1, new Setup(1), "\"x\": 1.5, \"y\": 0", ip -> { ip.translate(1.5, 0); return ip; });
    }

    static void points() throws Exception {
        double[][] at = {{3.25, 4.75}, {10.5, 7.5}, {0.1, 0.2}, {-0.3, 5}, {-0.9, -0.9}, {-1.5, 3}, {35.6, 21.5},
            {36, 22}, {37.2, 5}, {12.999, 0.001}, {34.5, 1.5}};
        for (String t : TYPES) {
            recordPoints(t, W, H, 0, at);
            recordPoints(t, W, H, t.equals("rgb") ? 0xff3366cc : 50, at);
        }
        double[][] thinAt = {{0, 3}, {0.4, 2.5}, {-0.6, 4}, {0, 8.5}, {2.25, 0}};
        for (String t : new String[] {"gray8", "float", "rgb"})
            recordPoints(t, 1, 9, 0, thinAt);
    }
}
