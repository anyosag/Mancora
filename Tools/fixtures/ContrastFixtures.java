// Generates golden display ranges for Mancora's automatic contrast with real
// ImageJ 1.x, so the tests compare against ImageJ itself.
//
//   java -Djava.awt.headless=true -cp ij.jar ContrastFixtures.java <repo-root>
//
// Writes Tests/Fixtures/contrast-golden.json. For every test image it records:
//   - the statistics ContrastEnhancer works from: ImageStatistics.getStatistics
//     for each plane, and StackStatistics for stacks
//   - the display range Process>Enhance Contrast (saturated=0.35) sets for each
//     plane, and with "Use stack histogram", or null when ImageJ leaves the
//     range unchanged
//   - the display range and press counter after presses 1-12 of the B&C
//     dialog's Auto button
//
// The pixel generators must match Tests/MancoraCoreTests/ContrastGolden.swift.
// Each case records an FNV-1a hash of its pixels, so a mismatch shows up there.
//
// Enhance Contrast runs through ContrastEnhancer's public API. The B&C dialog
// (ContrastAdjuster) is an AWT window that can't be constructed headless, so
// its Auto logic (ContrastAdjuster.autoAdjust, lines 815-864 of 1.54p, and the
// reset it falls back to, lines 588-605) is replicated in autoPress below,
// around ImageJ's own statistics and display-range calls. Run with a display,
// for example
//
//   xvfb-run java -cp ij.jar Tools/fixtures/ContrastFixtures.java <repo-root>
//
// and the program also drives the real dialog's autoAdjust through reflection
// and fails if any press differs from the replica. The JSON is the same in
// both modes.

