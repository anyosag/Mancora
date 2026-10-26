// Generates ROI reference data with real ImageJ 1.x, and checks ROI files
// that Mancora wrote, so Mancora's ROI tests compare against ImageJ itself.
//
//   java -Djava.awt.headless=true -cp ij.jar RoiFixtures.java <repo-root>
//
// Writes to Tests/Fixtures/roi/:
//   <name>.roi             each ROI as RoiEncoder saves it
//   <name>.reencoded.roi   only where ImageJ's own decode-then-encode differs
//                          from the file (what Mancora's encoder must match)
//   RoiSet.zip             all of them, saved by the ROI Manager's own code
//   golden.json            every ROI as RoiDecoder reads it back: geometry,
//                          properties, Roi.getMask() ("all" where it is null,
//                          i.e. a plain rectangle; left out over 20000 pixels)
//                          and ImageProcessor.fill(roi) on a 48x40 image, as
//                          hex bit strings (row-major, most significant first)
//
// Then, if Tests/Fixtures/roi/mancora/RoiSet.zip exists (written by Mancora's
// tests, see Tools/fixtures/README.md), opens it with the ROI Manager's own
// openZip() and writes mancora/verified.json: for each entry, whether it
// decodes to the same ROI (geometry, properties, mask and fill) as the entry
// the ROI Manager saved for that ROI in RoiSet.zip, and whether the bytes are
// the same.
//
// The ROI Manager can't be constructed headless (it is a Frame), so its
// saveMultiple() and openZip() run on an instance allocated without calling
// the constructor.

import ij.IJ;
import ij.ImagePlus;
import ij.gui.*;
import ij.io.RoiDecoder;
import ij.io.RoiEncoder;
import ij.plugin.frame.RoiManager;
import ij.process.*;
import java.awt.Color;
import java.awt.Font;
import java.awt.Rectangle;
import java.awt.geom.Rectangle2D;
import java.io.File;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.*;
import java.util.zip.CRC32;
import javax.swing.DefaultListModel;
import javax.swing.JList;

@SuppressWarnings({"unchecked", "rawtypes"})
public class RoiFixtures {
    static final int W = 48, H = 40;  // image size for ImageProcessor.fill(roi)
    static final int MAX_MASK_PIXELS = 20000;

    /** Each fixture's file contents: RoiEncoder's output, or a patched copy. */
    static final LinkedHashMap<String, byte[]> files = new LinkedHashMap<>();

    public static void main(String[] args) throws Exception {
        File root = new File(args[0]);
        File dir = new File(root, "Tests/Fixtures/roi");
        dir.mkdirs();
        for (File f : dir.listFiles())
            if (f.isFile()) f.delete();
        define();
        definePatched();

        StringBuilder json = new StringBuilder();
        json.append("{\n  \"imagej\": \"").append(IJ.getVersion()).append("\",\n");
        json.append("  \"imageWidth\": ").append(W).append(", \"imageHeight\": ").append(H).append(",\n");
        json.append("  \"rois\": [\n");
        int i = 0;
        for (Map.Entry<String, byte[]> e : files.entrySet()) {
            String name = e.getKey();
            byte[] bytes = e.getValue();
            Files.write(new File(dir, name + ".roi").toPath(), bytes);
            byte[] again = RoiEncoder.saveAsByteArray(new RoiDecoder(bytes, null).getRoi());
            boolean same = Arrays.equals(bytes, again);
            if (!same)
                Files.write(new File(dir, name + ".reencoded.roi").toPath(), again);
            Roi decoded = new RoiDecoder(bytes, name + ".roi").getRoi();
            String storedName = new RoiDecoder(bytes, null).getRoi().getName();
            json.append("    {\"file\": ").append(str(name + ".roi"));
            json.append(", \"reencodedIdentical\": ").append(same);
            json.append(", \"storedName\": ").append(str(storedName));
            json.append(", ").append(describe(decoded, true)).append("}");
            json.append(++i < files.size() ? ",\n" : "\n");
        }
        json.append("  ]\n}\n");
        Files.write(new File(dir, "golden.json").toPath(), json.toString().getBytes(StandardCharsets.UTF_8));

        RoiManager rm = headlessRoiManager();
        DefaultListModel labels = (DefaultListModel) field(rm, "listModel");
        ArrayList list = (ArrayList) field(rm, "rois");
        for (String name : files.keySet()) {
            labels.addElement(name);
            list.add(RoiDecoder.open(new File(dir, name + ".roi").getPath()));
        }
        int[] indexes = new int[list.size()];
        for (int k = 0; k < indexes.length; k++) indexes[k] = k;
        File zip = new File(dir, "RoiSet.zip");
        Method save = RoiManager.class.getDeclaredMethod("saveMultiple", int[].class, String.class);
        save.setAccessible(true);
        if (!(Boolean) save.invoke(rm, indexes, zip.getPath()))
            throw new RuntimeException("ROI Manager could not save " + zip);
        normalizeZipTimes(zip);
        System.out.println("ImageJ " + IJ.getVersion() + ": " + files.size() + " ROI fixtures written");

        File mancoraZip = new File(dir, "mancora/RoiSet.zip");
        if (mancoraZip.isFile())
            verifyMancora(dir, mancoraZip);
    }

