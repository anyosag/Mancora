// Golden data for MancoraProcess, computed by ImageJ 1.x itself: type
// conversions, Z projections, Process > Math, Image Calculator and the
// hyperstack tools (split, merge, substack, reduce, arrange).
//
//   java -Djava.awt.headless=true -cp ij.jar ConvertFixtures.java <repo-root>
//
// Writes Tests/Fixtures/process/{convert,zproject,math,hyperstack}.json.
// Each case names the ImageJ command it ran, describes its input images as
// formulas (see "Inputs" below) and records, for every output image, the
// SHA-256 of its pixels plus its type, dimensions, display ranges, LUTs,
// calibration, slice labels and a few sample pixels.
//
// Inputs. Plane k (0-based, channel fastest, then slice, then frame; plus the
// spec's "offset") of a W x H image holds, at x, y (i = y*W + x):
//   gray8    i==0: 0, i==1: 255, else (x*7 + y*13 + k*29) & 255
//   gray16   i==0: 0, i==1: 65535, i==2: 1, i==3: 32768,
//            else (x*1789 + y*2903 + k*4099 + 17) & 0xffff
//   gray16n  100 + (x*37 + y*101 + k*211) % 3000
//   gray32   (float)((x*37 + y*101 + k*211) % 2000 - 700) * 0.37f
//   gray32s  gray32 except: i==0 NaN, 1 +Inf, 2 -Inf, 3 -0.0, 4 Float.MAX_VALUE,
//            5 -Float.MAX_VALUE, 6 Float.MIN_VALUE, 7 0.5, 8 1.5, 9 2.5,
//            10 -0.5, 11 -1.5, 12 255.5, 13 65535.5, 14 1e10, 15 -1e10,
//            16 254.5, 17 65534.5, 18 256, 19 -256, and i==20+k%10 NaN
//   rgb      i==0: 0x000000, i==1: 0xffffff, else
//            r=(x*8+k*20)&255, g=(y*11+k*7)&255, b=(x*3+y*5+k*13)&255
// Every plane is labelled "p<k>" (k without the offset). Every image has
// pixelWidth 0.5, pixelHeight 0.75, pixelDepth 2, unit "µm", frameInterval 3.
// Multichannel non-RGB images are CompositeImages with the spec's mode, LUTs,
// display ranges and active channels. LUTs are ImageJ's built-in ones by
// name, "<name>-inv" for an inverted one, or "Stripes": r=(i*67)&255,
// g=(i*151)&255, b=(i*37)&255, which ImageJ does not consider a pseudocolor LUT.
//
// Omitted keys take defaults: inputs are 37 x 23, 1 x 1 x 1, offset 0,
// calibration "none"; outputs are 37 x 23 and 1 x 1 x 1, have no value
// function, value unit "Gray Value", pixelWidth 0.5, unit "µm", and labels
// "p0", "p1", ... in stack order.
//
// Pixel hash. SHA-256 over all planes in stack order; per pixel 8-bit: one
// byte; 16-bit: two bytes little-endian; 32-bit: the IEEE bits as four bytes
// little-endian, every NaN written as 0x7fc00000; RGB: three bytes R, G, B
// (alpha ignored). LUT hash: SHA-256 of 256 reds, 256 greens, 256 blues.
//
// Pixel samples are [flat index, value]; the flat index counts pixels across
// planes in stack order; RGB values are 0xRRGGBB.

import ij.*;
import ij.gui.*;
import ij.measure.Calibration;
import ij.plugin.*;
import ij.plugin.filter.ImageMath;
import ij.process.*;
import java.awt.image.IndexColorModel;
import java.io.File;
import java.lang.reflect.Field;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.*;

public class ConvertFixtures {
    static final int W = 37, H = 23;

    public static void main(String[] args) throws Exception {
        File dir = new File(args[0], "Tests/Fixtures/process");
        dir.mkdirs();
        write(new File(dir, "convert.json"), conversions());
        write(new File(dir, "zproject.json"), projections());
        write(new File(dir, "math.json"), math());
        write(new File(dir, "hyperstack.json"), tools());
        System.out.println("ImageJ " + IJ.getVersion() + " process fixtures written");
    }

    // MARK: Input images

    static class Spec {
        String pattern;
        int w = W, h = H, c = 1, z = 1, t = 1, offset = 0;
        double[][] display;
        String[] luts;
        String mode = "color";
        String active;
        String cal = "none";
        double[] function;
        String valueUnit;

        Spec(String pattern) { this.pattern = pattern; }
        Spec dims(int c, int z, int t) { this.c = c; this.z = z; this.t = t; return this; }
        Spec size(int w, int h) { this.w = w; this.h = h; return this; }
        Spec range(double... r) {
            display = new double[r.length / 2][];
            for (int i = 0; i < display.length; i++) display[i] = new double[] {r[2 * i], r[2 * i + 1]};
            return this;
        }
        Spec luts(String... l) { luts = l; return this; }
        Spec mode(String m) { mode = m; return this; }
        Spec active(String a) { active = a; return this; }
        Spec offset(int o) { offset = o; return this; }
        Spec signed() { cal = "signed"; return this; }
        Spec function(double a, double b, String unit) { cal = "function"; function = new double[] {a, b}; valueUnit = unit; return this; }

        boolean rgb() { return pattern.equals("rgb"); }

        String json() {
            Json j = new Json();
            j.str("pattern", pattern);
            if (w != W || h != H) j.num("width", w).num("height", h);
            if (c * z * t > 1) j.num("channels", c).num("slices", z).num("frames", t);
            if (offset != 0) j.num("offset", offset);
            j.raw("display", ranges(display));
            j.raw("luts", strings(luts));
            if (c > 1 && !rgb()) j.str("mode", mode);
            if (active != null) j.str("active", active);
            if (!cal.equals("none")) j.str("calibration", cal);
            if (function != null) j.raw("function", doubles(function)).str("valueUnit", valueUnit);
            return j.end();
        }
    }

    static int bitDepth(String pattern) {
        switch (pattern) {
            case "gray8": return 8;
            case "gray16": case "gray16n": return 16;
            case "gray32": case "gray32s": return 32;
            default: return 24;
        }
    }