import ij.IJ;
import ij.ImagePlus;
import ij.ImageStack;
import ij.plugin.ContrastEnhancer;
import ij.plugin.frame.ContrastAdjuster;
import ij.process.*;
import java.awt.GraphicsEnvironment;
import java.awt.Scrollbar;
import java.io.File;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public class ContrastFixtures {
    static final int PRESSES = 12;
    static final double SATURATED = 0.35;

    /** A test image: pixel type, size, plane count and generator parameters. */
    static final class Case {
        final String name, type, kind;
        final int width, height, planes;
        final Map<String, Double> p = new LinkedHashMap<>();

        Case(String name, String type, int width, int height, int planes, String kind, Object... params) {
            this.name = name;
            this.type = type;
            this.width = width;
            this.height = height;
            this.planes = planes;
            this.kind = kind;
            for (int i = 0; i < params.length; i += 2)
                p.put((String) params[i], ((Number) params[i + 1]).doubleValue());
        }

        long l(String key, long fallback) { return p.containsKey(key) ? p.get(key).longValue() : fallback; }
        float f(String key, float fallback) { return p.containsKey(key) ? p.get(key).floatValue() : fallback; }
    }

    static List<Case> cases() {
        List<Case> c = new ArrayList<>();
        int W = 128, H = 96;
        // 8-bit
        c.add(new Case("g8-ramp", "gray8", W, H, 1, "linear", "dx", 2));
        c.add(new Case("g8-ramp-clipped", "gray8", W, H, 1, "linear", "dx", 2, "dy", 1));
        c.add(new Case("g8-noise", "gray8", W, H, 1, "noise", "seed", 11, "center", 100, "sigma", 20));
        c.add(new Case("g8-noise-clipped", "gray8", W, H, 1, "noise", "seed", 12, "center", 128, "sigma", 90));
        c.add(new Case("g8-dim", "gray8", W, H, 1, "noise", "seed", 13, "center", 3, "sigma", 2));
        c.add(new Case("g8-skewed", "gray8", W, H, 1, "skewed", "seed", 14, "n", 256, "div", 255));
        c.add(new Case("g8-spots", "gray8", W, H, 1, "spots", "seed", 15, "center", 8, "sigma", 3,
            "perMille", 15, "spot", 190, "spotSigma", 25));
        c.add(new Case("g8-two-values", "gray8", W, H, 1, "twoValues", "a", 10, "b", 50, "period", 20));
        c.add(new Case("g8-constant", "gray8", W, H, 1, "constant", "value", 77));
        c.add(new Case("g8-small", "gray8", 7, 5, 1, "noise", "seed", 16, "center", 60, "sigma", 30));
        // 16-bit
        c.add(new Case("g16-ramp", "gray16", W, H, 1, "linear", "dx", 5, "dy", 640));
        c.add(new Case("g16-noise", "gray16", W, H, 1, "noise", "seed", 21, "center", 1000, "sigma", 150));
        c.add(new Case("g16-narrow", "gray16", W, H, 1, "noise", "seed", 22, "center", 30020, "sigma", 8));
        c.add(new Case("g16-12bit", "gray16", W, H, 1, "noise", "seed", 23, "center", 2000, "sigma", 900,
            "hi", 4095));
        c.add(new Case("g16-skewed", "gray16", W, H, 1, "skewed", "seed", 24, "n", 4096, "div", 256));
        c.add(new Case("g16-hot-pixels", "gray16", W, H, 1, "spots", "seed", 25, "center", 100, "sigma", 10,
            "perMille", 2, "spot", 60000, "spotSigma", 2000));
        c.add(new Case("g16-two-values", "gray16", W, H, 1, "twoValues", "a", 300, "b", 9000, "period", 20));
        c.add(new Case("g16-constant", "gray16", W, H, 1, "constant", "value", 4321));
        c.add(new Case("g16-zero", "gray16", W, H, 1, "constant", "value", 0));
        c.add(new Case("g16-small", "gray16", 9, 7, 1, "noise", "seed", 26, "center", 500, "sigma", 200));
        // 32-bit
        c.add(new Case("f32-ramp", "gray32Float", W, H, 1, "flinear", "divx", 7, "divy", 3));
        c.add(new Case("f32-noise", "gray32Float", W, H, 1, "fnoise", "seed", 31, "scale", 1.5, "offset", 0.25));
        c.add(new Case("f32-nan-inf", "gray32Float", W, H, 1, "fnoise", "seed", 32, "scale", 100, "offset", -20,
            "nanPeriod", 97, "posInfPeriod", 101, "posInfPhase", 3, "negInfPeriod", 103, "negInfPhase", 5));
        c.add(new Case("f32-many-inf", "gray32Float", W, H, 1, "fnoise", "seed", 33, "scale", 4, "offset", 0,
            "posInfPeriod", 7));
        c.add(new Case("f32-non-finite", "gray32Float", W, H, 1, "fconstant", "value", 1,
            "nanPeriod", 1, "posInfPeriod", 3, "negInfPeriod", 3, "negInfPhase", 1));
        c.add(new Case("f32-all-nan", "gray32Float", W, H, 1, "fconstant", "value", 0, "nanPeriod", 1));
        c.add(new Case("f32-constant", "gray32Float", W, H, 1, "fconstant", "value", 2.5));
        c.add(new Case("f32-zero", "gray32Float", W, H, 1, "fconstant", "value", 0));
        c.add(new Case("f32-skewed", "gray32Float", W, H, 1, "fskewed", "seed", 34, "n", 1000, "div", 7));
        c.add(new Case("f32-tiny", "gray32Float", W, H, 1, "fnoise", "seed", 35,
            "scale", Math.scalb(1.0, -20), "offset", -Math.scalb(1.0, -10)));
        c.add(new Case("f32-huge", "gray32Float", W, H, 1, "fnoise", "seed", 36, "scale", Math.scalb(1.0, 100),
            "offset", 0));
        c.add(new Case("f32-two-values", "gray32Float", W, H, 1, "ftwoValues", "a", -1.25, "b", 3.5, "period", 20));
        c.add(new Case("f32-small", "gray32Float", 6, 4, 1, "fnoise", "seed", 37, "scale", 10, "offset", 1));
        // Stacks
        int SW = 64, SH = 48;
        c.add(new Case("s8-stack", "gray8", SW, SH, 5, "noise", "seed", 41, "center", 40, "sigma", 15, "dk", 30));
        c.add(new Case("s8-constant-planes", "gray8", SW, SH, 3, "constant", "value", 50, "dk", 10));
        c.add(new Case("s16-stack", "gray16", SW, SH, 4, "noise", "seed", 42, "center", 500, "sigma", 100,
            "dk", 700));
        c.add(new Case("s16-narrow-stack", "gray16", SW, SH, 3, "noise", "seed", 43, "center", 1000, "sigma", 5,
            "dk", 3));
        c.add(new Case("s32-stack", "gray32Float", SW, SH, 3, "fnoise", "seed", 44, "scale", 1, "offset", 0,
            "dk", 4, "nanPeriod", 50));
        c.add(new Case("s32-inf-stack", "gray32Float", SW, SH, 2, "fnoise", "seed", 45, "scale", 8, "offset", 100,
            "dk", -50, "posInfPeriod", 211, "negInfPeriod", 307, "negInfPhase", 1));
        return c;
    }

    // MARK: Pixel generators (mirrored in ContrastGolden.swift)

    /** SplitMix64 (Steele, Lea and Flood), with Java's wrapping long arithmetic. */
    static final class SplitMix64 {
        long state;

        SplitMix64(long seed) { state = seed; }

        long next() {
            long z = (state += 0x9E3779B97F4A7C15L);
            z = (z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9L;
            z = (z ^ (z >>> 27)) * 0x94D049BB133111EBL;
            return z ^ (z >>> 31);
        }

        /** Uniform in [0, n). */
        long below(long n) { return (next() >>> 33) % n; }

        /** Roughly normal, mean 0 and standard deviation about 37837: four 16-bit uniforms summed. */
        long gauss() { return below(65536) + below(65536) + below(65536) + below(65536) - 131070; }
    }

    static ImageStack makeStack(Case c) {
        SplitMix64 rng = new SplitMix64(c.l("seed", 0));
        ImageStack stack = new ImageStack(c.width, c.height);
        for (int k = 0; k < c.planes; k++) {
            int n = c.width * c.height;
            ImageProcessor ip;
            switch (c.type) {
                case "gray8": {
                    byte[] px = new byte[n];
                    for (int i = 0; i < n; i++) px[i] = (byte) clamp(c, intValue(c, rng, i % c.width, i / c.width, k), 255);
                    ip = new ByteProcessor(c.width, c.height, px);
                    break;
                }
                case "gray16": {
                    short[] px = new short[n];
                    for (int i = 0; i < n; i++) px[i] = (short) clamp(c, intValue(c, rng, i % c.width, i / c.width, k), 65535);
                    ip = new ShortProcessor(c.width, c.height, px, null);
                    break;
                }
                default: {
                    float[] px = new float[n];
                    for (int i = 0; i < n; i++) px[i] = floatValue(c, rng, i % c.width, i / c.width, k);
                    ip = new FloatProcessor(c.width, c.height, px);
                }
            }
            stack.addSlice("plane " + (k + 1), ip);
        }
        return stack;
    }

    static long clamp(Case c, long v, long typeMax) {
        return Math.max(c.l("lo", 0), Math.min(c.l("hi", typeMax), v));
    }

    static long intValue(Case c, SplitMix64 rng, int x, int y, int k) {
        long dk = c.l("dk", 0);
        switch (c.kind) {
            case "linear":
                return c.l("offset", 0) + x * c.l("dx", 0) + y * c.l("dy", 0) + k * dk;
            case "noise":
                return c.l("center", 0) + k * dk + rng.gauss() * c.l("sigma", 0) / 37837;
            case "skewed": {
                long u = rng.below(c.l("n", 1));
                return c.l("offset", 0) + u * u / c.l("div", 1);
            }
            case "constant":
                return c.l("value", 0) + k * dk;
            case "twoValues":
                return (y * c.width + x) % c.l("period", 1) == 0 ? c.l("b", 0) : c.l("a", 0);
            case "spots":
                if (rng.below(1000) < c.l("perMille", 0))
                    return c.l("spot", 0) + rng.gauss() * c.l("spotSigma", 0) / 37837;
                return c.l("center", 0) + rng.gauss() * c.l("sigma", 0) / 37837;
            default:
                throw new IllegalArgumentException(c.kind);
        }
    }

    static float floatValue(Case c, SplitMix64 rng, int x, int y, int k) {
        float v;
        float dk = c.f("dk", 0f);
        switch (c.kind) {
            case "flinear":
                v = (float) x / c.f("divx", 1f) - (float) y / c.f("divy", 1f) + (float) k * dk;
                break;
            case "fnoise":
                v = (float) rng.gauss() / 37837f * c.f("scale", 1f) + c.f("offset", 0f) + (float) k * dk;
                break;
            case "fskewed": {
                long u = rng.below(c.l("n", 1));
                v = (float) (u * u) / c.f("div", 1f);
                break;
            }
            case "fconstant":
                v = c.f("value", 0f) + (float) k * dk;
                break;
            case "ftwoValues":
                v = (y * c.width + x) % c.l("period", 1) == 0 ? c.f("b", 0f) : c.f("a", 0f);
                break;
            default:
                throw new IllegalArgumentException(c.kind);
        }
        long i = (long) y * c.width + x;
        if (hits(c, "nan", i)) v = Float.NaN;
        if (hits(c, "posInf", i)) v = Float.POSITIVE_INFINITY;
        if (hits(c, "negInf", i)) v = Float.NEGATIVE_INFINITY;
        return v;
    }

    static boolean hits(Case c, String special, long i) {
        long period = c.l(special + "Period", 0);
        return period > 0 && i % period == c.l(special + "Phase", 0);
    }

    // MARK: Hashes (FNV-1a, 64-bit)

    static final long FNV_OFFSET = 0xcbf29ce484222325L, FNV_PRIME = 0x100000001b3L;

    static long fnv(long h, long value, int bytes) {
        for (int b = 0; b < bytes; b++) {
            h ^= (value >>> (8 * b)) & 0xff;
            h *= FNV_PRIME;
        }
        return h;
    }

    /** Raw pixel bytes, little-endian, plane after plane. */
    static String pixelHash(ImageStack stack) {
        long h = FNV_OFFSET;
        for (int k = 1; k <= stack.size(); k++) {
            Object px = stack.getPixels(k);
            if (px instanceof byte[])
                for (byte v : (byte[]) px) h = fnv(h, v, 1);
            else if (px instanceof short[])
                for (short v : (short[]) px) h = fnv(h, v, 2);
            else
                for (float v : (float[]) px) h = fnv(h, Float.floatToRawIntBits(v), 4);
        }
        return String.format("%016x", h);
    }

    /** All 65536 bin counts as 32-bit little-endian values; shorter arrays are padded with zeros. */
    static String histogram16Hash(int[] hist) {
        long h = FNV_OFFSET;
        for (int i = 0; i < 65536; i++) h = fnv(h, i < hist.length ? hist[i] : 0, 4);
        return String.format("%016x", h);
    }

    // MARK: Enhance Contrast

    /** Display range set by Enhance Contrast on the current plane of imp, or null if it is left unchanged. */
    static double[] enhance(ImagePlus imp, boolean stackHistogram) {
        double[] a = enhanceFrom(imp, stackHistogram, 1, 2);
        double[] b = enhanceFrom(imp, stackHistogram, 3, 4);
        if (a[0] == 1 && a[1] == 2 && b[0] == 3 && b[1] == 4)
            return null;
        if (!Arrays.equals(a, b))
            throw new IllegalStateException("Enhance Contrast depends on the previous range: " + imp.getTitle());
        return a;
    }

    static double[] enhanceFrom(ImagePlus imp, boolean stackHistogram, double min, double max) {
        imp.setDisplayRange(min, max);
        ContrastEnhancer ce = new ContrastEnhancer();
        ce.setUseStackHistogram(stackHistogram);
        ce.stretchHistogram(imp, SATURATED);
        return new double[] {imp.getDisplayRangeMin(), imp.getDisplayRangeMax()};
    }

    // MARK: B&C Auto

    static final int AUTO_THRESHOLD = 5000;

    /** ContrastAdjuster's per-image Auto state: the autoThreshold field. */
    static final class AutoState {
        int autoThreshold;
    }

    /**
     * One press of the B&C dialog's Auto button on a non-RGB image without a
     * selection: ContrastAdjuster.autoAdjust (1.54p lines 815-864) and, when
     * no range is found, ContrastAdjuster.reset (lines 588-605).
     */
    static void autoPress(ImagePlus imp, AutoState state) {
        ImageStatistics stats = imp.getRawStatistics();
        int limit = stats.pixelCount / 10;
        int[] histogram = stats.histogram;
        if (state.autoThreshold < 10)
            state.autoThreshold = AUTO_THRESHOLD;
        else
            state.autoThreshold /= 2;
        int threshold = stats.pixelCount / state.autoThreshold;
        int i = -1;
        boolean found = false;
        int count;
        do {
            i++;
            count = histogram[i];
            if (count > limit) count = 0;
            found = count > threshold;
        } while (!found && i < 255);
        int hmin = i;
        i = 256;
        do {
            i--;
            count = histogram[i];
            if (count > limit) count = 0;
            found = count > threshold;
        } while (!found && i > 0);
        int hmax = i;
        if (hmax >= hmin) {
            double min = stats.histMin + hmin * stats.binSize;
            double max = stats.histMin + hmax * stats.binSize;
            if (min == max) {
                min = stats.min;
                max = stats.max;
            }
            imp.setDisplayRange(min, max);
        } else {
            // reset(imp, ip): 16- and 32-bit images go back to ImagePlus.resetDisplayRange;
            // 8-bit images to defaultMin/defaultMax, which setupNewImage sets to 0 and 255.
            int bitDepth = imp.getBitDepth();
            if (bitDepth == 16 || bitDepth == 32)
                imp.resetDisplayRange();
            else
                imp.setDisplayRange(0, 255);
            state.autoThreshold = 0;
        }
    }

    /** The real ContrastAdjuster, driven through reflection; needs a display. */
    static final class RealDialog {
        final ContrastAdjuster ca = new ContrastAdjuster();
        final Method setup, autoAdjust;
        final Field autoThreshold;

        RealDialog() throws Exception {
            for (String name : new String[] {"contrastSlider", "brightnessSlider", "minSlider", "maxSlider"}) {
                Field f = ContrastAdjuster.class.getDeclaredField(name);
                f.setAccessible(true);
                f.set(ca, new Scrollbar(Scrollbar.HORIZONTAL, 0, 1, 0, 256));
            }
            setup = ContrastAdjuster.class.getDeclaredMethod("setup", ImagePlus.class);
            setup.setAccessible(true);
            autoAdjust = ContrastAdjuster.class.getDeclaredMethod("autoAdjust", ImagePlus.class, ImageProcessor.class);
            autoAdjust.setAccessible(true);
            autoThreshold = ContrastAdjuster.class.getDeclaredField("autoThreshold");
            autoThreshold.setAccessible(true);
        }

        /** Presses Auto PRESSES times on a fresh image; returns {min, max, autoThreshold} per press. */
        double[][] presses(ImageProcessor ip) throws Exception {
            ImagePlus imp = new ImagePlus("dialog", ip);
            setup.invoke(ca, imp);
            double[][] out = new double[PRESSES][];
            for (int p = 0; p < PRESSES; p++) {
                autoAdjust.invoke(ca, imp, imp.getProcessor());
                out[p] = new double[] {imp.getDisplayRangeMin(), imp.getDisplayRangeMax(), autoThreshold.getInt(ca)};
            }
            return out;
        }
    }

    // MARK: Main

    public static void main(String[] args) throws Exception {
        File root = new File(args[0]);
        RealDialog dialog = GraphicsEnvironment.isHeadless() ? null : new RealDialog();
        int dialogChecks = 0;
        StringBuilder sb = new StringBuilder();
        sb.append("{\n  \"imagej\": \"").append(IJ.getVersion()).append("\",\n");
        sb.append("  \"saturated\": ").append(num(SATURATED)).append(",\n");
        sb.append("  \"presses\": ").append(PRESSES).append(",\n");
        sb.append("  \"cases\": [\n");
        List<Case> cases = cases();
        for (int ci = 0; ci < cases.size(); ci++) {
            Case c = cases.get(ci);
            ImageStack stack = makeStack(c);
            sb.append("    {\n");
            sb.append("      \"name\": \"").append(c.name).append("\",\n");
            sb.append("      \"type\": \"").append(c.type).append("\",\n");
            sb.append("      \"width\": ").append(c.width).append(", \"height\": ").append(c.height);
            sb.append(", \"planes\": ").append(c.planes).append(",\n");
            sb.append("      \"generator\": {\"kind\": \"").append(c.kind).append("\", \"parameters\": {");
            String sep = "";
            for (Map.Entry<String, Double> e : c.p.entrySet()) {
                sb.append(sep).append("\"").append(e.getKey()).append("\": ").append(num(e.getValue()));
                sep = ", ";
            }
            sb.append("}},\n");
            sb.append("      \"pixelHash\": \"").append(pixelHash(stack)).append("\",\n");
            sb.append("      \"planeResults\": [\n");
            for (int k = 1; k <= c.planes; k++) {
                ImageProcessor ip = stack.getProcessor(k);
                ImageStatistics stats = ImageStatistics.getStatistics(ip, ImageStatistics.MIN_MAX, null);
                checkRawStatisticsMatch(c, stats, new ImagePlus("raw", ip.duplicate()).getRawStatistics());
                double[] enhanced = enhance(new ImagePlus(c.name, ip.duplicate()), false);

                ImagePlus imp = new ImagePlus(c.name, ip.duplicate());
                AutoState state = new AutoState();
                double[][] presses = new double[PRESSES][];
                for (int p = 0; p < PRESSES; p++) {
                    autoPress(imp, state);
                    presses[p] = new double[] {imp.getDisplayRangeMin(), imp.getDisplayRangeMax(), state.autoThreshold};
                }
                if (dialog != null) {
                    double[][] real = dialog.presses(ip.duplicate());
                    for (int p = 0; p < PRESSES; p++)
                        if (!Arrays.equals(real[p], presses[p]))
                            throw new IllegalStateException(c.name + " plane " + k + " press " + (p + 1)
                                + ": dialog " + Arrays.toString(real[p]) + ", replica " + Arrays.toString(presses[p]));
                    dialogChecks++;
                }

                sb.append("        {\n");
                sb.append("          \"statistics\": ").append(statsJSON(stats)).append(",\n");
                sb.append("          \"enhance\": ").append(rangeJSON(enhanced)).append(",\n");
                sb.append("          \"auto\": [");
                for (int p = 0; p < PRESSES; p++) {
                    sb.append(p == 0 ? "\n" : ",\n");
                    sb.append("            {\"min\": ").append(num(presses[p][0]));
                    sb.append(", \"max\": ").append(num(presses[p][1]));
                    sb.append(", \"autoThreshold\": ").append((int) presses[p][2]).append("}");
                }
                sb.append("\n          ]\n");
                sb.append(k < c.planes ? "        },\n" : "        }\n");
            }
            sb.append("      ]");
            if (c.planes > 1) {
                ImagePlus imp = new ImagePlus(c.name, stack.duplicate());
                ImageStatistics stats = new StackStatistics(imp);
                sb.append(",\n      \"stack\": {\n");
                sb.append("        \"statistics\": ").append(statsJSON(stats)).append(",\n");
                sb.append("        \"enhance\": [");
                for (int k = 1; k <= c.planes; k++) {
                    imp.setSlice(k);
                    sb.append(k == 1 ? "" : ", ").append(rangeJSON(enhance(imp, true)));
                }
                sb.append("]\n      }");
            }
            sb.append(ci < cases.size() - 1 ? "\n    },\n" : "\n    }\n");
        }
        sb.append("  ]\n}\n");
        File out = new File(root, "Tests/Fixtures/contrast-golden.json");
        Files.write(out.toPath(), sb.toString().getBytes(StandardCharsets.UTF_8));
        System.out.println("ImageJ " + IJ.getVersion() + ": " + cases.size() + " contrast cases written to " + out);
        if (dialog != null)
            System.out.println("B&C Auto replica matches ContrastAdjuster.autoAdjust on " + dialogChecks + " planes");
        else
            System.out.println("Headless: B&C Auto replica not cross-checked against the dialog (run under xvfb-run)");
        System.exit(0);
    }

    /** getRawStatistics (used by B&C Auto) must bin exactly like the MIN_MAX statistics (Enhance Contrast). */
    static void checkRawStatisticsMatch(Case c, ImageStatistics a, ImageStatistics b) {
        boolean same = Arrays.equals(a.histogram, b.histogram) && a.histMin == b.histMin && a.histMax == b.histMax
            && a.binSize == b.binSize && a.pixelCount == b.pixelCount
            && Double.compare(a.min, b.min) == 0 && Double.compare(a.max, b.max) == 0;
        if (!same)
            throw new IllegalStateException(c.name + ": getRawStatistics differs from MIN_MAX statistics");
    }

    static String statsJSON(ImageStatistics s) {
        StringBuilder sb = new StringBuilder("{");
        sb.append("\"nBins\": ").append(s.nBins);
        sb.append(", \"histMin\": ").append(num(s.histMin));
        sb.append(", \"histMax\": ").append(num(s.histMax));
        sb.append(", \"binSize\": ").append(num(s.binSize));
        sb.append(", \"pixelCount\": ").append(s.pixelCount);
        sb.append(", \"min\": ").append(num(s.min));
        sb.append(", \"max\": ").append(num(s.max));
        sb.append(", \"mean\": ").append(num(s.mean));
        if (s.histogram16 != null)
            sb.append(", \"histogram16Hash\": \"").append(histogram16Hash(s.histogram16)).append("\"");
        sb.append(", \"histogram\": [");
        for (int i = 0; i < s.histogram.length; i++)
            sb.append(i == 0 ? "" : ",").append(s.histogram[i]);
        return sb.append("]}").toString();
    }

    static String rangeJSON(double[] range) {
        return range == null ? "null" : "{\"min\": " + num(range[0]) + ", \"max\": " + num(range[1]) + "}";
    }

    /**
     * A double as a JSON string in Java's round-trip format ("1.0E-5", "NaN",
     * "-Infinity"), so readers parse it themselves instead of trusting a JSON
     * library's number conversion.
     */
    static String num(double v) {
        return "\"" + v + "\"";
    }
}