    // MARK: The ROIs

    static void add(String name, Roi roi) {
        addFile(name, RoiEncoder.saveAsByteArray(roi));
    }

    static void addFile(String name, byte[] bytes) {
        if (files.put(name, bytes) != null)
            throw new IllegalArgumentException("duplicate " + name);
    }

    /** A copy of another fixture with a 16-bit header field changed. */
    static void patch(String name, String from, int offset, int value) {
        byte[] b = files.get(from).clone();
        if (offset == 6)
            b[6] = (byte) value;
        else {
            b[offset] = (byte) (value >> 8);
            b[offset + 1] = (byte) value;
        }
        addFile(name, b);
    }

    /** Files ImageJ reads but its current RoiEncoder doesn't write. */
    static void definePatched() {
        final int version = 4, type = 6;
        patch("legacy-v217-colors", "colors", version, 217);             // no stroke or fill before 218
        patch("legacy-v221-subpixel", "polygon-float-star", version, 221); // integer vertices before 222
        patch("legacy-v222-rect", "rect-subpixel", version, 222);        // integer rectangles before 223
        patch("legacy-v225-points", "points-styled", version, 225);      // no point type, size or counters
        patch("legacy-v227-group", "group", version, 227);               // no group, stroke always scaled
        patch("rotated-rect-tool", "rotated-rect", type, 7);             // the rotated rectangle tool's freehand type
        byte[] b = files.get("rect-int").clone();                        // no header 2: no name, no position
        Arrays.fill(b, 60, 64, (byte) 0);
        b[4] = 0;
        b[5] = (byte) 218;
        addFile("legacy-no-header2", b);
    }

    static Roi poly(int type, int[] x, int[] y) {
        return new PolygonRoi(x, y, x.length, type);
    }

    static Roi fpoly(int type, float[] x, float[] y) {
        return new PolygonRoi(x, y, x.length, type);
    }