    static Object pixels(String pattern, int k, int w, int h) {
        int n = w * h;
        switch (bitDepth(pattern)) {
            case 8: {
                byte[] p = new byte[n];
                for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
                    int i = y * w + x;
                    p[i] = (byte) (i == 0 ? 0 : i == 1 ? 255 : (x * 7 + y * 13 + k * 29) & 255);
                }
                return p;
            }
            case 16: {
                short[] p = new short[n];
                boolean narrow = pattern.equals("gray16n");
                for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
                    int i = y * w + x, v;
                    if (narrow) v = 100 + (x * 37 + y * 101 + k * 211) % 3000;
                    else if (i == 0) v = 0;
                    else if (i == 1) v = 65535;
                    else if (i == 2) v = 1;
                    else if (i == 3) v = 32768;
                    else v = (x * 1789 + y * 2903 + k * 4099 + 17) & 0xffff;
                    p[i] = (short) v;
                }
                return p;
            }
            case 32: {
                float[] p = new float[n];
                boolean special = pattern.equals("gray32s");
                float[] specials = {Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY, -0.0f,
                    Float.MAX_VALUE, -Float.MAX_VALUE, Float.MIN_VALUE, 0.5f, 1.5f, 2.5f, -0.5f, -1.5f,
                    255.5f, 65535.5f, 1e10f, -1e10f, 254.5f, 65534.5f, 256f, -256f};
                for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
                    int i = y * w + x;
                    float v = (float) ((x * 37 + y * 101 + k * 211) % 2000 - 700) * 0.37f;
                    if (special) {
                        if (i < specials.length) v = specials[i];
                        else if (i == 20 + k % 10) v = Float.NaN;
                    }
                    p[i] = v;
                }
                return p;
            }
            default: {
                int[] p = new int[n];
                for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
                    int i = y * w + x;
                    int r = (x * 8 + k * 20) & 255, g = (y * 11 + k * 7) & 255, b = (x * 3 + y * 5 + k * 13) & 255;
                    p[i] = i == 0 ? 0xff000000 : i == 1 ? 0xffffffff : 0xff000000 | r << 16 | g << 8 | b;
                }
                return p;
            }
        }
    }

    static IndexColorModel lutModel(String name) {
        boolean inverted = name.endsWith("-inv");
        String base = inverted ? name.substring(0, name.length() - 4) : name;
        IndexColorModel cm;
        if (base.equals("Stripes")) {
            byte[] r = new byte[256], g = new byte[256], b = new byte[256];
            for (int i = 0; i < 256; i++) { r[i] = (byte) (i * 67); g[i] = (byte) (i * 151); b[i] = (byte) (i * 37); }
            cm = new IndexColorModel(8, 256, r, g, b);
        } else cm = LutLoader.getLut(base);
        LUT lut = new LUT(cm, 0, 0);
        return inverted ? lut.createInvertedLut() : lut;
    }

    static int modeCode(String mode) {
        return mode.equals("composite") ? IJ.COMPOSITE : mode.equals("grayscale") ? IJ.GRAYSCALE : IJ.COLOR;
    }

    /** Builds the image; fills in the spec's LUT names and display ranges when they were left out. */
    static ImagePlus build(Spec s) {
        ImageStack stack = new ImageStack(s.w, s.h);
        int n = s.c * s.z * s.t;
        for (int k = 0; k < n; k++) stack.addSlice("p" + k, pixels(s.pattern, k + s.offset, s.w, s.h));
        ImagePlus imp = new ImagePlus("in", stack);
        imp.setDimensions(s.c, s.z, s.t);
        if (s.luts == null) {
            s.luts = new String[s.c];
            String[] colors = {"Red", "Green", "Blue", "Grays", "Cyan", "Magenta", "Yellow"};
            for (int c = 0; c < s.c; c++) s.luts[c] = s.c == 1 ? "Grays" : colors[c % colors.length];
        }
        boolean composite = s.c > 1 && !s.rgb();
        if (composite) {
            CompositeImage ci = new CompositeImage(imp, modeCode(s.mode));
            for (int c = 0; c < s.c; c++) {
                ci.setPositionWithoutUpdate(c + 1, 1, 1);
                ci.setChannelLut(new LUT(lutModel(s.luts[c]), 0, 0), c + 1);
                if (s.display != null) ci.setDisplayRange(s.display[c][0], s.display[c][1]);
            }
            if (s.active != null) ci.setActiveChannels(s.active);
            ci.setPosition(1, 1, 1);
            imp = ci;
        } else if (!s.rgb()) {
            imp.getProcessor().setColorModel(lutModel(s.luts[0]));
            if (s.display != null) imp.setDisplayRange(s.display[0][0], s.display[0][1]);
        }
        if (s.z > 1 && s.t > 1) imp.setOpenAsHyperStack(true);
        Calibration cal = imp.getCalibration();
        cal.pixelWidth = 0.5;
        cal.pixelHeight = 0.75;
        cal.pixelDepth = 2;
        cal.setUnit("µm");
        cal.frameInterval = 3;
        if (s.cal.equals("signed")) cal.setSigned16BitCalibration();
        if (s.cal.equals("function")) cal.setFunction(Calibration.STRAIGHT_LINE, s.function.clone(), s.valueUnit);
        imp.setCalibration(cal);
        if (s.display == null) s.display = displayRanges(imp);
        return imp;
    }

    static double[][] displayRanges(ImagePlus imp) {
        if (imp.isComposite()) {
            CompositeImage ci = (CompositeImage) imp;
            double[][] r = new double[imp.getNChannels()][];
            for (int c = 0; c < r.length; c++) {
                LUT lut = ci.getChannelLut(c + 1);
                r[c] = new double[] {lut.min, lut.max};
            }
            return r;
        }
        ImageProcessor ip = imp.getProcessor();
        return new double[][] {{ip.getMin(), ip.getMax()}};
    }

    // MARK: Output images

    static String result(ImagePlus imp) throws Exception {
        Json j = new Json();
        int bits = imp.getBitDepth();
        j.str("type", bits == 8 ? "gray8" : bits == 16 ? "gray16" : bits == 32 ? "gray32Float" : "rgb8");
        if (imp.getWidth() != W || imp.getHeight() != H) j.num("width", imp.getWidth()).num("height", imp.getHeight());
        if (imp.getStackSize() > 1) j.num("channels", imp.getNChannels()).num("slices", imp.getNSlices()).num("frames", imp.getNFrames());
        ImageStack stack = imp.getStack();
        j.str("sha256", pixelHash(stack));
        j.raw("display", ranges(displayRanges(imp)));
        if (bits != 24) {
            String[] luts = new String[imp.isComposite() ? imp.getNChannels() : 1];
            for (int c = 0; c < luts.length; c++) {
                IndexColorModel cm = imp.isComposite() ? ((CompositeImage) imp).getChannelLut(c + 1)
                    : (IndexColorModel) imp.getProcessor().getColorModel();
                luts[c] = lutHash(cm).substring(0, 16);
            }
            j.raw("luts", strings(luts));
        }
        if (imp.isComposite()) {
            CompositeImage ci = (CompositeImage) imp;
            j.str("mode", ci.getModeAsString());
            boolean[] active = ci.getActiveChannels();
            StringBuilder sb = new StringBuilder();
            for (int c = 0; c < imp.getNChannels(); c++) sb.append(active[c] ? '1' : '0');
            j.str("active", sb.toString());
        }
        Calibration cal = imp.getCalibration();
        if (cal.getFunction() == Calibration.STRAIGHT_LINE && cal.getCoefficients() != null)
            j.raw("function", doubles(cal.getCoefficients()));
        if (!cal.getValueUnit().equals("Gray Value")) j.str("valueUnit", cal.getValueUnit());
        if (cal.pixelWidth != 0.5 || !cal.getUnit().equals("µm")) j.num("pixelWidth", cal.pixelWidth).str("unit", cal.getUnit());
        String[] labels = new String[stack.getSize()];
        boolean defaultLabels = true;
        for (int i = 0; i < labels.length; i++) {
            labels[i] = stack.getSliceLabel(i + 1);
            defaultLabels &= ("p" + i).equals(labels[i]);
        }
        if (!defaultLabels) j.raw("labels", strings(labels));
        j.raw("samples", samples(stack));
        return j.end();
    }

    static String pixelHash(ImageStack stack) throws Exception {
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        for (int s = 1; s <= stack.getSize(); s++) {
            Object px = stack.getPixels(s);
            if (px instanceof byte[]) md.update((byte[]) px);
            else if (px instanceof short[]) {
                short[] p = (short[]) px;
                byte[] b = new byte[p.length * 2];
                for (int i = 0; i < p.length; i++) { b[2 * i] = (byte) p[i]; b[2 * i + 1] = (byte) (p[i] >> 8); }
                md.update(b);
            } else if (px instanceof float[]) {
                float[] p = (float[]) px;
                byte[] b = new byte[p.length * 4];
                for (int i = 0; i < p.length; i++) {
                    int v = Float.floatToIntBits(p[i]);  // canonical NaN
                    for (int k = 0; k < 4; k++) b[4 * i + k] = (byte) (v >> (8 * k));
                }
                md.update(b);
            } else {
                int[] p = (int[]) px;
                byte[] b = new byte[p.length * 3];
                for (int i = 0; i < p.length; i++) {
                    b[3 * i] = (byte) (p[i] >> 16); b[3 * i + 1] = (byte) (p[i] >> 8); b[3 * i + 2] = (byte) p[i];
                }
                md.update(b);
            }
        }
        return hex(md.digest());
    }

    static String lutHash(IndexColorModel cm) throws Exception {
        byte[] all = new byte[768], r = new byte[256], g = new byte[256], b = new byte[256];
        cm.getReds(r); cm.getGreens(g); cm.getBlues(b);
        System.arraycopy(r, 0, all, 0, 256);
        System.arraycopy(g, 0, all, 256, 256);
        System.arraycopy(b, 0, all, 512, 256);
        return hex(MessageDigest.getInstance("SHA-256").digest(all));
    }

    static String samples(ImageStack stack) {
        int n = stack.getWidth() * stack.getHeight(), planes = stack.getSize();
        TreeSet<Integer> idx = new TreeSet<>();
        for (int i : new int[] {0, 1, 2, 3, 13, n / 2}) if (i < n) idx.add(i);
        if (planes > 1) idx.add((planes - 1) * n + n / 2);
        StringBuilder sb = new StringBuilder("[");
        for (int flat : idx) {
            Object px = stack.getPixels(flat / n + 1);
            int i = flat % n;
            String v;
            if (px instanceof byte[]) v = "" + (((byte[]) px)[i] & 255);
            else if (px instanceof short[]) v = "" + (((short[]) px)[i] & 0xffff);
            else if (px instanceof float[]) v = number(((float[]) px)[i]);
            else v = "" + (((int[]) px)[i] & 0xffffff);
            if (sb.length() > 1) sb.append(",");
            sb.append("[").append(flat).append(",").append(v).append("]");
        }
        return sb.append("]").toString();
    }

    // MARK: Cases

    static class Cases {
        final List<String> list = new ArrayList<>();
        void add(String id, String op, Spec[] inputs, Json params, List<ImagePlus> outputs) throws Exception {
            Json j = new Json();
            j.str("id", id).str("op", op);
            StringBuilder in = new StringBuilder("[");
            for (Spec s : inputs) in.append(in.length() > 1 ? "," : "").append(s.json());
            j.raw("inputs", in.append("]").toString());
            j.raw("params", params.end());
            if (outputs == null) j.raw("error", "true");
            else {
                StringBuilder o = new StringBuilder("[");
                for (ImagePlus imp : outputs) o.append(o.length() > 1 ? ",\n     " : "\n     ").append(result(imp));
                j.raw("outputs", o.append("]").toString());
            }
            list.add(j.end());
        }
    }

    static void write(File f, Cases cases) throws Exception {
        StringBuilder sb = new StringBuilder();
        sb.append("{\n  \"imagej\": \"").append(IJ.getVersion()).append("\",\n  \"cases\": [\n    ");
        sb.append(String.join(",\n    ", cases.list));
        sb.append("\n  ]\n}\n");
        Files.write(f.toPath(), sb.toString().getBytes(StandardCharsets.UTF_8));
        System.out.println(f.getName() + ": " + cases.list.size() + " cases");
    }

    // MARK: Type conversions (Image > Type, ij.plugin.Converter)

    static Spec[] conversionInputs() {
        return new Spec[] {
            new Spec("gray8"),
            new Spec("gray8").luts("Fire").range(50, 200),
            new Spec("gray8").luts("Grays-inv").range(20, 230),
            new Spec("gray8").luts("Spectrum"),
            new Spec("gray8").luts("Stripes").range(20, 220),
            new Spec("gray16").range(1000, 40000),
            new Spec("gray16"),
            new Spec("gray16n").luts("Fire"),
            new Spec("gray16").signed().range(30000, 36000),
            new Spec("gray16n").function(-10, 0.5, "nM").range(500, 2500),
            new Spec("gray32").range(-100.25, 300.5),
            new Spec("gray32"),
            new Spec("gray32s").range(-50, 400).luts("Ice"),
            new Spec("gray32").range(10, 10),
            new Spec("rgb"),
            new Spec("gray16").range(1000, 40000).luts("Fire").dims(1, 5, 1),
            new Spec("gray8").range(20, 220).luts("Fire").dims(1, 4, 1),
            new Spec("gray8").luts("Spectrum").range(20, 220).dims(1, 3, 1),
            new Spec("gray8").luts("Stripes").range(20, 220).dims(1, 3, 1),
            new Spec("gray16n").luts("Stripes").range(200, 3000).dims(1, 2, 1),
            new Spec("gray32").range(-100.25, 300.5).dims(1, 4, 1),
            new Spec("gray16").signed().range(30000, 36000).dims(1, 3, 1),
            new Spec("rgb").dims(1, 3, 1),
            new Spec("gray16").dims(3, 4, 2).mode("composite").range(1000, 40000, 0, 65535, 5000, 20000),
            new Spec("gray16").dims(3, 4, 2).mode("color").range(1000, 40000, 0, 65535, 5000, 20000),
            new Spec("gray16").dims(3, 4, 2).mode("grayscale").range(1000, 40000, 0, 65535, 5000, 20000),
            new Spec("gray16").dims(3, 4, 2).mode("composite").active("101").range(1000, 40000, 0, 65535, 5000, 20000),
            new Spec("gray8").dims(3, 4, 2).mode("composite").luts("Cyan", "Magenta", "Yellow").range(0, 255, 30, 200, 10, 100),
            new Spec("gray32s").dims(2, 3, 1).mode("composite").luts("Green", "Magenta").range(-100.25, 300.5, 0, 200),
            new Spec("gray16n").dims(3, 1, 1).mode("composite").range(200, 3000, 100, 3099, 1000, 2000),
            new Spec("gray16n").dims(3, 1, 1).mode("color").range(200, 3000, 100, 3099, 1000, 2000),
            new Spec("gray16").dims(2, 3, 1).mode("composite").signed().range(30000, 36000, 0, 65535),
        };
    }

    static String describe(Spec s) {
        String d = s.pattern;
        if (s.c * s.z * s.t > 1) d += "-" + s.c + "x" + s.z + "x" + s.t;
        if (s.c > 1) d += "-" + s.mode + (s.active != null ? "-" + s.active : "");
        if (!s.cal.equals("none")) d += "-" + s.cal;
        if (s.luts != null) d += "-" + String.join("+", s.luts);
        if (s.display != null) d += "-" + Arrays.deepToString(s.display).replace(" ", "");
        return d;
    }

    static Cases conversions() throws Exception {
        Cases cases = new Cases();
        String[][] targets = {{"gray8", "8-bit"}, {"gray16", "16-bit"}, {"gray32Float", "32-bit"}, {"rgb8", "RGB Color"}};
        for (Spec base : conversionInputs()) {
            String name = describe(base);
            for (String[] target : targets) {
                for (int variant = 0; variant < 3; variant++) {
                    boolean scale = variant != 1, weighted = variant == 2;
                    if (!scale && target[0].equals("gray32Float")) continue;
                    if (!scale && target[0].equals("rgb8")) continue;
                    if (weighted && !base.rgb()) continue;
                    Spec spec = cloneSpec(base);
                    ImagePlus imp = build(spec);
                    String error = convert(imp, target[1], scale, weighted);
                    Json params = new Json().str("to", target[0]).bool("scale", scale).bool("weighted", weighted);
                    String id = "convert/" + name + "/" + target[0] + (scale ? "" : "/unscaled") + (weighted ? "/weighted" : "");
                    cases.add(id, "convert", new Spec[] {spec}, params, error == null ? List.of(imp) : null);
                }
            }
        }
        return cases;
    }

    static Spec cloneSpec(Spec s) {
        Spec c = new Spec(s.pattern);
        c.w = s.w; c.h = s.h; c.c = s.c; c.z = s.z; c.t = s.t; c.offset = s.offset;
        c.display = s.display == null ? null : Arrays.stream(s.display).map(double[]::clone).toArray(double[][]::new);
        c.luts = s.luts == null ? null : s.luts.clone();
        c.mode = s.mode; c.active = s.active; c.cal = s.cal;
        c.function = s.function == null ? null : s.function.clone();
        c.valueUnit = s.valueUnit;
        return c;
    }

    /** Runs Image > Type > item as the menu does; returns an error message for refused conversions. */
    static String convert(ImagePlus imp, String item, boolean scale, boolean weighted) {
        ImageConverter.setDoScaling(scale);
        Prefs.weightedColor = weighted;
        if (weighted) ColorProcessor.setWeightingFactors(0.299, 0.587, 0.114);
        else ColorProcessor.setWeightingFactors(1d / 3d, 1d / 3d, 1d / 3d);
        int bits = imp.getBitDepth();
        IJ.redirectErrorMessages(false);
        WindowManager.setTempCurrentImage(imp);
        new Converter().run(item);
        WindowManager.setTempCurrentImage(null);
        String error = imp.getBitDepth() == bits && !item.equals(bits == 8 ? "8-bit" : bits == 16 ? "16-bit" : bits == 32 ? "32-bit" : "RGB Color")
            ? "unsupported" : null;
        ImageConverter.setDoScaling(true);
        Prefs.weightedColor = false;
        ColorProcessor.setWeightingFactors(1d / 3d, 1d / 3d, 1d / 3d);
        return error;
    }

    // MARK: Z Project (ij.plugin.ZProjector)

    static Cases projections() throws Exception {
        Cases cases = new Cases();
        String[] methods = {"avg", "max", "min", "sum", "sd", "median"};
        Spec[] stacks = {
            new Spec("gray8").luts("Fire").range(10, 240).dims(1, 6, 1),
            new Spec("gray16").range(1000, 40000).luts("Fire").dims(1, 6, 1),
            new Spec("gray16").signed().range(30000, 36000).dims(1, 5, 1),
            new Spec("gray32").range(-100.25, 300.5).luts("Ice").dims(1, 6, 1),
            new Spec("gray32s").range(-50, 400).dims(1, 5, 1),
            new Spec("rgb").dims(1, 6, 1),
            new Spec("gray16n").dims(1, 1, 5),
            new Spec("gray16n").dims(3, 1, 1).mode("composite").luts("Cyan", "Magenta", "Yellow").range(200, 3000, 100, 3099, 1000, 2000),
        };
        for (Spec base : stacks) {
            int n = base.c * base.z * base.t;
            int[][] ranges = n >= 5 ? new int[][] {{1, n}, {2, n - 1}} : new int[][] {{1, n}};
            for (String m : methods) for (int[] r : ranges) {
                Spec spec = cloneSpec(base);
                ImagePlus imp = build(spec);
                ImagePlus out = project(imp, m, r[0], r[1]);
                Json params = new Json().str("method", m).num("start", r[0]).num("stop", r[1]).bool("allFrames", true).num("frame", 1);
                cases.add("zproject/" + describe(base) + "/" + m + "/" + r[0] + "-" + r[1], "zproject", new Spec[] {spec}, params, List.of(out));
            }
        }
        Spec[] hyper = {
            new Spec("gray16").dims(3, 4, 2).mode("composite").range(1000, 40000, 0, 65535, 5000, 20000),
            new Spec("gray8").dims(3, 4, 2).mode("color").luts("Cyan", "Magenta", "Fire").range(0, 255, 30, 200, 10, 100),
            new Spec("gray32s").dims(2, 3, 2).mode("grayscale").luts("Green", "Magenta").range(-100.25, 300.5, 0, 200),
            new Spec("rgb").dims(1, 4, 2),
            new Spec("gray16n").dims(1, 4, 2).luts("Fire").range(200, 3000),
            new Spec("gray16n").dims(2, 1, 3).mode("composite").luts("Red", "Green").range(200, 3000, 100, 3099),
        };
        for (Spec base : hyper) for (String m : methods) {
            int[][] variants = base.z > 1 && base.t > 1
                ? new int[][] {{1, base.z, 1, 1}, {2, 3, 1, 1}, {1, base.z, 0, 2}}
                : new int[][] {{1, base.z > 1 ? base.z : base.t, 1, 1}};
            for (int[] v : variants) {
                Spec spec = cloneSpec(base);
                ImagePlus imp = build(spec);
                boolean all = v[2] == 1;
                imp.setPosition(1, 1, v[3]);
                ImagePlus out = project(imp, m + (all ? " all" : ""), v[0], v[1]);
                Json params = new Json().str("method", m).num("start", v[0]).num("stop", v[1]).bool("allFrames", all).num("frame", v[3]);
                cases.add("zproject/" + describe(base) + "/" + m + "/" + v[0] + "-" + v[1] + (all ? "" : "/frame" + v[3]),
                    "zproject", new Spec[] {spec}, params, List.of(out));
            }
        }
        return cases;
    }

    /** ZProjector.run, plus the gray LUT that the menu command gives projections of simple composites. */
    static ImagePlus project(ImagePlus imp, String method, int start, int stop) {
        ImagePlus out = ZProjector.run(imp, method, start, stop);
        boolean simpleComposite = imp.getNChannels() == imp.getStackSize();
        if (simpleComposite && imp.getNChannels() > 1 && imp.getBitDepth() != 24 && !out.isComposite())
            grays(out);
        return out;
    }

    // MARK: Process > Math (ImageMath), Edit > Invert, Image Calculator

    static Cases math() throws Exception {
        Cases cases = new Cases();
        Spec[] images = {
            new Spec("gray8").luts("Fire").range(10, 240),
            new Spec("gray16").range(1000, 40000),
            new Spec("gray16").signed().range(30000, 36000),
            new Spec("gray32").range(-100.25, 300.5),
            new Spec("gray32s").range(-50, 400),
            new Spec("rgb"),
            new Spec("gray16n").range(200, 3000).dims(1, 3, 1),
            new Spec("gray32").range(-100.25, 300.5).dims(1, 3, 1),
        };
        Object[][] ops = {
            {"add", 25.0}, {"add", -30.7}, {"sub", 25.5}, {"mul", 1.25}, {"mul", 0.37}, {"mul", -2.0}, {"mul", 1e10},
            {"div", 2.5}, {"div", 0.0}, {"and", "11110000"}, {"or", "1010"}, {"xor", "11111111"},
            {"min", 100.0}, {"max", 200.0}, {"min", -20.5}, {"gamma", 0.5}, {"gamma", 2.2}, {"set", 25.0}, {"set", 1000.5},
            {"log", null}, {"exp", null}, {"sqr", null}, {"sqrt", null}, {"abs", null}, {"reciprocal", null},
            {"nan", new double[] {-50, 150}}, {"invert", null},
        };
        for (Spec base : images) for (Object[] op : ops) {
            String arg = (String) op[0];
            int bits = bitDepth(base.pattern);
            if (arg.equals("nan") && bits != 32) continue;
            Spec spec = cloneSpec(base);
            ImagePlus imp = build(spec);
            Json params = new Json().str("operation", arg);
            if (op[1] instanceof Double) params.num("value", (Double) op[1]);
            if (op[1] instanceof String) params.str("binary", (String) op[1]);
            if (op[1] instanceof double[]) params.num("lower", ((double[]) op[1])[0]).num("upper", ((double[]) op[1])[1]);
            applyMath(imp, arg, op[1]);
            String value = op[1] == null ? "" : op[1] instanceof double[] ? "/" + Arrays.toString((double[]) op[1]).replace(" ", "") : "/" + op[1];
            cases.add("math/" + describe(base) + "/" + arg + value, "math", new Spec[] {spec}, params, List.of(imp));
        }
        calculator(cases);
        return cases;
    }

    static void setField(Object target, String name, Object value) throws Exception {
        Field f = target.getClass().getDeclaredField(name);
        f.setAccessible(true);
        f.set(target, value);
    }

    /** Runs ImageMath.run(ip) on every plane the way PlugInFilterRunner does, or Edit > Invert. */
    static void applyMath(ImagePlus imp, String arg, Object value) throws Exception {
        int size = imp.getStackSize();
        if (arg.equals("invert")) {
            // ij.plugin.filter.Filters("invert").run(ip)
            if (size == 1) imp.getProcessor().invert();
            else {
                ImageStack stack = imp.getStack();
                ImageProcessor ip = stack.getProcessor(1);
                for (int i = 1; i <= size; i++) {
                    ip.setPixels(stack.getPixels(i));
                    ip.invert();
                }
                if (imp.getBitDepth() == 16) imp.resetDisplayRange();
            }
            return;
        }
        ImageMath math = new ImageMath();
        math.setup(arg, imp);
        if (value instanceof Double) {
            double v = (Double) value;
            for (String field : new String[] {"addValue", "mulValue", "minValue", "maxValue", "gammaValue"}) setField(math, field, v);
        }
        if (value instanceof String) setField(math, "andValue", value);
        if (value instanceof double[]) {
            double[] t = (double[]) value;
            imp.getProcessor().setThreshold(t[0], t[1], ImageProcessor.NO_LUT_UPDATE);
        }
        if (size == 1) {
            math.run(imp.getProcessor());
        } else {
            ImageStack stack = imp.getStack();
            ImageProcessor ip = stack.getProcessor(1);
            if (value instanceof double[]) ip.setThreshold(((double[]) value)[0], ((double[]) value)[1], ImageProcessor.NO_LUT_UPDATE);
            for (int i = 1; i <= size; i++) {
                ip.setPixels(stack.getPixels(i));
                ip.setSliceNumber(i);
                ip.setSnapshotPixels(null);
                math.run(ip);
            }
        }
        if (value instanceof double[]) imp.getProcessor().resetThreshold();
    }

    static void calculator(Cases cases) throws Exception {
        String[] ops = {"add", "sub", "mul", "div", "and", "or", "xor", "min", "max", "ave", "diff", "copy", "zero"};
        Spec[][] pairs = {
            {new Spec("gray8").luts("Fire").range(10, 240), new Spec("gray8").offset(3)},
            {new Spec("gray16").range(1000, 40000), new Spec("gray16").offset(3)},
            {new Spec("gray32s").range(-50, 400), new Spec("gray32").offset(3).range(-100.25, 300.5)},
            {new Spec("rgb"), new Spec("rgb").offset(3)},
            {new Spec("gray8"), new Spec("gray16").range(1000, 40000).offset(3)},
            {new Spec("gray16n"), new Spec("gray8").offset(3)},
            {new Spec("gray8"), new Spec("gray32").range(-100.25, 300.5).offset(3)},
            {new Spec("gray16").signed().range(30000, 36000), new Spec("gray16n").offset(3)},
            {new Spec("gray16n").dims(1, 3, 1), new Spec("gray16n").dims(1, 3, 1).offset(3)},
            {new Spec("gray8").dims(1, 3, 1), new Spec("gray8").offset(5)},
        };
        for (Spec[] pair : pairs) for (String op : ops) for (int f = 0; f < 2; f++) {
            boolean float32 = f == 1;
            if (float32 && bitDepth(pair[0].pattern) == 32) continue;
            Spec a = cloneSpec(pair[0]), b = cloneSpec(pair[1]);
            ImagePlus img1 = build(a), img2 = build(b);
            boolean stack = img1.getStackSize() > 1;
            ImagePlus out = ImageCalculator.run(img1, img2, op + " create" + (float32 ? " 32-bit" : "") + (stack ? " stack" : ""));
            Json params = new Json().str("operation", op).bool("float", float32);
            cases.add("calc/" + describe(a) + "/" + op + "/" + describe(b) + (float32 ? "/32-bit" : ""), "calc",
                new Spec[] {a, b}, params, List.of(out));
        }
    }

    // MARK: Hyperstack tools

    static Cases tools() throws Exception {
        Cases cases = new Cases();
        // Image > Color > Split Channels
        Spec[] splits = {
            new Spec("gray16").dims(3, 4, 2).mode("composite").range(1000, 40000, 0, 65535, 5000, 20000).signed(),
            new Spec("gray8").dims(3, 2, 1).mode("grayscale").luts("Cyan", "Fire", "Yellow").range(0, 255, 30, 200, 10, 100),
            new Spec("gray32").dims(2, 1, 3).mode("color").luts("Green", "Magenta").range(-100.25, 300.5, 0, 200),
            new Spec("rgb"),
            new Spec("rgb").dims(1, 3, 1),
        };
        for (Spec base : splits) {
            Spec spec = cloneSpec(base);
            ImagePlus imp = build(spec);
            List<ImagePlus> outs = new ArrayList<>();
            if (imp.getBitDepth() == 24) {
                // ChannelSplitter.splitRGB(imp), the menu's RGB path
                ImageStack[] channels = ChannelSplitter.splitRGB(imp.getStack(), true);
                for (ImageStack s : channels) {
                    ImagePlus c = new ImagePlus("c", s);
                    c.setCalibration(imp.getCalibration());
                    outs.add(c);
                }
            } else {
                // ChannelSplitter.split runs IJ.run(imp2, "Grays", "") for grayscale composites,
                // which needs a GUI; split in color mode and apply the gray LUT the same way.
                boolean gray = ((CompositeImage) imp).getMode() == IJ.GRAYSCALE;
                if (gray) ((CompositeImage) imp).setMode(IJ.COLOR);
                for (ImagePlus c : ChannelSplitter.split(imp)) {
                    if (gray) grays(c);
                    outs.add(c);
                }
            }
            cases.add("split/" + describe(base), "split", new Spec[] {spec}, new Json(), outs);
        }
        // Image > Color > Merge Channels (create composite, keep sources)
        Object[][] merges = {
            {new int[] {0, 1, 2}, new Spec[] {new Spec("gray16n").dims(1, 2, 2).range(200, 3000), new Spec("gray16n").dims(1, 2, 2).offset(4).range(100, 3099), new Spec("gray16n").dims(1, 2, 2).offset(8).range(1000, 2000)}, false},
            {new int[] {0, 3}, new Spec[] {new Spec("gray8").range(10, 240), new Spec("gray8").offset(2)}, false},
            {new int[] {1, 4, 6}, new Spec[] {new Spec("gray32").range(-100.25, 300.5), new Spec("gray32").offset(1).luts("Fire").range(-50, 200), new Spec("gray32").offset(2)}, false},
            {new int[] {0, 1}, new Spec[] {new Spec("gray8").luts("Fire").dims(1, 3, 1), new Spec("gray8").offset(3).dims(1, 3, 1)}, false},
            {new int[] {0, 1}, new Spec[] {new Spec("gray8").luts("Fire").dims(1, 3, 1), new Spec("gray8").offset(3).dims(1, 3, 1)}, true},
            {new int[] {0, 1, 2}, new Spec[] {new Spec("gray8").dims(1, 2, 1), new Spec("gray8").luts("Grays-inv").offset(3).dims(1, 2, 1), new Spec("gray8").offset(5).dims(1, 2, 1)}, true},
            {new int[] {0, 2}, new Spec[] {new Spec("gray16").range(1000, 40000), new Spec("gray16n").offset(3)}, false},
        };
        for (Object[] m : merges) {
            int[] slots = (int[]) m[0];
            Spec[] specs = (Spec[]) m[1];
            boolean ignore = (Boolean) m[2];
            ImagePlus[] images = new ImagePlus[7];
            Spec[] built = new Spec[specs.length];
            for (int i = 0; i < specs.length; i++) {
                built[i] = cloneSpec(specs[i]);
                images[slots[i]] = build(built[i]);
            }
            RGBStackMerge merger = new RGBStackMerge();
            setField(merger, "ignoreLuts", ignore);
            ImagePlus out = merger.mergeHyperstacks(images, true);
            out.setCalibration(images[slots[0]].getCalibration());
            Json params = new Json().raw("slots", ints(slots)).bool("ignoreLUTs", ignore).bool("composite", true);
            cases.add("merge/" + Arrays.toString(slots).replace(" ", "") + "/" + describe(built[0]) + (ignore ? "/ignore-luts" : ""),
                "merge", built, params, List.of(out));
        }
        // Merge Channels without "Create composite": an RGB stack (RGBStackMerge.mergeStacks)
        Object[][] rgbMerges = {
            {new int[] {0, 1, 2}, new Spec[] {new Spec("gray8").dims(1, 2, 1), new Spec("gray8").offset(3).dims(1, 2, 1), new Spec("gray8").offset(5).dims(1, 2, 1)}},
            {new int[] {0, 2}, new Spec[] {new Spec("gray8").luts("Grays-inv"), new Spec("gray16").range(1000, 40000)}},
            {new int[] {1}, new Spec[] {new Spec("gray32").range(-100.25, 300.5).dims(1, 2, 1)}},
        };
        for (Object[] m : rgbMerges) {
            int[] slots = (int[]) m[0];
            Spec[] specs = (Spec[]) m[1];
            ImageStack[] stacks = new ImageStack[3];
            Spec[] built = new Spec[specs.length];
            ImagePlus first = null;
            for (int i = 0; i < specs.length; i++) {
                built[i] = cloneSpec(specs[i]);
                ImagePlus imp = build(built[i]);
                if (first == null) first = imp;
                stacks[slots[i]] = imp.getStack();
            }
            ImageStack rgb = new RGBStackMerge().mergeStacks(first.getWidth(), first.getHeight(), first.getStackSize(), stacks[0], stacks[1], stacks[2], true);
            ImagePlus out = new ImagePlus("RGB", rgb);
            out.setCalibration(first.getCalibration());
            Json params = new Json().raw("slots", ints(slots)).bool("ignoreLUTs", false).bool("composite", false);
            cases.add("merge-rgb/" + Arrays.toString(slots).replace(" ", "") + "/" + describe(built[0]), "merge", built, params, List.of(out));
        }
        // Image > Stacks > Tools > Make Substack
        String[] lists = {"2-8", "2-9-3", "7,1,3", "4", "1-10-4"};
        for (Spec base : new Spec[] {new Spec("gray16").dims(1, 10, 1).range(1000, 40000).luts("Fire"), new Spec("rgb").dims(1, 1, 10)}) {
            for (String list : lists) {
                Spec spec = cloneSpec(base);
                ImagePlus imp = build(spec);
                ImagePlus out = SubstackMaker.run(imp, list);
                cases.add("substack/" + describe(base) + "/" + list, "substack", new Spec[] {spec}, new Json().str("slices", list), List.of(out));
            }
        }
        String[][] hyperLists = {{"1,3", "2-4", "1-2"}, {"2", "1-4-2", "2"}, {"3,1", "4,1", "1"}, {"1-3", "1", "1-2"}};
        for (String[] l : hyperLists) {
            Spec spec = new Spec("gray16").dims(3, 4, 2).mode("color").range(1000, 40000, 0, 65535, 5000, 20000);
            ImagePlus imp = build(spec);
            ImagePlus out = SubHyperstackMaker.makeSubhyperstack(imp, l[0], l[1], l[2]);
            Json params = new Json().str("channelList", l[0]).str("sliceList", l[1]).str("frameList", l[2]);
            cases.add("subhyperstack/" + String.join("/", l), "subhyperstack", new Spec[] {spec}, params, List.of(out));
        }
        // Image > Hyperstacks > Reduce Dimensionality (keep source)
        int[][] reductions = {{1, 0, 1, 1, 3, 1}, {1, 1, 0, 2, 1, 2}, {0, 1, 1, 2, 1, 1}, {0, 0, 1, 3, 2, 1}, {1, 0, 0, 1, 2, 2}};
        for (int[] r : reductions) {
            Spec spec = new Spec("gray16").dims(3, 4, 2).mode(r[0] == 1 ? "composite" : "grayscale").range(1000, 40000, 0, 65535, 5000, 20000);
            ImagePlus imp = build(spec);
            imp.setPosition(r[3], r[4], r[5]);
            ImagePlus out = reduce(imp, r[0] == 1, r[1] == 1, r[2] == 1);
            Json params = new Json().bool("keepChannels", r[0] == 1).bool("keepSlices", r[1] == 1).bool("keepFrames", r[2] == 1)
                .num("channel", r[3]).num("slice", r[4]).num("frame", r[5]);
            cases.add("reduce/" + r[0] + r[1] + r[2] + "/at" + r[3] + "," + r[4] + "," + r[5], "reduce", new Spec[] {spec}, params, List.of(out));
        }
        // Image > Color > Arrange Channels
        int[][] orders = {{3, 1, 2}, {2, 3}, {1}};
        for (int[] order : orders) {
            Spec spec = new Spec("gray8").dims(3, 2, 1).mode("composite").luts("Cyan", "Magenta", "Yellow").range(0, 255, 30, 200, 10, 100);
            ImagePlus imp = build(spec);
            ImagePlus out = ChannelArranger.run(imp, order);
            out.copyAttributes(imp);  // as the menu command does
            cases.add("arrange/" + Arrays.toString(order).replace(" ", ""), "arrange", new Spec[] {spec},
                new Json().raw("order", ints(order)), List.of(out));
        }
        return cases;
    }

    /** HyperStackReducer.run with "Keep source" checked. */
    static ImagePlus reduce(ImagePlus imp, boolean keepC, boolean keepZ, boolean keepT) {
        int c2 = keepC ? imp.getNChannels() : 1, z2 = keepZ ? imp.getNSlices() : 1, t2 = keepT ? imp.getNFrames() : 1;
        ImagePlus imp2 = IJ.createImage("reduced", imp.getBitDepth() + "-bit", imp.getWidth(), imp.getHeight(), c2 * z2 * t2);
        imp2.setDimensions(c2, z2, t2);
        imp2.setCalibration(imp.getCalibration());
        imp2.setOpenAsHyperStack(true);
        new HyperStackReducer(imp).reduce(imp2);
        if (c2 > 1 && c2 == imp.getNChannels() && imp.isComposite()) {
            int mode = ((CompositeImage) imp).getMode();
            imp2 = new CompositeImage(imp2, mode);
            ((CompositeImage) imp2).copyLuts(imp);
        } else {
            imp2.setDisplayRange(imp.getDisplayRangeMin(), imp.getDisplayRangeMax());
            if (imp.isComposite() && ((CompositeImage) imp).getMode() == IJ.GRAYSCALE) grays(imp2);
        }
        return imp2;
    }

    /** IJ.run(imp, "Grays", "") on a single-channel image (LutLoader.showLut), which needs no GUI. */
    static void grays(ImagePlus imp) {
        IndexColorModel cm = LutLoader.getLut("Grays");
        ImageProcessor ip = imp.getChannelProcessor();
        ip.setColorModel(cm);
        imp.setProcessor(ip);
        if (imp.getStackSize() > 1) imp.getStack().setColorModel(cm);
    }

    // MARK: JSON

    static class Json {
        final StringBuilder sb = new StringBuilder("{");
        Json key(String k) { if (sb.length() > 1) sb.append(","); sb.append(quote(k)).append(":"); return this; }
        Json str(String k, String v) { key(k).sb.append(v == null ? "null" : quote(v)); return this; }
        Json num(String k, double v) { key(k).sb.append(number(v)); return this; }
        Json bool(String k, boolean v) { key(k).sb.append(v); return this; }
        Json raw(String k, String v) { key(k).sb.append(v); return this; }
        String end() { return sb.toString() + "}"; }
    }

    static String quote(String s) {
        StringBuilder sb = new StringBuilder("\"");
        for (char ch : s.toCharArray()) {
            if (ch == '"' || ch == '\\') sb.append('\\').append(ch);
            else if (ch < 0x20) sb.append(String.format("\\u%04x", (int) ch));
            else sb.append(ch);
        }
        return sb.append('"').toString();
    }

    /** Integral values print without a fraction; NaN and infinities as strings. */
    static String number(double v) {
        if (Double.isNaN(v)) return "\"NaN\"";
        if (Double.isInfinite(v)) return v > 0 ? "\"Infinity\"" : "\"-Infinity\"";
        if (v == Math.rint(v) && Math.abs(v) < 1e15 && !(v == 0 && 1 / v < 0)) return Long.toString((long) v);
        return Double.toString(v);
    }

    static String doubles(double[] a) {
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < a.length; i++) sb.append(i > 0 ? "," : "").append(number(a[i]));
        return sb.append("]").toString();
    }

    static String ints(int[] a) {
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < a.length; i++) sb.append(i > 0 ? "," : "").append(a[i]);
        return sb.append("]").toString();
    }

    static String ranges(double[][] r) {
        if (r == null) return "null";
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < r.length; i++) sb.append(i > 0 ? "," : "").append(doubles(r[i]));
        return sb.append("]").toString();
    }

    static String strings(String[] a) {
        if (a == null) return "null";
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < a.length; i++) sb.append(i > 0 ? "," : "").append(a[i] == null ? "null" : quote(a[i]));
        return sb.append("]").toString();
    }

    static String hex(byte[] b) {
        StringBuilder sb = new StringBuilder();
        for (byte v : b) sb.append(String.format("%02x", v & 0xff));
        return sb.toString();
    }
}