    static void define() {
        // Rectangles, including ImageJ's 1x1 minimum and rounded corners.
        add("rect-int", new Roi(3, 4, 10, 7));
        add("rect-1x1", new Roi(0, 0, 1, 1));
        add("rect-zero-size", new Roi(5, 6, 0, 0));
        add("rect-negative", new Roi(-5, -3, 12, 9));
        add("rect-outside", new Roi(50, 45, 5, 5));
        add("rect-wide", new Roi(-10, 30, 70, 3));
        add("rect-far", new Roi(61000, 5, 10, 10));
        add("rect-subpixel", new Roi(1.25, 2.5, 7.75, 5.5));
        add("rect-subpixel-negative", new Roi(-2.5, -1.75, 6.3, 4.1));
        add("rrect", new Roi(2, 3, 20, 15, 6));
        add("rrect-odd", new Roi(4, 4, 7, 5, 3));
        add("rrect-3x3", new Roi(1, 1, 3, 3, 2));
        add("rrect-2x5", new Roi(30, 3, 2, 5, 2));
        add("rrect-big-corner", new Roi(1, 1, 9, 13, 30));
        add("rrect-negative", new Roi(-4, -6, 15, 14, 9));
        add("rrect-subpixel", new Roi(1.5, 2.5, 10.25, 8.5, 5));
        add("rrect-large", new Roi(5, 2, 37, 33, 21));
        add("rrect-wide-corner", new Roi(8, 20, 33, 11, 12));

        // Ovals: every tiny size, odd and even sizes, clipping, subpixel bounds.
        for (int w = 1; w <= 3; w++)
            for (int h = 1; h <= 3; h++)
                add("oval-" + w + "x" + h, new OvalRoi(2 * w, 3 * h, w, h));
        add("oval-4x4", new OvalRoi(10, 10, 4, 4));
        add("oval-5x4", new OvalRoi(20, 10, 5, 4));
        add("oval-17x11", new OvalRoi(4, 5, 17, 11));
        add("oval-20x20", new OvalRoi(25, 2, 20, 20));
        add("oval-negative", new OvalRoi(-3, -2, 9, 7));
        add("oval-clipped", new OvalRoi(30, 25, 30, 25));
        add("oval-large", new OvalRoi(3, 4, 41, 29));
        add("oval-subpixel", new OvalRoi(1.5, 2.25, 9.5, 6.75));
        add("oval-subpixel-negative", new OvalRoi(-1.3, -2.7, 5.2, 4.6));

        // Integer polygons: concave, self-intersecting, degenerate edges.
        add("polygon-triangle", poly(Roi.POLYGON, new int[] {2, 20, 9}, new int[] {3, 6, 18}));
        add("polygon-concave", poly(Roi.POLYGON,
            new int[] {3, 25, 25, 14, 10, 3}, new int[] {3, 3, 20, 9, 22, 18}));
        add("polygon-bowtie", poly(Roi.POLYGON, new int[] {2, 22, 22, 2}, new int[] {2, 16, 2, 16}));
        add("polygon-star", poly(Roi.POLYGON,
            new int[] {20, 27, 8, 32, 13}, new int[] {2, 30, 12, 12, 30}));
        add("polygon-degenerate", poly(Roi.POLYGON,
            new int[] {4, 4, 12, 12, 18, 18, 18, 30, 30, 4}, new int[] {4, 4, 4, 9, 9, 9, 15, 15, 25, 25}));
        add("polygon-negative", poly(Roi.POLYGON, new int[] {-6, 10, 4, -2}, new int[] {-4, 2, 14, 9}));
        add("polygon-all-negative", poly(Roi.POLYGON, new int[] {-20, -3, -9}, new int[] {-15, -12, -2}));
        add("polygon-sliver", poly(Roi.POLYGON, new int[] {5, 6, 40}, new int[] {5, 5, 30}));
        add("polygon-far", poly(Roi.POLYGON, new int[] {61000, 61010, 61004}, new int[] {3, 5, 15}));
        // RoiDecoder reads 16-bit values below -5000 as unsigned: x=40000
        // survives, x=-6000 comes back as 59536.
        add("polygon-x40000", poly(Roi.POLYGON, new int[] {40000, 40012, 40005}, new int[] {2, 4, 13}));
        add("polygon-x-6000", poly(Roi.POLYGON, new int[] {-6000, -5990, -5996}, new int[] {2, 4, 13}));
        add("freehand-int", poly(Roi.FREEROI,
            new int[] {10, 14, 19, 23, 25, 24, 20, 15, 11, 8, 6, 7},
            new int[] {4, 3, 5, 8, 13, 18, 22, 23, 21, 17, 12, 7}));
        add("traced-int", poly(Roi.TRACED_ROI,
            new int[] {5, 9, 9, 12, 12, 16, 16, 5}, new int[] {5, 5, 8, 8, 4, 4, 14, 14}));

        // Subpixel polygons: pixel-center and pixel-edge coordinates, crossings.
        add("polygon-float-triangle", fpoly(Roi.POLYGON,
            new float[] {2.3f, 20.7f, 9.5f}, new float[] {3.1f, 6.6f, 18.25f}));
        add("polygon-float-star", fpoly(Roi.POLYGON,
            new float[] {20.5f, 27.25f, 8.1f, 32.4f, 13.6f}, new float[] {2.2f, 30.7f, 12.5f, 11.9f, 30.3f}));
        add("polygon-float-halves", fpoly(Roi.POLYGON,
            new float[] {2.5f, 10.5f, 10.5f, 6.0f, 2.5f}, new float[] {2.5f, 2.5f, 9.5f, 12.0f, 9.0f}));
        add("polygon-float-integers", fpoly(Roi.POLYGON,
            new float[] {3, 14, 14, 3}, new float[] {4, 4, 11, 11}));
        add("polygon-float-negative", fpoly(Roi.POLYGON,
            new float[] {-20.5f, -3.25f, -9.75f}, new float[] {-15.5f, -12.2f, -2.6f}));
        add("polygon-float-straddle", fpoly(Roi.POLYGON,
            new float[] {-4.4f, 12.6f, 5.2f, -1.9f}, new float[] {-3.3f, 2.8f, 15.1f, 8.7f}));
        add("polygon-float-tiny", fpoly(Roi.POLYGON,
            new float[] {7.2f, 7.9f, 7.4f}, new float[] {7.1f, 7.3f, 7.95f}));
        add("polygon-float-offset", fpoly(Roi.POLYGON,
            new float[] {1000.3f, 1012.7f, 1006.1f}, new float[] {500.2f, 503.9f, 511.6f}));
        add("freehand-float", fpoly(Roi.FREEROI,
            new float[] {10.2f, 14.8f, 19.3f, 23.7f, 25.1f, 24.4f, 20.6f, 15.5f, 11.2f, 8.9f, 6.3f, 7.7f},
            new float[] {4.4f, 3.1f, 5.9f, 8.2f, 13.5f, 18.8f, 22.1f, 23.6f, 21.3f, 17.7f, 12.4f, 7.9f}));
        add("traced-float", fpoly(Roi.TRACED_ROI,
            new float[] {5, 9, 9, 12, 12, 16, 16, 5}, new float[] {5, 5, 8, 8, 4, 4, 14, 14}));

        // ImageJ's parametric polygons.
        add("ellipse", new EllipseRoi(5, 6, 30, 22, 0.5));
        add("rotated-rect", new RotatedRectRoi(4, 30, 35, 8, 9));

        // Spline-fitted outlines (the file keeps the nodes and a flag).
        PolygonRoi spline = (PolygonRoi) poly(Roi.POLYGON, new int[] {5, 25, 30, 12}, new int[] {5, 3, 20, 25});
        spline.fitSpline();
        add("polygon-spline", spline);
        PolygonRoi splineLine = (PolygonRoi) fpoly(Roi.POLYLINE, new float[] {3, 15.5f, 30}, new float[] {30, 5, 28.5f});
        splineLine.fitSpline();
        add("polyline-spline", splineLine);

        // Lines.
        add("line-int", new Line(3, 4, 30, 20));
        add("line-subpixel", new Line(1.25, 30.5, 40.75, 2.125));
        Line wide = new Line(5, 35, 40, 30);
        wide.setStrokeWidth(5);
        add("line-wide", wide);
        add("line-negative", new Line(-5.5, -3, 10, 12.25));
        add("line-vertical", new Line(10, 30, 10, 2));
        Arrow arrow = new Arrow(5, 5, 35, 25);
        arrow.setStyle(Arrow.NOTCHED);
        arrow.setHeadSize(15);
        arrow.setDoubleHeaded(true);
        arrow.setOutline(true);
        add("arrow", arrow);
        add("arrow-default", new Arrow(40, 3, 8, 12.5));
        add("polyline-int", poly(Roi.POLYLINE, new int[] {2, 10, 18, 30}, new int[] {20, 4, 25, 10}));
        add("polyline-float", fpoly(Roi.POLYLINE, new float[] {2.5f, 10.25f, 18.75f, 30.1f}, new float[] {20.5f, 4.4f, 25.6f, 10.0f}));
        add("polyline-negative", fpoly(Roi.POLYLINE, new float[] {-8.5f, -2.25f, -0.5f}, new float[] {-6.0f, -1.5f, -3.75f}));
        add("freeline-int", poly(Roi.FREELINE, new int[] {3, 4, 6, 9, 13, 18}, new int[] {10, 12, 13, 13, 12, 9}));
        add("freeline-float", fpoly(Roi.FREELINE, new float[] {3.1f, 4.2f, 6.3f, 9.4f}, new float[] {10.5f, 12.6f, 13.7f, 13.8f}));
        add("angle", poly(Roi.ANGLE, new int[] {30, 10, 25}, new int[] {5, 20, 35}));
        add("angle-float", fpoly(Roi.ANGLE, new float[] {30.5f, 10.25f, 25.75f}, new float[] {5.5f, 20.0f, 35.25f}));

        // Points: single, multi, counters and per-point positions.
        add("point-single", new PointRoi(7, 9));
        add("points-int", new PointRoi(new int[] {3, 10, 20, 47}, new int[] {4, 15, 2, 39}, 4));
        PointRoi styled = new PointRoi(new float[] {2.5f, 12.25f, 30.75f}, new float[] {3.5f, 20.125f, 8.0f}, 3);
        styled.setPointType(PointRoi.DOT);
        styled.setSize(4);
        styled.setShowLabels(true);
        styled.promptBeforeDeleting(true);
        add("points-styled", styled);
        PointRoi counted = new PointRoi(new float[] {5, 15, 25, 35}, new float[] {5, 10, 15, 20}, 4);
        counted.setCounters(new int[] {0 | 1 << 8, 2 | 1 << 8, 1 | 3 << 8, 2 | 7 << 8});
        add("points-counters", counted);
        PointRoi uniform = new PointRoi(new float[] {8, 9}, new float[] {10, 11}, 2);
        uniform.setCounters(new int[] {3 | 5 << 8, 3 | 5 << 8});
        add("points-uniform-position", uniform);
        PointRoi positioned = new PointRoi(new float[] {4, 6}, new float[] {4, 6}, 2);
        positioned.setPosition(4);
        add("points-position", positioned);
        PointRoi hyper = new PointRoi(new float[] {14, 16}, new float[] {4, 6}, 2);
        hyper.setPosition(2, 3, 1);
        add("points-hyperstack", hyper);
        add("points-negative", new PointRoi(new float[] {-3.5f, -0.5f, 2.25f}, new float[] {-1.25f, 4.0f, -7.5f}, 3));

        // Names, colors, strokes, positions, groups, properties, overlay labels.
        Roi named = new Roi(1, 1, 5, 5);
        named.setName("Zellkern ü 細胞 🙂");
        add("named-unicode", named);
        Roi colored = new OvalRoi(6, 7, 15, 9);
        colored.setFillColor(new Color(0x40, 0x80, 0xff, 0x7f));
        colored.setStrokeColor(new Color(255, 0, 128, 200));
        add("colors", colored);
        Roi stroked = poly(Roi.POLYGON, new int[] {3, 20, 12}, new int[] {3, 8, 19});
        stroked.setStrokeWidth(2.5);
        stroked.setStrokeColor(Color.green);
        add("stroke-float", stroked);
        Roi unscalable = new Roi(10, 10, 8, 6);
        unscalable.setUnscalableStrokeWidth(3);
        add("stroke-unscalable", unscalable);
        Roi stack = new Roi(2, 2, 6, 6);
        stack.setPosition(5);
        add("position-stack", stack);
        Roi hyperRect = new Roi(2, 2, 6, 6);
        hyperRect.setPosition(2, 3, 4);
        add("position-hyperstack", hyperRect);
        Roi sliceOnly = new OvalRoi(2, 2, 6, 6);
        sliceOnly.setPosition(0, 7, 0);
        add("position-slice-only", sliceOnly);
        Roi grouped = new Roi(12, 3, 9, 4);
        grouped.setGroup(7);
        add("group", grouped);
        Roi props = new Roi(4, 5, 6, 7);
        props.setProperty("class", "nucleus");
        props.setProperty("score", "0.93");
        add("properties", props);
        Roi labelled = new Roi(20, 20, 10, 10);
        Overlay proto = new Overlay();
        proto.drawLabels(true);
        proto.drawNames(true);
        proto.drawBackgrounds(true);
        proto.setLabelColor(Color.cyan);
        proto.setLabelFont(new Font("SansSerif", Font.BOLD, 14), true);
        labelled.setPrototypeOverlay(proto);
        add("overlay-labels", labelled);
        Roi everything = fpoly(Roi.POLYGON, new float[] {3.5f, 30.25f, 22.0f, 6.75f}, new float[] {2.5f, 6.0f, 28.5f, 21.25f});
        everything.setName("everything");
        everything.setFillColor(new Color(10, 20, 30, 40));
        everything.setStrokeColor(new Color(200, 100, 50));
        everything.setStrokeWidth(1.75);
        everything.setPosition(1, 2, 3);
        everything.setProperty("note", "all properties");
        Overlay proto2 = new Overlay();
        proto2.drawNames(true);
        proto2.setLabelFont(new Font("SansSerif", Font.PLAIN, 9), false);
        everything.setPrototypeOverlay(proto2);
        add("everything", everything);

        // Types Mancora keeps as opaque bytes.
        ShapeRoi composite = new ShapeRoi(new Roi(2, 2, 14, 12));
        composite.xor(new ShapeRoi(new OvalRoi(8, 6, 14, 12)));
        composite.setName("composite");
        add("composite", composite);
        add("text", new TextRoi(5, 6, "Hello", new Font("SansSerif", Font.PLAIN, 12)));
        ByteProcessor tiny = new ByteProcessor(4, 3);
        for (int k = 0; k < 12; k++) tiny.set(k % 4, k / 4, k * 20);
        ImageRoi image = new ImageRoi(3, 4, tiny);
        image.setOpacity(0.5);
        add("image", image);
    }

    // MARK: Describing a decoded ROI as JSON

    static String describe(Roi roi, boolean withMasks) {
        List<String> f = new ArrayList<>();
        f.add(kv("class", str(roi.getClass().getSimpleName())));
        f.add(kv("type", "" + roi.getType()));
        f.add(kv("subpixel", "" + roi.subPixelResolution()));
        Rectangle r = roi.getBounds();
        f.add(kv("bounds", "[" + r.x + ", " + r.y + ", " + r.width + ", " + r.height + "]"));
        Rectangle2D.Double fb = roi.getFloatBounds();
        f.add(kv("floatBounds", "[" + fb.x + ", " + fb.y + ", " + fb.width + ", " + fb.height + "]"));
        if (roi.getCornerDiameter() > 0)
            f.add(kv("cornerDiameter", "" + roi.getCornerDiameter()));
        if (roi instanceof Line) {
            Line line = (Line) roi;
            f.add(kv("line", "[" + line.x1d + ", " + line.y1d + ", " + line.x2d + ", " + line.y2d + "]"));
            if (roi instanceof Arrow) {
                Arrow a = (Arrow) roi;
                f.add(kv("arrow", "{\"style\": " + a.getStyle() + ", \"headSize\": " + a.getHeadSize()
                    + ", \"doubleHeaded\": " + a.getDoubleHeaded() + ", \"outline\": " + a.getOutline() + "}"));
            }
        }
        if (roi instanceof PolygonRoi) {
            PolygonRoi p = (PolygonRoi) roi;
            if (roi.subPixelResolution()) {
                FloatPolygon fp = p.getNonSplineFloatPolygon();
                f.add(kv("xs", floats(fp.xpoints, fp.npoints)));
                f.add(kv("ys", floats(fp.ypoints, fp.npoints)));
            } else {
                java.awt.Polygon ip = p.getNonSplineCoordinates();
                int[] xs = new int[ip.npoints], ys = new int[ip.npoints];
                for (int k = 0; k < ip.npoints; k++) {
                    xs[k] = ip.xpoints[k] + r.x;
                    ys[k] = ip.ypoints[k] + r.y;
                }
                f.add(kv("xi", ints(xs, xs.length)));
                f.add(kv("yi", ints(ys, ys.length)));
            }
            if (p.isSplineFit())
                f.add(kv("splineFit", "true"));
        }
        if (roi instanceof EllipseRoi)
            f.add(kv("params", doubles(((EllipseRoi) roi).getParams())));
        if (roi instanceof RotatedRectRoi)
            f.add(kv("params", doubles(((RotatedRectRoi) roi).getParams())));
        if (roi instanceof PointRoi) {
            PointRoi p = (PointRoi) roi;
            int[] counters = p.getCounters();
            f.add(kv("point", "{\"type\": " + p.getPointType() + ", \"size\": " + p.getSize()
                + ", \"showLabels\": " + p.getShowLabels() + ", \"promptBeforeDeleting\": " + p.promptBeforeDeleting()
                + ", \"counters\": " + (counters == null ? "null" : ints(counters, counters.length)) + "}"));
        }
        f.add(kv("name", str(roi.getName())));
        f.add(kv("strokeColor", color(roi.getStrokeColor())));
        f.add(kv("fillColor", color(roi.getFillColor())));
        f.add(kv("strokeWidth", "" + roi.getStrokeWidth()));
        f.add(kv("scaleStrokeWidth", "" + roi.getScaleStrokeWidth()));
        f.add(kv("position", "" + roi.getPosition()));
        f.add(kv("hyperstack", "" + roi.hasHyperStackPosition()));
        f.add(kv("cztPosition", "[" + roi.getCPosition() + ", " + roi.getZPosition() + ", " + roi.getTPosition() + "]"));
        f.add(kv("group", "" + roi.getGroup()));
        f.add(kv("properties", str(roi.getProperties())));
        Overlay o = roi.getPrototypeOverlay();
        Font font = o.getLabelFont();
        f.add(kv("overlay", "{\"labels\": " + o.getDrawLabels() + ", \"names\": " + o.getDrawNames()
            + ", \"backgrounds\": " + o.getDrawBackgrounds() + ", \"color\": " + color(o.getLabelColor())
            + ", \"font\": " + (font == null ? "null" : "{\"size\": " + font.getSize() + ", \"bold\": " + (font.getStyle() == Font.BOLD) + "}")
            + ", \"scalable\": " + o.scalableLabels() + "}"));
        if (withMasks && roi.isArea() && !(roi instanceof TextRoi) && !(roi instanceof ImageRoi)) {
            if ((long) r.width * r.height <= MAX_MASK_PIXELS) {
                ImageProcessor mask = roi.getMask();
                if (mask == null)  // a plain rectangle: every pixel of the bounds
                    f.add(kv("mask", str("all")));
                else {
                    if (mask.getWidth() != r.width || mask.getHeight() != r.height)
                        throw new IllegalStateException("mask size differs from bounds");
                    f.add(kv("mask", str(bits((byte[]) mask.getPixels(), mask.getWidth() * mask.getHeight()))));
                }
            }
            ByteProcessor ip = new ByteProcessor(W, H);
            ip.setColor(255);
            ip.fill(roi);
            f.add(kv("image", str(bits((byte[]) ip.getPixels(), W * H))));
        }
        return String.join(", ", f);
    }

    static String kv(String k, String v) {
        return "\"" + k + "\": " + v;
    }

    static String str(String s) {
        if (s == null) return "null";
        StringBuilder sb = new StringBuilder("\"");
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '"' || c == '\\') sb.append('\\').append(c);
            else if (c < 0x20 || c > 0x7e) sb.append(String.format("\\u%04x", (int) c));
            else sb.append(c);
        }
        return sb.append('"').toString();
    }

    static String color(Color c) {
        return c == null ? "null" : Integer.toUnsignedString(c.getRGB());
    }

    static String floats(float[] a, int n) {
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < n; i++) sb.append(i > 0 ? ", " : "").append(Float.toString(a[i]));
        return sb.append("]").toString();
    }

    static String doubles(double[] a) {
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < a.length; i++) sb.append(i > 0 ? ", " : "").append(Double.toString(a[i]));
        return sb.append("]").toString();
    }

    static String ints(int[] a, int n) {
        StringBuilder sb = new StringBuilder("[");
        for (int i = 0; i < n; i++) sb.append(i > 0 ? ", " : "").append(a[i]);
        return sb.append("]").toString();
    }

    /** Mask pixels as a bit string (row-major, most significant bit first), in hex. */
    static String bits(byte[] pixels, int n) {
        StringBuilder sb = new StringBuilder();
        int acc = 0, nb = 0;
        for (int i = 0; i < n; i++) {
            acc = acc << 1 | (pixels[i] != 0 ? 1 : 0);
            if (++nb == 8) {
                sb.append(String.format("%02x", acc));
                acc = 0;
                nb = 0;
            }
        }
        if (nb > 0) sb.append(String.format("%02x", acc << (8 - nb)));
        return sb.toString();
    }

    // MARK: The ROI Manager, headless

    static RoiManager headlessRoiManager() throws Exception {
        Field f = Class.forName("sun.misc.Unsafe").getDeclaredField("theUnsafe");
        f.setAccessible(true);
        Object unsafe = f.get(null);
        Method alloc = unsafe.getClass().getMethod("allocateInstance", Class.class);
        RoiManager rm = (RoiManager) alloc.invoke(unsafe, RoiManager.class);
        setField(rm, "listModel", new DefaultListModel());
        setField(rm, "rois", new ArrayList());
        setField(rm, "list", new JList());
        return rm;
    }

    static Object field(Object o, String name) throws Exception {
        Field f = RoiManager.class.getDeclaredField(name);
        f.setAccessible(true);
        return f.get(o);
    }

    static void setField(Object o, String name, Object value) throws Exception {
        Field f = RoiManager.class.getDeclaredField(name);
        f.setAccessible(true);
        f.set(o, value);
    }

    /** Sets every entry's DOS date to 2000-01-01 00:00 so the fixture doesn't change on each run. */
    static void normalizeZipTimes(File zip) throws Exception {
        byte[] b = Files.readAllBytes(zip.toPath());
        int eocd = b.length - 22;
        while (eocd >= 0 && u32(b, eocd) != 0x06054b50) eocd--;
        int entries = u16(b, eocd + 10);
        int cen = (int) u32(b, eocd + 16);
        for (int i = 0; i < entries; i++) {
            if (u32(b, cen) != 0x02014b50) throw new IllegalStateException("bad central directory");
            put16(b, cen + 12, 0);
            put16(b, cen + 14, (20 << 9) | (1 << 5) | 1);
            int loc = (int) u32(b, cen + 42);
            put16(b, loc + 10, 0);
            put16(b, loc + 12, (20 << 9) | (1 << 5) | 1);
            cen += 46 + u16(b, cen + 28) + u16(b, cen + 30) + u16(b, cen + 32);
        }
        Files.write(zip.toPath(), b);
    }

    static int u16(byte[] b, int i) {
        return (b[i] & 255) | (b[i + 1] & 255) << 8;
    }

    static long u32(byte[] b, int i) {
        return u16(b, i) | (long) u16(b, i + 2) << 16;
    }

    static void put16(byte[] b, int i, int v) {
        b[i] = (byte) v;
        b[i + 1] = (byte) (v >> 8);
    }

    // MARK: Checking files Mancora wrote

    static void verifyMancora(File dir, File zip) throws Exception {
        byte[] zipBytes = Files.readAllBytes(zip.toPath());
        CRC32 crc = new CRC32();
        crc.update(zipBytes);
        RoiManager rm = headlessRoiManager();
        Method open = RoiManager.class.getDeclaredMethod("openZip", String.class);
        open.setAccessible(true);
        boolean opened = (Boolean) open.invoke(rm, zip.getPath());
        DefaultListModel labels = (DefaultListModel) field(rm, "listModel");
        ArrayList list = (ArrayList) field(rm, "rois");
        int same = 0;
        StringBuilder json = new StringBuilder();
        json.append("{\n  \"imagej\": \"").append(IJ.getVersion()).append("\",\n");
        json.append("  \"file\": \"RoiSet.zip\", \"bytes\": ").append(zipBytes.length);
        json.append(", \"crc32\": ").append(crc.getValue()).append(",\n");
        json.append("  \"openedByRoiManager\": ").append(opened).append(", \"count\": ").append(list.size()).append(",\n");
        json.append("  \"entries\": [\n");
        File imagejZip = new File(dir, "RoiSet.zip");
        for (int i = 0; i < list.size(); i++) {
            String label = (String) labels.getElementAt(i);
            Roi roi = (Roi) list.get(i);
            // Compare with what the ROI Manager itself saved for this ROI.
            byte[] imagej = entryBytes(imagejZip, label + ".roi");
            String status;
            boolean identical = false;
            if (imagej == null)
                status = "no ImageJ fixture";
            else {
                Roi expected = new RoiDecoder(imagej, label + ".roi").getRoi();
                status = describe(expected, true).equals(describe(roi, true)) ? "same" : "different";
                identical = Arrays.equals(entryBytes(zip, label + ".roi"), imagej);
                if (status.equals("same")) same++;
                else {
                    System.out.println("  ImageJ:  " + describe(expected, false));
                    System.out.println("  Mancora: " + describe(roi, false));
                }
            }
            json.append("    {\"name\": ").append(str(label)).append(", \"decodes\": ").append(str(status));
            json.append(", \"identicalBytes\": ").append(identical).append("}");
            json.append(i < list.size() - 1 ? ",\n" : "\n");
        }
        json.append("  ]\n}\n");
        Files.write(new File(zip.getParentFile(), "verified.json").toPath(), json.toString().getBytes(StandardCharsets.UTF_8));
        System.out.println("Mancora's RoiSet.zip: ROI Manager opened " + list.size() + " ROIs, " + same + " decode as ImageJ's own");
    }

    /** One entry's bytes, read with java.util.zip.ZipInputStream like the ROI Manager. */
    static byte[] entryBytes(File zip, String name) throws Exception {
        try (java.util.zip.ZipInputStream in = new java.util.zip.ZipInputStream(new java.io.FileInputStream(zip))) {
            for (java.util.zip.ZipEntry e; (e = in.getNextEntry()) != null; )
                if (e.getName().equals(name)) return in.readAllBytes();
        }
        return null;
    }
}
