/// Macros that run both natively and in ImageJ, grouped by what they exercise.
enum MacroCorpus {
    /// The language: values, operators, strings, arrays, control flow,
    /// functions and number formatting, including ImageJ's quirks.
    static let language: [MacroParityCase] = [
        .init("print and numbers", #"""
            print("Hello, world");
            x = 3; y = 4.5;
            print(x + y, x*y, x/y, x%2, -x, 7%-3, -7%3, 5.5%2);
            print(1/3, 2/3*1000, 1e-10, 123456789012, NaN, 0.1+0.2, 1/0, -1/0);
            print(1e5, 1.5e-3, 2E3, 0x1F, 0xff + 1, 3.0, 100000000, 1e9, 12345.678901);
            print(0.00001234, 1234567.891, -0.5, 1e300*1e10, PI, -PI);
            """#),
        .init("string concatenation quirks", #"""
            x = 3; y = 4.5;
            print("abc" + 1 + 2.5);
            print("sum: " + x + y);
            print(x + y + " is the sum");
            s = "v=" + x/7;
            print(s);
            t = "" + 1/3;
            print(t, "" + 2/3, "n" + 1e-7, "n" + 1e10, "n" + 123456.789);
            u = "a"; u += "b"; u += 3; print(u);
            print("x" + (1 + 2) + "y");
            """#),
        .init("operators", #"""
            print(5 & 3, 5 | 3, 5 ^ 3, ~5, 1 << 4, 256 >> 2, -16 >> 2);
            print((2 == 2), (2 != 2), (3 > 2), (3 >= 3), (2 < 1), (2 <= 2));
            print(true, false, (true && false), (true || false), !true, !false);
            print(("abc" == "ABC"), ("abc" < "abd"), ("b" > "a"), ("abc" != "abc"));
            a = 2; a += 3; a -= 1; a *= 6; a /= 4; print(a);
            b = 5; b++; print(b); b--; b--; print(b);
            c = 1; d = c++ + 10; print(c, d);
            e = 1; f = ++e + 10; print(e, f);
            print(7.9 & 3, -1 & 255, 2147483647 + 1, 1e10 | 0);
            t = 2 > 1; print(t);
            u = (1 == 1) && (2 == 3); print(u);
            """#),
        .init("comparison as a print argument", #"""
            print(2 == 2);
            """#),
        .init("control flow", #"""
            for (i=0; i<5; i++) {
                if (i==1) continue;
                if (i==4) break;
                print("i=" + i);
            }
            n = 0;
            while (n < 5) n++;
            print(n);
            do { n--; } while (n > 2);
            print(n);
            if (n == 2) print("two"); else print("not two");
            if (n > 5) {
                print("big");
            } else if (n > 1) {
                print("medium");
            } else {
                print("small");
            }
            for (i=0, j=10; i<3; i++, j--) print(i, j);
            k = 0;
            for (;;) { k++; if (k > 3) break; }
            print(k);
            """#),
        .init("functions", #"""
            function sq(v) { return v*v; }
            function greet(name) { return "Hello, " + name; }
            function both(a, b) { return a + b; }
            function noReturn() { x = 1; }
            function arr(n) { a = newArray(n); for (i=0; i<n; i++) a[i] = i*i; return a; }
            function fact(n) { if (n <= 1) return 1; return n*fact(n-1); }
            print(sq(7), greet("you"), both(2, 3), both("a", "b"));
            squares = arr(4);
            Array.print(squares);
            print(fact(10), sq(sq(2)), sq(1.5));
            var g = 10;
            function useG() { g++; return g; }
            print(useG(), useG(), g);
            noReturn();
            print("done");
            """#),
        .init("arrays", #"""
            a = newArray(3, 1, 2);
            Array.sort(a);
            Array.print(a);
            s = newArray("pear", "Apple", "fig");
            Array.sort(s);
            Array.print(s);
            b = newArray(5);
            print(b.length, lengthOf(b), b[0]);
            c = Array.concat(a, s, 7);
            Array.print(c);
            d = Array.slice(c, 1, 4);
            Array.print(d);
            Array.print(Array.reverse(Array.copy(a)));
            Array.getStatistics(a, min, max, mean, std);
            print(min, max, mean, std);
            r = Array.rankPositions(newArray(30, 10, 20));
            Array.print(r);
            Array.print(Array.getSequence(4));
            Array.print(Array.trim(c, 2));
            Array.print(Array.deleteValue(newArray(1, 2, 1, 3), 1));
            Array.print(Array.deleteIndex(newArray("a", "b", "c"), 1));
            Array.print(Array.resample(newArray(0, 10), 5));
            Array.print(Array.rotate(newArray(1, 2, 3, 4), 1));
            f = newArray(1, 2, 3);
            Array.fill(f, 9);
            Array.print(f);
            g = f;
            g[0] = 1;
            Array.print(f);
            e = newArray(2);
            e[4] = 5;
            print(e.length);
            Array.print(e);
            Array.print(Array.filter(newArray("cat", "dog", "catfish"), "cat"));
            Array.print("prefix", newArray(1.5, 2.25));
            x = newArray(1, 3, 2, 5, 1, 4);
            Array.print(Array.findMaxima(x, 0));
            Array.print(Array.findMinima(x, 0));
            k = newArray(3, 1, 2);
            v = newArray("c", "a", "b");
            Array.sort(k, v);
            Array.print(k);
            Array.print(v);
            """#),
        .init("strings", #"""
            str = "Hello World";
            print(str.length, lengthOf(str), str.toUpperCase(), toLowerCase(str));
            print(str.indexOf("World"), indexOf(str, "o"), indexOf(str, "o", 5), lastIndexOf(str, "o"));
            print(substring(str, 6), substring(str, 0, 5), str.substring(3, 4));
            print(replace(str, "o", "0"), replace(str, "l+", "L"), str.replace("World", "There"));
            print(startsWith(str, "Hell"), endsWith(str, "x"), str.contains("lo W"), str.startsWith("H"));
            print(matches("abc123", "[a-z]+[0-9]+"), matches("abc", "b"), str.matches(".*World"));
            print(fromCharCode(72, 105, 33), charCodeAt("A", 0), str.charAt(4));
            print(String.trim("  padded  ") + "|", trim("\tx\n") + "|");
            print(String.pad(7, 3), IJ.pad(-5, 4), IJ.pad("ab", 5), String.pad("12", 1));
            print(String.join(newArray("a", "b", "c")), String.join(newArray(1, 2.5, 3), "-"));
            print(toString(5), toString(1.5), toString(2.25, 1), toString("3.14159", 2));
            print(d2s(PI, 4), d2s(2.5, 0), d2s(3.5, 0), d2s(-2.5, 0), d2s(1234.5678, -2), d2s(0.125, 2));
            print(toHex(255), toHex(-1), toBinary(10), toBinary(0));
            print(parseInt("42"), parseInt("ff", 16), parseInt("x"), parseInt("2.7"), parseFloat("3.25"), parseFloat(" 1e3 "));
            print(isNaN(parseFloat("abc")), parseFloat("12 apples"), parseFloat("Infinity"));
            s2 = split("a,b,,c", ",");
            print(s2.length, s2[2] == "", s2[3]);
            s3 = split("one two\tthree");
            print(s3.length, s3[2]);
            s4 = split("a1b22c", "(\\d+)");
            Array.print(s4);
            s5 = split("x;y;z", ";");
            print(s5.length);
            s6 = split("line1\nline2\n", "\n");
            print(s6.length);
            print("a\tb", "quote \"inside\"", 'single \'quoted\'');
            print("é and ü and 日本");
            """#),
        .init("string formatting", #"""
            print(String.format("%.3f", PI), String.format("%5.1f|", 2.25), String.format("%-6.2f|", 1.005));
            print(String.format("%e", 12345.678), String.format("%.2e", 0.000123), String.format("%g", 0.0001234));
            print(String.format("%.1f", 0.05), String.format("%.1f", 0.15), String.format("%.1f", 0.25));
            print(String.format("%08.3f", -3.14159), String.format("%+.2f", 2.0), String.format("%,.2f", 1234567.891));
            print(String.format("x=%.0f y=%.0f", 2.5, 3.5), String.format("%s", 1.5), String.format("%%"));
            """#),
        .init("math", #"""
            print(abs(-2.5), sqrt(2), pow(2, 10), exp(1), log(10), sin(PI/6), cos(0), tan(PI/4));
            print(atan(1), atan2(1, 1), asin(1), acos(0), floor(-1.5), round(2.5), round(-2.5), round(2.4999));
            print(minOf(3, -1), maxOf(3, -1), Math.min(1, 2), Math.max(1, 2), Math.ceil(1.2), Math.abs(-3));
            print(Math.log10(1000), Math.sqr(4), Math.constrain(15, 0, 10), Math.map(5, 0, 10, 0, 100));
            print(Math.round(2.5), Math.round(-2.5), Math.toRadians(180), Math.toDegrees(PI), Math.erf(0.5));
            print(Math.pow(2, 0.5), Math.atan2(-1, -1), Math.floor(2.7), Math.exp(0), Math.log(Math.exp(2)));
            random("seed", 42);
            print(random(), random(), random("gaussian"));
            random("seed", 1);
            a = random();
            random("seed", 1);
            print(a == random());
            """#),
        .init("lists", #"""
            List.set("b", "2");
            List.set("a", "1");
            List.set("c", "three");
            print(List.get("a"), List.get("missing") + "|", List.size, List.getValue("b") + 1);
            print(List.getList);
            print(List.indexOf("c"));
            List.toArrays(keys, values);
            Array.print(keys);
            Array.print(values);
            List.clear();
            print(List.size);
            List.setList("x=1\ny = 2\n# comment\nz:3");
            print(List.get("x"), List.get("y"), List.get("z"), List.size);
            List.fromArrays(newArray("p", "q"), newArray("10", "20"));
            print(List.get("q"));
            """#),
        .init("variables and scope", #"""
            var counter = 0;
            function bump() { counter++; local = 5; return local; }
            bump(); bump();
            print(counter);
            x = 5;
            function shadow(x) { x = x * 2; return x; }
            print(shadow(3), x);
            a = newArray(1, 2);
            function change(arr) { arr[0] = 100; }
            change(a);
            print(a[0]);
            s = "text";
            n = s.length;
            print(n);
            v = 1; v = "now a string"; print(v);
            w = "7"; print(w + 1, parseInt(w) + 1);
            """#),
        .init("nested and user functions in expressions", #"""
            function add(a, b) { return a + b; }
            function half(x) { return x / 2; }
            function label(s) { return "[" + s + "]"; }
            print(add(1, 2) * 3, half(add(4, 6)), label("x") + label(add(1, 1)));
            print(add(half(4), half(6)), lengthOf(label("abc")));
            r = newArray(add(1, 1), half(5));
            Array.print(r);
            if (add(1, 1) == 2) print("yes");
            for (i = 0; i < add(1, 2); i++) print(label(i));
            """#),
        .init("return value", #"""
            x = 4;
            return "result " + x;
            """#),
        .init("exit", #"""
            print("before");
            exit;
            print("after");
            """#),
        .init("comments and layout", #"""
            // a line comment
            /* a block
               comment */
            print("a"); /* inline */ print("b");
            x = 1 /* in */ + 2;
            print(x);
            /*

            print("hidden");
            */
            print("end") // trailing
            """#),
        .init("undefined variable error", #"""
            print("start");
            y = x + 1;
            print("never");
            """#),
        .init("missing semicolon in a loop", #"""
            for (i = 0; i < 2; i++) {
                print(i)
                print("next");
            }
            """#),
        .init("index out of range", #"""
            a = newArray(1, 2, 3);
            print(a[3]);
            """#),
        .init("statement errors", #"""
            print("ok");
            else print("no");
            """#),
        .init("getArgument and getVersion", #"""
            print("[" + getArgument() + "]");
            print(getVersion());
            requires("1.52a");
            print(IJ.pad(3, 2));
            """#),
        .init("eval", #"""
            s = eval("return 'inner ' + 2*3;");
            print(s);
            eval("print('printed inside')");
            """#),
        .init("regular expressions in replace", #"""
            print(replace("abc", "", "-"), replace("", "", "x"), replace("aaa", "a*?", "-"));
            print(replace("ab", "(a)b", "$10"), replace("abc", "(a)(b)", "$2$1$0"), replace("x-y", "(\\w)-(\\w)", "$2\\$$1"));
            print(replace("ab", "(?<n>a)b", "${n}!"), replace("a1", "(?<first>[a-z])(?<second>\\d)", "${second}${first}"));
            print(replace("ab", "(?:a)(b)", "<$1>"), replace("ab", "(x)?ab", "[$1]"), replace("no match", "xyz", "$"));
            """#),
        .init("a lone $ in a replacement", #"""
            print(replace("ab", "ab", "$"));
            """#),
        .init("a backslash ending a replacement", #"""
            print(replace("ab", "ab", "\\"));
            """#),
        .init("a replacement's missing group", #"""
            print(replace("ab", "(a)b", "$2"));
            """#),
        .init("a replacement's group that isn't a number", #"""
            print(replace("ab", "ab", "$x"));
            """#),
        .init("a replacement's missing named group", #"""
            print(replace("ab", "(?<n>a)b", "${m}"));
            """#),
        .init("Math.toRadians and toDegrees", #"""
            n = 0; m = 0;
            for (i = 0; i < 1000; i++) {
                if (Math.toRadians(i) == i / 180 * PI) n++;
                if (Math.toDegrees(i) == i * 180 / PI) m++;
            }
            print(n, m);
            """#),
        .init("printing a string function that returns nothing", #"""
            print(String.append("x"));
            print("a", String.append("y"));
            print(String.resetBuffer);
            print(String.buffer + "|");
            """#),
        .init("deep recursion", #"""
            function depth(n) { if (n == 0) return 0; return 1 + depth(n - 1); }
            print(depth(600));
            """#),
        .init("recursion that fills the variable stack", #"""
            function f(a, b, c, d) { return f(a, b, c, d); }
            f(1, 2, 3, 4);
            """#),
        .init("results as strings and headings", #"""
            setResult("A", 0, 1.5);
            setResult("A", 1, 2);
            setResult("B", 0, 3);
            setResult("B", 1, 1e9);
            setResult("C", 0, 2147483647);
            setResult("C", 1, 4e9);
            print(getResultString("A", 0), getResultString("A", 1), getResultString("B", 0), getResultString("B", 1));
            print(getResultString("C", 0), getResultString("C", 1), Table.getString("A", 1), Table.getString("B", 1));
            print(String.getResultsHeadings + "|");
            print(Table.headings + "|");
            setResult("Label", 0, "x");
            print(Table.headings + "|");
            """#),
        .init("file names", #"""
            print(File.getName("/a/b/"), File.getName("a//b"), File.getParent("a//b"), File.getDirectory("a//b//c"));
            print(File.getName("//") + "|", File.getNameWithoutExtension("/a/b.c/"), File.getParent("/a"), File.getDirectory("/a"));
            """#),
        .init("File.openAsString of a missing file", #"""
            s = File.openAsString("/nonexistent/file.txt");
            """#),
        .init("image.subtitle without an image", #"""
            print(getInfo("image.subtitle"));
            """#),
        .init("String.format conversions and flags", #"""
            print(String.format("%#.0f", 3), String.format("%#.0e", 2.5), String.format("%.1f %<.2f", 1.25), String.format("%2$.1f %1$.1f", 1, 2));
            print(String.format("%h|%H|%.1h", 1.5, -1234567.891, NaN), String.format("%a %A %.2a %.0a", 1.5, -0.1, 0.1, -0.1));
            print(String.format("%E|%G|%+.1f|%010.1f|%-8.1e|", NaN, NaN, NaN, NaN, 1/0), String.format("%.1b|%5%|%S", 1, NaN));
            print(String.format("%0(10.1f|% (.1f|%010.3e|%.20a|%a", -1.5, -1.5, -1.5, -0.1, 1e-320));
            """#),
        .init("String.format: '-' with '0'", #"""
            print(String.format("%-08.2f|", 1.5));
            """#),
        .init("String.format: ',' with %e", #"""
            print(String.format("%,.3e", 1234.5));
            """#),
        .init("String.format: a missing argument", #"""
            print(String.format("%.2f %.3f", 1));
            """#),
        .init("String.format: '<' without a previous argument", #"""
            print(String.format("%<.1f", 1));
            """#),
        .init("String.format: '-' without a width", #"""
            print(String.format("%-.2f", 1));
            """#),
        .init("String.format: a precision without digits", #"""
            print(String.format("%.f", 1));
            """#),
        .init("String.format: no conversion", #"""
            print(String.format("%5", 1));
            """#),
        .init("String.format: '#' with %g", #"""
            print(String.format("%#g", 1));
            """#),
        .init("String.format: an unknown conversion after a good one", #"""
            print(String.format("%.2f %q", 1));
            """#),
        .init("String.format: a repeated flag", #"""
            print(String.format("%++.2f", 1));
            """#),
        .init("Table.get, Table.getString and Table.setColumn", #"""
            Table.setColumn("v", newArray(1, 2.5, 3));
            Table.setColumn("w", newArray("a", "b"));
            print(Table.size, Table.getString("w", 2) + "|", Table.get("w", 2), Table.get("v"), Table.getString("v"));
            Table.setColumn("x", newArray(7, 8, 9, 10, 11));
            print(Table.size, Table.getString("v", 4) + "|", Table.get("v", 4), Table.getString("w", 3) + "|", Table.getString("x", 4));
            print(Table.get("missing", 0), Table.getString("missing", 0));
            setResult("Label", 0, "lbl");
            print(Table.getString("Label", 0), Table.get("Label", 0), Table.get("x", 1));
            """#),
    ]

    /// Images: the current image, pixels, selections, statistics,
    /// thresholds, display ranges, calibration and commands.
    static let images: [MacroParityCase] = [
        .init("wand on every mode", #"""
            function trace(x, y, tolerance, mode) {
                if (mode == "") doWand(x, y); else doWand(x, y, tolerance, mode);
                getSelectionCoordinates(xs, ys);
                print(x, y, tolerance, mode, selectionType(), xs.length);
                Array.print(xs);
                Array.print(ys);
            }
            newImage("w", "8-bit black", 48, 32, 1);
            setColor(200); makeOval(4, 4, 16, 13); fill();
            setColor(120); makeRectangle(26, 6, 12, 16); fill();
            setColor(0); makeRectangle(29, 10, 4, 5); fill();
            setColor(121); makeRectangle(40, 6, 4, 4); fill();
            for (i = 0; i < 20; i++) setPixel(2 + i, 28 - (i % 2), 90);
            setPixel(30, 24, 90); setPixel(31, 25, 90); setPixel(32, 26, 90);
            run("Select None");
            trace(10, 10, 0, "");
            trace(27, 7, 0, "");
            trace(30, 11, 0, "");
            trace(3, 28, 0, "");
            trace(30, 24, 0, "");
            trace(0, 0, 0, "");
            trace(27, 7, 1, "Legacy");
            trace(27, 7, 0, "4-connected");
            trace(30, 24, 0, "8-connected");
            trace(30, 24, 0, "4-connected");
            trace(0, 0, 0, "8-connected");
            trace(30, 11, 0, "8-connected");
            trace(10, 10, 100, "8-connected");
            setThreshold(100, 255);
            trace(1, 10, 0, "");
            trace(30, 11, 0, "");
            trace(30, 11, 0, "4-connected");
            trace(2, 30, 0, "");
            resetThreshold();
            makeRectangle(1, 1, 3, 3);
            doWand(-5, 3);
            print(selectionType());
            """#),
        .init("wand on 16-bit, float and RGB", #"""
            newImage("a", "16-bit black", 30, 20, 1);
            setColor(4000); makeOval(3, 3, 12, 10); fill();
            setColor(4100); makeRectangle(18, 4, 8, 9); fill();
            run("Select None");
            doWand(8, 8); getSelectionCoordinates(xs, ys); Array.print(xs); Array.print(ys);
            doWand(8, 8, 150, "8-connected"); getSelectionCoordinates(xs, ys); Array.print(xs); Array.print(ys);
            newImage("b", "32-bit black", 30, 20, 1);
            setColor(1.5); makeRectangle(4, 4, 9, 7); fill();
            setPixel(6, 6, NaN);
            run("Select None");
            doWand(5, 5); getSelectionCoordinates(xs, ys); Array.print(xs); Array.print(ys);
            makeRectangle(20, 2, 3, 3);
            doWand(6, 6); print(selectionType()); getSelectionBounds(x, y, w, h); print(x, y, w, h);
            newImage("c", "RGB black", 30, 20, 1);
            setColor(255, 0, 0); makeRectangle(3, 3, 8, 8); fill();
            setColor(0, 0, 255); makeRectangle(11, 3, 8, 8); fill();
            run("Select None");
            doWand(5, 5); getSelectionCoordinates(xs, ys); Array.print(xs); Array.print(ys);
            doWand(5, 5, 1, "8-connected"); getSelectionCoordinates(xs, ys); Array.print(xs); Array.print(ys);
            """#),
        .init("image basics", #"""
            print(getTitle(), getWidth(), getHeight(), nSlices, nImages, bitDepth(), getImageID() < 0);
            getDimensions(w, h, c, z, t);
            print(w, h, c, z, t, is("binary"), is("Inverting LUT"), is("hyperstack"), is("batch mode"));
            getPixelSize(unit, pw, ph);
            print(unit, pw, ph);
            getVoxelSize(vw, vh, vd, vunit);
            print(vw, vh, vd, vunit);
            print(getPixel(3, 4), getPixel(60, 46), getPixel(-1, 0), getPixel(2.5, 3.5), getValue(3, 4));
            rename("renamed");
            print(getTitle(), getInfo("image.title"));
            """#, on: .gray8),
        .init("pixels on every type", #"""
            ids = newArray(4);
            types = newArray("8-bit", "16-bit", "32-bit", "RGB");
            for (i = 0; i < 4; i++) {
                newImage("img" + i, types[i] + " ramp", 20, 10, 1);
                setPixel(3, 4, 300);
                print(getTitle(), bitDepth(), getPixel(3, 4), getPixel(10, 2), getPixel(1.5, 2.5));
                getMinAndMax(min, max);
                print(min, max);
            }
            """#),
        .init("newImage fills", #"""
            newImage("a", "8-bit white", 5, 4, 1);
            newImage("b", "8-bit black", 5, 4, 2);
            newImage("c", "16-bit ramp", 5, 4, 1);
            newImage("d", "32-bit white", 5, 4, 1);
            newImage("e", "RGB white", 5, 4, 1);
            newImage("f", "16-bit black", 5, 4, 1);
            print(nImages, getTitle());
            selectImage("b");
            print(getTitle(), nSlices);
            selectImage(1);
            print(getTitle());
            """#),
        .init("selections and statistics", #"""
            makeRectangle(5, 6, 20, 15);
            print(selectionType());
            getSelectionBounds(x, y, w, h);
            print(x, y, w, h);
            getStatistics(area, mean, min, max, std);
            print(area, mean, min, max, std);
            getRawStatistics(n, rmean, rmin, rmax);
            print(n, rmean, rmin, rmax);
            print(getValue("Mean"), getValue("Area"), getValue("Median"), getValue("IntDen"), getValue("Skew"));
            makeOval(10, 10, 25, 18);
            print(selectionType(), getValue("Area"), getValue("Mean"), getValue("Perim."), getValue("Circ."));
            makePolygon(5, 5, 40, 8, 30, 40, 8, 30);
            print(selectionType(), getValue("Area"), getValue("Feret"), getValue("Mean"));
            getSelectionCoordinates(xs, ys);
            Array.print(xs);
            Array.print(ys);
            run("Select None");
            print(selectionType());
            getStatistics(area, mean);
            print(area, mean);
            """#, on: .gray8),
        .init("statistics on 16-bit, 32-bit, RGB and calibrated images", #"""
            for (i = 1; i <= nImages; i++) {
                selectImage(i);
                makeRectangle(3, 2, 30, 20);
                getStatistics(area, mean, min, max, std, hist);
                print(getTitle(), area, mean, min, max, std, hist.length);
                print(getValue("Mean"), getValue("StdDev"), getValue("Mode"), getValue("Min"), getValue("Kurt"));
            }
            """#, on: .gray16, .gray32, .rgb, .calibrated, tolerance: 1e-6),
        .init("histogram", #"""
            getHistogram(values, counts, 256);
            print(values.length, counts.length, values[10], counts[0], counts[100], counts[255]);
            makeRectangle(10, 10, 10, 10);
            getHistogram(0, counts2, 256);
            sum = 0;
            for (i = 0; i < 256; i++) sum += counts2[i];
            print(sum);
            """#, on: .gray8),
        .init("raw statistics' histogram of a 16-bit image", #"""
            makeOval(3, 3, 20, 14);
            getRawStatistics(n, mean, min, max, std, hist);
            print(n, max, hist.length, hist[hist.length - 1]);
            sum = 0;
            for (i = 0; i < hist.length; i++) sum += hist[i];
            print(sum);
            getStatistics(area, mean, min, max, std, hist);
            print(hist.length);
            run("Select None");
            getRawStatistics(n, mean, min, max, std, hist);
            print(n, max, hist.length, hist[hist.length - 1]);
            """#, on: .gray16),
        .init("thresholds", #"""
            setThreshold(50, 150);
            getThreshold(lower, upper);
            print(lower, upper);
            run("Convert to Mask");
            print(getTitle(), is("binary"), getPixel(5, 5));
            """#, on: .gray8),
        .init("auto thresholds", #"""
            methods = newArray("Default", "Otsu dark", "Huang", "Li dark", "Triangle", "Yen");
            for (i = 0; i < methods.length; i++) {
                setAutoThreshold(methods[i]);
                getThreshold(lower, upper);
                print(methods[i], lower, upper);
            }
            setAutoThreshold();
            getThreshold(lower, upper);
            print("legacy", lower, upper);
            resetThreshold();
            getThreshold(lower, upper);
            print(lower, upper);
            """#, on: .gray8),
        .init("16-bit thresholds and display range", #"""
            setThreshold(1000.4, 2500.6);
            getThreshold(lower, upper);
            print(lower, upper);
            setAutoThreshold("Otsu dark");
            getThreshold(lower, upper);
            print(lower, upper);
            getMinAndMax(min, max);
            print(min, max);
            setMinAndMax(500.4, 3000.6);
            getMinAndMax(min, max);
            print(min, max);
            resetMinAndMax();
            getMinAndMax(min, max);
            print(min, max);
            """#, on: .gray16),
        .init("measure and results", #"""
            run("Set Measurements...", "area mean min centroid display redirect=None decimal=3");
            makeRectangle(5, 5, 10, 10);
            run("Measure");
            makeOval(20, 10, 15, 12);
            run("Measure");
            print(nResults, getResult("Mean", 0), getResult("Area"), getResultLabel(1), getResultString("Mean", 1));
            print(getResult("X", 1), getResult("Nonexistent", 0));
            setResult("Extra", 0, 42);
            setResult("Text", 1, "hello");
            setResult("Mean", nResults, 7);
            print(nResults, getResult("Extra", 0), getResultString("Text", 1), getResult("Extra", 1));
            updateResults();
            """#, on: .gray8),
        .init("particles and summary", #"""
            setThreshold(128, 255);
            run("Analyze Particles...", "size=5-Infinity display clear summarize");
            print(nResults);
            if (nResults > 0) print(getResult("Area", 0), getResult("Mean", nResults - 1));
            """#, on: .gray8),
        .init("ROI Manager", #"""
            roiManager("reset");
            makeRectangle(5, 5, 10, 10);
            roiManager("add");
            makeOval(20, 10, 15, 12);
            roiManager("add");
            makeRectangle(5, 5, 10, 10);
            roiManager("add");
            print(roiManager("count"), RoiManager.size, RoiManager.getName(0), RoiManager.getName(1), RoiManager.getName(2));
            roiManager("select", 1);
            print(selectionType(), roiManager("index"));
            run("Set Measurements...", "area mean display redirect=None decimal=3");
            roiManager("deselect");
            roiManager("measure");
            print(nResults, getResult("Area", 0), getResult("Area", 1), getResultLabel(0));
            roiManager("select", 0);
            roiManager("rename", "first");
            print(RoiManager.getName(0));
            roiManager("delete");
            print(roiManager("count"));
            """#, on: .gray8),
        .init("stacks", #"""
            print(nSlices, getSliceNumber());
            setSlice(3);
            print(getSliceNumber(), getPixel(5, 5));
            Stack.getDimensions(w, h, c, z, t);
            print(w, h, c, z, t, Stack.isHyperstack);
            for (i = 1; i <= nSlices; i++) {
                setSlice(i);
                getStatistics(area, mean);
                print(i, mean);
            }
            run("Z Project...", "projection=[Max Intensity]");
            print(getTitle(), nSlices);
            """#, on: .stack16),
        .init("hyperstack position", #"""
            Stack.getDimensions(w, h, c, z, t);
            print(c, z, t, nSlices, Stack.isHyperstack);
            Stack.setPosition(2, 2, 1);
            Stack.getPosition(ch, sl, fr);
            print(ch, sl, fr, getSliceNumber());
            Stack.setChannel(1);
            Stack.getPosition(ch, sl, fr);
            print(ch, sl, fr, getPixel(1, 1));
            """#, on: .hyperstack),
        .init("commands on images", #"""
            run("Duplicate...", "title=copy");
            run("Gaussian Blur...", "sigma=2");
            print(getTitle(), getPixel(10, 10));
            selectImage("gray8.tif");
            run("Invert");
            print(getPixel(10, 10));
            run("8-bit");
            imageCalculator("Subtract create", "gray8.tif", "copy");
            print(getTitle(), nImages);
            close("copy");
            print(nImages);
            close();
            print(nImages, getTitle());
            """#, on: .gray8, tolerance: 1e-6),
        .init("changeValues and fill", #"""
            changeValues(0, 100, 7);
            print(getPixel(0, 0), getPixel(5, 5));
            makeRectangle(10, 10, 5, 5);
            setColor(200);
            fill();
            print(getPixel(12, 12));
            setForegroundColor(255, 255, 255);
            makeOval(30, 20, 10, 10);
            run("Fill", "slice");
            print(getPixel(35, 25));
            run("Select None");
            setPixel(1, 1, 99);
            print(getPixel(1, 1));
            """#, on: .gray8),
        .init("drawing", #"""
            setColor(200);
            drawLine(2, 3, 50, 40);
            drawLine(60, 0, 0, 46);
            drawLine(-10, 20, 70, 25);
            setLineWidth(2);
            drawLine(5, 40, 40, 5);
            setLineWidth(5);
            drawLine(10, 10, 30, 12);
            drawLine(0, 0, 3, 40);
            setLineWidth(1);
            drawRect(4, 4, 20, 15);
            fillRect(30, 20, 10, 8);
            drawOval(35, 5, 20, 14);
            fillOval(8, 25, 17, 13);
            moveTo(1, 1);
            lineTo(20, 2);
            lineTo(20, 30);
            setColor(17);
            fillOval(-5, -5, 12, 12);
            """#, on: .gray8),
        .init("drawing on 16-bit, 32-bit and RGB", #"""
            for (i = 1; i <= nImages; i++) {
                selectImage(i);
                setForegroundColor(255, 128, 0);
                drawLine(0, 0, 60, 46);
                fillRect(10, 10, 8, 8);
                setColor(100);
                fillOval(20, 20, 15, 11);
                setColor(10, 200, 30);
                drawOval(30, 5, 12, 12);
            }
            """#, on: .gray16, .gray32, .rgb),
        .init("metadata and calibration", #"""
            setMetadata("Info", "line one\nkey: value");
            print(getMetadata("Info"));
            print(getInfo("key"));
            setVoxelSize(0.5, 0.25, 2, "um");
            getVoxelSize(w, h, d, unit);
            print(w, h, d, unit);
            run("Properties...", "unit=micron pixel_width=0.1 pixel_height=0.1 voxel_depth=1");
            getPixelSize(unit, pw, ph);
            print(unit, pw, ph);
            makeRectangle(0, 0, 10, 10);
            print(getValue("Area"));
            x = 10; y = 20;
            toScaled(x, y);
            print(x, y);
            toUnscaled(x, y);
            print(x, y);
            """#, on: .gray8),
        .init("no image open", #"""
            print("start");
            print(getTitle());
            """#),
    ]

    /// Saving, options and `call` targets that change what a macro gets.
    static let filesAndOptions: [MacroParityCase] = [
        .init("getInfo keys for selections, overlays and fonts", #"""
            makeRectangle(2, 2, 5, 5);
            print(getInfo("selection.color"), getInfo("overlay") + "|", getInfo("font.name"));
            Roi.setStrokeColor("magenta");
            print(getInfo("roi.color"));
            setFont("Serif", 14, "bold");
            print(getInfo("font.name"));
            setFont("user");
            print(getInfo("font.name"));
            """#, on: .gray8),
        .init("save and saveAs keep ImageJ's names", #"""
            dir = getDirectory("temp");
            save(dir + "mancora-save.tif");
            print(getTitle(), File.exists(dir + "mancora-save.tif"));
            save(dir + "mancora-save-noext");
            print(getTitle(), File.exists(dir + "mancora-save-noext.tif"));
            saveAs("Tiff", dir + "mancora-saveas.png");
            print(getTitle(), File.exists(dir + "mancora-saveas.tif"), File.exists(dir + "mancora-saveas.png"));
            makeRectangle(2, 3, 10, 12);
            saveAs("Selection", dir + "mancora-sel.txt");
            print(File.exists(dir + "mancora-sel.roi"));
            names = newArray("mancora-save.tif", "mancora-save-noext.tif", "mancora-saveas.tif", "mancora-sel.roi");
            for (i = 0; i < names.length; i++) ok = File.delete(dir + names[i]);
            """#, on: .gray8),
        .init("Roi.contains rounds", #"""
            makeRectangle(10, 10, 10, 10);
            print(Roi.contains(9.6, 9.6), Roi.contains(9.4, 10), Roi.contains(19.4, 10), Roi.contains(19.6, 10));
            makeOval(5, 5, 20, 20);
            print(Roi.contains(14.5, 14.5), Roi.contains(5.2, 5.2), Roi.contains(24.6, 15));
            """#, on: .gray8),
        .init("getList keys and setOption InvertY", #"""
            a = getList("Image.Titles");
            print(a.length, a[0]);
            m = getList("THRESHOLD.methods");
            print(m.length, m[0], m[m.length - 1]);
            setOption("InvertY", true);
            print(is("InvertY"));
            x = 3; y = 4;
            toScaled(x, y);
            print(x, y);
            makeRectangle(5, 6, 10, 4);
            List.setMeasurements;
            print(List.getValue("Y"), List.getValue("BY"));
            setOption("InvertY", false);
            print(is("InvertY"));
            setOption("Changes", false);
            print(is("changes"));
            """#, on: .gray8),
        .init("call targets Mancora runs", #"""
            call("ij.IJ.log", "logged by call");
            call("java.lang.System.gc");
            call("ij.gui.ImageWindow.setNextLocation", "10", "20");
            t = call("java.lang.System.currentTimeMillis");
            print(parseFloat(t) > 1e12, call("ij.IJ.pad", "7", "3"));
            """#),
    ]

    /// Dialogs read from macro options, as GenericDialog does in macro mode.
    /// ImageJ only sees options on a thread `IJ.run` has named "Run$_...",
    /// so each case runs a command before `ij.Macro.setOptions`; and a
    /// dialog without options would wait for a person, so each case has them.
    static let dialogs: [MacroParityCase] = [
        .init("Dialog fields from macro options", #"""
            run("Select None");
            call("ij.Macro.setOptions", "count=7 name=[two words] fast mode=Median size=2.5 color=green");
            print(call("ij.Macro.getOptions"));
            Dialog.create("Options");
            Dialog.addNumber("Count:", 3);
            Dialog.addString("Name:", "first");
            Dialog.addCheckbox("Fast", false);
            Dialog.addCheckbox("Slow", true);
            Dialog.addChoice("Mode:", newArray("Mean", "Median", "Max"));
            Dialog.addSlider("Size", 0, 5, 1.5);
            Dialog.addNumber("Missing", 4.25);
            Dialog.addRadioButtonGroup("Color", newArray("red", "green"), 1, 2, "red");
            Dialog.addMessage("A message", 14, "blue");
            Dialog.addHelp("https://imagej.net");
            Dialog.setInsets(5, 0, 5);
            Dialog.show();
            n = Dialog.getNumber();
            s = Dialog.getString();
            f = Dialog.getCheckbox();
            w = Dialog.getCheckbox();
            m = Dialog.getChoice();
            z = Dialog.getNumber();
            miss = Dialog.getNumber();
            c = Dialog.getRadioButton();
            print(n, s, f, w, m, z, miss, c, Dialog.getYesNoCancel());
            print(n + 1, f + w);
            call("ij.Macro.setOptions", "");
            """#, on: .gray8),
        .init("Dialog keys of repeated labels, folders and image choices", #"""
            run("Select None");
            call("ij.Macro.setOptions", "value=10 value_1=20 folder=/data folder_1=b image=gray8.tif step=0.3");
            Dialog.create("Repeated");
            Dialog.addNumber("Value:", 1);
            Dialog.addNumber("Value:", 2);
            Dialog.addNumber("Value:", 3, 2, 6, "px");
            Dialog.addDirectory("Folder:", "/tmp");
            Dialog.addString("Folder", "x");
            Dialog.addFile("File:", "/tmp/a.tif");
            Dialog.addImageChoice("Image:");
            Dialog.addSlider("Step", 0, 1, 0.5, 0.1);
            Dialog.addCheckboxGroup(2, 2, newArray("A", "B", "C"), newArray(1, 0, 1));
            Dialog.enableYesNoCancel("Do", "Don't");
            Dialog.show();
            print(Dialog.getNumber(), Dialog.getNumber(), Dialog.getNumber());
            print(Dialog.getString(), Dialog.getString(), Dialog.getString(), Dialog.getImageChoice(), Dialog.getNumber());
            print(Dialog.getCheckbox(), Dialog.getCheckbox(), Dialog.getCheckbox(), Dialog.getYesNoCancel());
            call("ij.Macro.setOptions", "");
            """#, on: .gray8),
        .init("Dialog values naming variables", #"""
            run("Select None");
            width = 42;
            label = "from var";
            call("ij.Macro.setOptions", "width=&width title=&label size=0x1f");
            Dialog.create("Vars");
            Dialog.addNumber("Width", 1);
            Dialog.addString("Title", "t");
            Dialog.addNumber("Size", 1);
            Dialog.show();
            print(Dialog.getNumber(), Dialog.getString(), Dialog.getNumber());
            call("ij.Macro.setOptions", "");
            """#, on: .gray8),
        .init("prompts and choosers from macro options", #"""
            run("Select None");
            call("ij.Macro.setOptions", "enter=12.5 your=Ann choose=/tmp/data select=/tmp/folder/a.tif");
            print(getNumber("Enter a value", 3), getString("Your name:", "Bob"));
            print(getNumber("Other", 8), getString("Missing", "default"));
            print(getDirectory("Choose a folder"));
            path = File.openDialog("Select a file");
            print(path, File.name, File.directory);
            call("ij.Macro.setOptions", "");
            """#, on: .gray8),
        .init("run() clears macro options", #"""
            run("Select None");
            call("ij.Macro.setOptions", "count=5");
            print(call("ij.Macro.getOptions"));
            run("Select None");
            print(call("ij.Macro.getOptions"));
            """#, on: .gray8),
        .init("Dialog error past the last field", #"""
            run("Select None");
            call("ij.Macro.setOptions", "a=4");
            Dialog.create("E");
            Dialog.addNumber("A", 1);
            Dialog.show();
            print(Dialog.getNumber(), Dialog.getString(), Dialog.getCheckbox(), Dialog.getChoice());
            call("ij.Macro.setOptions", "");
            Dialog.addString("B", "b");
            print(Dialog.getString());
            x = Dialog.getNumber();
            """#, on: .gray8),
        .init("Dialog before Dialog.create", #"""
            x = Dialog.getNumber();
            """#),
    ]

    /// Tables: the current table, Table.* members, CSV and TSV files,
    /// Array.show and Table.applyMacro. Each case closes the tables it
    /// opened, since ImageJ keeps their windows from case to case.
    static let tables: [MacroParityCase] = [
        .init("Table calls without a title use the front table", #"""
            Table.create("Mancora T1");
            Table.set("A", 0, 1.5);
            Table.set("B", 0, "x");
            Table.set("A", 1, 2);
            print(Table.size, Table.title, Table.headings);
            print(Table.get("A", 1), Table.getString("B", 0), Table.getString("A", 0), Table.get("Missing", 0));
            print(Table.columnExists("B"), Table.columnExists("C"), nResults);
            Table.create("Mancora T2");
            Table.set("C", 0, 3);
            print(Table.title, Table.size, Table.size("Mancora T1"), Table.get("A", 0, "Mancora T1"));
            Table.reset("Mancora T1");
            print(Table.title, Table.size("Mancora T1"), Table.size("Mancora T2"));
            selectWindow("Mancora T2");
            print(Table.title);
            close("Mancora T1");
            close("Mancora T2");
            """#),
        .init("Table columns, sorting and deleting", #"""
            Table.create("Mancora Sort");
            Table.setColumn("Name", newArray("pear", "apple", "fig", "kiwi"));
            Table.setColumn("Size", newArray(3, 1, 4, 1.5));
            Table.sort("Size");
            Array.print(Table.getColumn("Name"));
            Array.print(Table.getColumn("Size"));
            Table.sort("Name");
            Array.print(Table.getColumn("Name"));
            Table.renameColumn("Size", "Weight");
            Table.deleteRows(0, 1);
            print(Table.headings, Table.size);
            Table.deleteColumn("Name");
            print(Table.headings);
            Table.setColumn("Extra", newArray(7));
            Array.print(Table.getColumn("Extra"));
            Table.setColumn("Longer", newArray(1, 2, 3));
            print(Table.size, Table.getString("Weight", 2) + "|", Table.getString("Extra", 2) + "|", Table.get("Longer", 2));
            Table.showRowNumbers(true);
            print(Table.headings);
            close("Mancora Sort");
            """#),
        .init("Table save and open", #"""
            Table.create("Mancora Save");
            Table.set("Area", 0, 12.5);
            Table.set("Label", 0, "first");
            Table.set("Count", 0, 3);
            Table.set("Area", 1, 7);
            Table.set("Count", 1, 4);
            Table.set("Note", 1, "a, b");
            dir = getDirectory("temp");
            Table.save(dir + "mancora-table.csv");
            print(File.openAsString(dir + "mancora-table.csv"));
            Table.save(dir + "mancora-table.tsv");
            print(File.openAsString(dir + "mancora-table.tsv"));
            // ImageJ shows the tables Table.open and open() open without
            // waiting for their windows to come to the front, so name them.
            Table.open(dir + "mancora-table.csv", "Mancora Opened");
            t = "Mancora Opened";
            print(Table.title(t), Table.size(t), Table.headings(t));
            print(Table.getString("Label", 0, t), Table.get("Area", 0, t), Table.getString("Note", 1, t), Table.get("Count", 1, t));
            open(dir + "mancora-table.tsv");
            t = "mancora-table.tsv";
            print(Table.title(t), Table.size(t), Table.headings(t), Table.getString("Note", 1, t));
            ok = File.delete(dir + "mancora-table.csv");
            ok = File.delete(dir + "mancora-table.tsv");
            close("Mancora Save");
            close("Mancora Opened");
            close("mancora-table.tsv");
            """#),
        .init("Array.show", #"""
            a = newArray(1, 2.5, 3);
            b = newArray("x", "y");
            // ImageJ brings a new table window to the front asynchronously;
            // selectWindow waits for it, so the title-less calls see it.
            Array.show("Mancora Arrays (row numbers)", a, b);
            selectWindow("Mancora Arrays");
            print(Table.title, Table.size, Table.headings, Table.getString("b", 2) + "|", Table.get("a", 1));
            Array.show(a);
            selectWindow("a");
            print(Table.title, Table.headings);
            Array.show("Mancora Idx (indexes)", b);
            selectWindow("Mancora Idx");
            print(Table.title, Table.headings, Table.get("Index", 1));
            close("Mancora Arrays");
            close("a");
            close("Mancora Idx");
            """#),
        .init("Table.applyMacro", #"""
            Table.create("Mancora Apply");
            Table.setColumn("X", newArray(1, 2, 3));
            Table.setColumn("Y", newArray(10, 20, 30));
            Table.applyMacro("Sum = X + Y; Y = Y * 2; z = row;");
            print(Table.headings);
            Array.print(Table.getColumn("Sum"));
            Array.print(Table.getColumn("Y"));
            close("Mancora Apply");
            """#),
        .init("results functions fall back to the front table", #"""
            Table.create("Mancora Current");
            Table.set("V", 0, 5);
            print(getResult("V", 0), getResultString("V", 0), nResults);
            setResult("Area", 0, 1);
            print(nResults, getResult("Area", 0), getResultString("Area", 0));
            updateResults();
            close("Mancora Current");
            """#),
        .init("Table errors", #"""
            Table.create("Mancora Err");
            Table.set("A", 0, 1);
            print(Table.get("A", 0, "Mancora Err"));
            close("Mancora Err");
            x = Table.get("A", 0, "Mancora Missing");
            """#),
    ]

    /// Selections: the parametric constructors, Roi.* members and geometry queries.
    static let rois: [MacroParityCase] = [
        .init("selection constructors", #"""
            makeEllipse(10, 20, 40, 30, 0.5);
            print(selectionType(), Roi.getType, Roi.size);
            getSelectionCoordinates(xs, ys);
            print(xs.length, xs[0], ys[0], xs[18], ys[18], xs[45], ys[45]);
            getSelectionBounds(x, y, w, h);
            print(x, y, w, h, getValue("Area"), getValue("Mean"));
            makeRotatedRectangle(5, 5, 40, 25, 8);
            // (Roi.getType says "polygon" here: Mancora keeps the selection as
            // its .roi bytes, and ImageJ's own decoder reads these back as one.)
            print(selectionType(), getValue("Area"));
            getSelectionCoordinates(xs, ys);
            Array.print(xs);
            Array.print(ys);
            makeArrow(5, 5, 30, 20, "notched large");
            print(selectionType(), Roi.getType, Roi.getStrokeWidth);
            getLine(x1, y1, x2, y2, lw);
            print(x1, y1, x2, y2, lw);
            makeLine(3, 4, 30, 40, 5);
            getLine(x1, y1, x2, y2, lw);
            print(selectionType(), x1, y1, x2, y2, lw, Roi.size, Roi.getStrokeColor);
            makeLine(3.5, 4, 30, 40.25);
            getLine(x1, y1, x2, y2, lw);
            print(x1, y2, lw, Roi.size, Roi.getStrokeColor);
            run("Select None");
            getLine(x1, y1, x2, y2, lw);
            print(x1, lw);
            makePoint(10.5, 12, "large cross red");
            print(selectionType(), Roi.getType, Roi.getStrokeColor);
            getSelectionCoordinates(xs, ys);
            print(xs[0], ys[0]);
            makeSelection("point dot", newArray(1, 5, 9), newArray(2, 6, 10));
            print(selectionType(), Roi.size, Roi.getStrokeColor);
            """#, on: .gray8),
        .init("geometry queries", #"""
            makeOval(10, 10, 20, 12);
            Roi.getFeretPoints(xs, ys);
            Array.print(xs);
            Array.print(ys);
            makePolygon(5, 5, 40, 8, 30, 40, 8, 30);
            Roi.getFeretPoints(xs, ys);
            Array.print(xs);
            Array.print(ys);
            print(selectionContains(10, 10), selectionContains(4, 4), selectionContains(29.6, 39.4));
            makeRectangle(10, 10, 4, 3);
            Roi.getContainedPoints(xs, ys);
            print(xs.length);
            Array.print(xs);
            Array.print(ys);
            makeLine(2, 2, 20, 30, 10, 40);
            print(Roi.contains(10, 20), Roi.contains(3, 3), selectionContains(15, 25));
            makePoint(7, 8);
            print(Roi.contains(7, 8), Roi.contains(8, 8));
            makeSelection("point", newArray(1.5, 4), newArray(2, 6));
            Roi.getContainedPoints(xs, ys);
            Array.print(xs);
            makeLine(1, 1, 10, 10);
            print(Roi.contains(5, 5));
            """#, on: .gray8),
        .init("Roi without a selection", #"""
            run("Select None");
            print(Roi.size);
            c = Roi.getStrokeColor;
            """#, on: .gray8),
        // Last: after Roi.copy and Roi.paste, ImageJ no longer reports the
        // next case's image as changed (state the bridge keeps between macros).
        .init("Roi properties and colors", #"""
            makeRectangle(5, 6, 20, 10);
            print(Roi.getStrokeColor, Roi.getFillColor, Roi.getStrokeWidth, Roi.getGroup, Roi.getName + "|");
            Roi.setStrokeColor("red");
            Roi.setStrokeWidth(3);
            print(Roi.getStrokeColor, Roi.getStrokeWidth);
            Roi.setStrokeColor(0, 128, 255);
            print(Roi.getStrokeColor);
            Roi.setStrokeColor("#80ff0000");
            print(Roi.getStrokeColor);
            Roi.setFillColor("cyan");
            print(Roi.getFillColor, Roi.getStrokeColor);
            Roi.setProperty("id", "42");
            Roi.setProperty("flag");
            Roi.setProperty("zeta", "z");
            print(Roi.getProperty("id"), Roi.getProperty("flag"), Roi.getProperty("none") + "|");
            print(Roi.getProperties);
            Roi.setProperty("flag", "");
            print(Roi.getProperties);
            Roi.setPosition(3);
            Roi.getPosition(c, z, t);
            print(c, z, t);
            Roi.setPosition(1, 2, 3);
            Roi.getPosition(c, z, t);
            print(c, z, t);
            Roi.setName("box");
            print(Roi.getName, selectionName());
            Roi.getFloatBounds(x, y, w, h);
            print(x, y, w, h);
            makeRectangle(1.5, 2.25, 10.5, 4);
            Roi.getFloatBounds(x, y, w, h);
            print(x, y, w, h);
            Roi.getBounds(x, y, w, h);
            print(x, y, w, h);
            print(Roi.getDefaultColor, Roi.getDefaultStrokeWidth, Roi.getDefaultGroup);
            Roi.copy;
            run("Select None");
            print(selectionType());
            Roi.paste;
            print(selectionType());
            Roi.move(3, 4);
            Roi.translate(1, 1);
            getSelectionBounds(x, y, w, h);
            print(x, y, w, h);
            Roi.selectNone;
            print(selectionType(), Roi.size);
            """#, on: .gray8),
    ]

    /// The ROI Manager: colors and widths, positions, saving, filling and Multi Measure.
    static let roiManager: [MacroParityCase] = [
        .init("ROI Manager colors, selection and saving", #"""
            roiManager("reset");
            makeRectangle(5, 5, 10, 10);
            roiManager("add");
            makeOval(20, 10, 15, 12);
            roiManager("add", "red", 3);
            makeRectangle(30, 30, 8, 6);
            Roi.setName("box");
            roiManager("add", "#00ff00");
            print(roiManager("count"), RoiManager.getName(2), RoiManager.getIndex("box"));
            roiManager("select", 1);
            print(Roi.getStrokeColor, Roi.getStrokeWidth);
            roiManager("select", 2);
            print(Roi.getStrokeColor);
            roiManager("deselect");
            roiManager("set color", "blue");
            roiManager("select", 0);
            print(Roi.getStrokeColor, Roi.getFillColor);
            roiManager("set fill color", "yellow");
            print(Roi.getFillColor, Roi.getStrokeColor);
            roiManager("select", 0);
            print(Roi.getFillColor, Roi.getStrokeColor);
            roiManager("deselect");
            roiManager("set line width", 4);
            roiManager("select", 2);
            print(Roi.getStrokeWidth, Roi.getFillColor, Roi.getStrokeColor);
            RoiManager.selectByName("box");
            print(roiManager("index"));
            RoiManager.setPosition(2);
            roiManager("select", 2);
            Roi.getPosition(c, z, t);
            print(c, z, t);
            RoiManager.selectPosition(0, 2, 0);
            print(RoiManager.selected, roiManager("index"));
            RoiManager.selectGroup(0);
            print(RoiManager.selected);
            RoiManager.translate(2, 3);
            roiManager("select", 0);
            getSelectionBounds(x, y, w, h);
            print(x, y, w, h);
            RoiManager.delete(1);
            print(roiManager("count"), RoiManager.getName(1));
            dir = getDirectory("temp");
            roiManager("save", dir + "mancora-rois.zip");
            roiManager("select", 1);
            roiManager("save", dir + "mancora-one.roi");
            roiManager("save selected", dir + "mancora-sel.zip");
            roiManager("reset");
            roiManager("open", dir + "mancora-sel.zip");
            print(roiManager("count"), RoiManager.getName(0));
            roiManager("open", dir + "mancora-rois.zip");
            roiManager("open", dir + "mancora-one.roi");
            print(roiManager("count"), RoiManager.getName(2), RoiManager.getName(3));
            roiManager("select all");
            print(RoiManager.selected);
            ok = File.delete(dir + "mancora-rois.zip");
            ok = File.delete(dir + "mancora-one.roi");
            ok = File.delete(dir + "mancora-sel.zip");
            roiManager("reset");
            """#, on: .gray8),
        .init("ROI Manager fill", #"""
            setForegroundColor(200, 200, 200);
            roiManager("reset");
            makeRectangle(5, 5, 10, 10);
            roiManager("add");
            makeOval(20, 10, 15, 12);
            roiManager("add");
            roiManager("fill");
            print(selectionType(), getPixel(7, 7), getPixel(27, 16), getPixel(1, 1));
            roiManager("reset");
            """#, on: .gray8),
        .init("ROI Manager Multi Measure", #"""
            run("Set Measurements...", "area mean min display redirect=None decimal=3");
            roiManager("reset");
            makeRectangle(5, 5, 10, 10);
            roiManager("add");
            makeOval(20, 10, 15, 12);
            Roi.setName("ov");
            roiManager("add");
            roiManager("multi measure");
            print(nResults, getResult("Mean1", 0), getResult("Area(ov)", 0), getResultLabel(0), selectionType());
            roiManager("reset");
            """#, on: .gray8),
        .init("ROI Manager Multi Measure on a stack", #"""
            roiManager("reset");
            makeRectangle(5, 5, 10, 10);
            roiManager("add");
            roiManager("multi-measure measure_all one");
            print(nResults, getResult("Mean1", 4), selectionType());
            roiManager("reset");
            """#, on: .stack8),
        .init("ROI Manager slice info", #"""
            roiManager("reset");
            setSlice(3);
            makeRectangle(2, 2, 5, 5);
            roiManager("add");
            print(RoiManager.getName(0));
            roiManager("remove slice info");
            print(RoiManager.getName(0));
            roiManager("select", 0);
            Roi.getPosition(c, z, t);
            print(c, z, t, getSliceNumber());
            roiManager("reset");
            """#, on: .stack8),
    ]

    /// What commands leave behind besides pixels: the invisible threshold
    /// of binary images, and selections on stacks.
    static let commandState: [MacroParityCase] = [
        .init("a filter clears Convert to Mask's threshold", #"""
            run("Convert to Mask");
            run("Smooth");
            getThreshold(lower, upper);
            print(lower, upper);
            run("Set Measurements...", "area mean limit redirect=None decimal=3");
            run("Measure");
            """#, on: .gray8),
        .init("math and Fill clear it too", #"""
            run("Convert to Mask");
            run("Add...", "value=1");
            getThreshold(lower, upper);
            print(lower, upper);
            run("Convert to Mask");
            makeRectangle(2, 2, 5, 5);
            run("Fill", "slice");
            getThreshold(lower, upper);
            print(lower, upper);
            """#, on: .gray8),
        .init("a stack filter keeps it", #"""
            run("Convert to Mask", "method=Default background=Default black");
            run("Smooth", "stack");
            getThreshold(lower, upper);
            print(lower, upper);
            """#, on: .stack8),
        .init("a visible threshold survives math", #"""
            setThreshold(100, 200);
            run("Add...", "value=10");
            getThreshold(lower, upper);
            print(lower, upper);
            """#, on: .gray8),
        .init("binary commands set it", #"""
            run("Options...", "iterations=1 count=1 black do=Nothing");
            run("Erode");
            getThreshold(lower, upper);
            print(lower, upper);
            run("Set Measurements...", "area mean limit redirect=None decimal=3");
            run("Measure");
            run("Invert LUT");
            run("Dilate");
            getThreshold(lower, upper);
            print(lower, upper);
            """#, on: .binary),
        .init("binary commands with a white background", #"""
            run("Options...", "iterations=1 count=1 do=Nothing");
            run("Dilate");
            getThreshold(lower, upper);
            print(lower, upper);
            run("Options...", "iterations=1 count=1 black do=Nothing");
            """#, on: .binary),
        .init("binary commands on a stack don't", #"""
            run("Options...", "iterations=1 count=1 black do=Nothing");
            run("Erode", "stack");
            getThreshold(lower, upper);
            print(lower, upper);
            """#, on: .binaryStack),
        .init("Convert to Mask ignores the invisible threshold", #"""
            newImage("w", "8-bit white", 30, 30, 1);
            makeRectangle(5, 5, 5, 5);
            setColor(0);
            fill();
            run("Select None");
            run("Make Binary");
            getThreshold(lower, upper);
            print(lower, upper, getPixel(0, 0), getPixel(6, 6));
            run("Convert to Mask");
            print(getPixel(0, 0), getPixel(6, 6));
            """#),
        .init("type conversions clear the threshold", #"""
            setThreshold(1500, 3000);
            run("8-bit");
            getThreshold(lower, upper);
            print(lower, upper);
            setThreshold(10, 100);
            run("8-bit");
            getThreshold(lower, upper);
            print(lower, upper);
            """#, on: .gray16),
        .init("filters on a stack's selection", #"""
            makeRectangle(10, 7, 25, 19);
            run("Gaussian Blur...", "sigma=2 stack");
            makeOval(12, 9, 33, 21);
            run("Median...", "radius=2 stack");
            run("Invert", "stack");
            """#, on: .stack16),
        .init("Outline on a stack's selection", #"""
            run("Options...", "iterations=1 count=1 black do=Nothing");
            makeRectangle(5, 5, 30, 30);
            run("Outline", "stack");
            makeOval(5, 5, 40, 30);
            run("Outline", "stack");
            """#, on: .binaryStack),
        .init("a line selection doesn't limit filters", #"""
            makeLine(5, 5, 40, 30);
            run("Gaussian Blur...", "sigma=2");
            run("Convolve...", "text1=[1 1 1\n1 1 1\n1 1 1] normalize");
            """#, on: .gray16),
    ]
}

extension MacroCorpus {
    /// Prints an array's length and every value to 9 decimals, so profiles
    /// and histograms must match ImageJ's to the last digit.
    static let show = #"""
        function show(label, a) {
            s = label + " " + a.length + ":";
            for (i = 0; i < a.length; i++) s = s + " " + d2s(a[i], 9);
            print(s);
        }
        function showHist(label, values, counts) {
            s = label + " " + values.length + "/" + counts.length + ":";
            n = 0;
            for (i = 0; i < counts.length; i++) n += counts[i];
            s = s + " n=" + n;
            for (i = 0; i < counts.length; i++)
                if (counts.length <= 1000 || counts[i] > 0) s = s + " " + d2s(values[i], 9) + "=" + counts[i];
            print(s);
        }

        """#

    /// Line, polyline and rectangle profiles (`getProfile`) and `getLine`.
    static let profiles: [MacroParityCase] = [
        .init("straight line profiles", show + #"""
            for (k = 1; k <= nImages; k++) {
                selectImage(k);
                t = getTitle();
                makeLine(5, 7, 50, 30); show(t + " int", getProfile());
                makeLine(3.5, 40.25, 57.75, 2.5); show(t + " sub", getProfile());
                makeLine(10, 10, 10, 40); show(t + " vertical", getProfile());
                makeLine(40, 20, 12, 20); show(t + " leftward", getProfile());
                makeLine(0, 0, 60, 46); show(t + " corners", getProfile());
                makeLine(-5, 10, 70, 35.5); show(t + " outside", getProfile());
                makeLine(20.125, 11.75, 33.875, 41.25); show(t + " short", getProfile());
                makeLine(30, 30, 30, 30); show(t + " point", getProfile());
                getLine(x1, y1, x2, y2, w);
                print(x1, y1, x2, y2, w);
            }
            """#, on: .gray8, .gray16, .gray32, .rgb),
        .init("wide line profiles", show + #"""
            for (k = 1; k <= nImages; k++) {
                selectImage(k);
                t = getTitle();
                makeLine(5, 7, 50, 30, 3); show(t + " 3", getProfile());
                makeLine(5, 7, 50, 30, 10); show(t + " 10", getProfile());
                makeLine(10.5, 40.25, 50.75, 5.5, 4); show(t + " sub 4", getProfile());
                makeLine(30, 5, 30, 40, 2); show(t + " vertical 2", getProfile());
                makeLine(2, 2, 58, 44, 10); show(t + " edges 10", getProfile());
                makeLine(50, 20, 10, 22, 7); show(t + " leftward 7", getProfile());
                makeLine(-8, 30, 25, -3, 5); show(t + " outside 5", getProfile());
                makeLine(5, 7, 50, 30, 1); show(t + " 1", getProfile());
                getLine(x1, y1, x2, y2, w);
                print(x1, y1, x2, y2, w, getValue("selection.width"));
                makeLine(5, 7, 50, 30, 2.5);
                getLine(x1, y1, x2, y2, w);
                print(w);
            }
            """#, on: .gray8, .gray16, .gray32, .rgb),
        .init("polyline and freeline profiles", show + #"""
            for (k = 1; k <= nImages; k++) {
                selectImage(k);
                t = getTitle();
                makeLine(5, 5, 20, 30, 45, 10, 55, 40); show(t + " polyline", getProfile());
                makeLine(0, 0, 10, 20, 30, 20); show(t + " from origin", getProfile());
                makeSelection("polyline", newArray(4.5, 20.25, 33.75, 50.5), newArray(6.25, 30.5, 12.125, 40));
                show(t + " subpixel polyline", getProfile());
                makeSelection("polyline", newArray(5, 40), newArray(10, 30)); show(t + " two points", getProfile());
                makeSelection("freeline", newArray(5, 8, 12, 17, 23, 30, 38, 45), newArray(20, 22, 25, 24, 20, 18, 19, 23));
                show(t + " freeline", getProfile());
                makeSelection("freeline", newArray(5.5, 9.25, 14.75, 20.5, 26.125), newArray(30.5, 28.25, 27, 29.5, 33.75));
                show(t + " subpixel freeline", getProfile());
                getLine(x1, y1, x2, y2, w);
                print(x1, y1, x2, y2, w);
            }
            """#, on: .gray8, .gray16, .gray32, .rgb),
        .init("profiles without interpolation", show + #"""
            setOption("InterpolateLines", false);
            for (k = 1; k <= nImages; k++) {
                selectImage(k);
                t = getTitle();
                makeLine(3.5, 40.25, 57.75, 2.5); show(t + " sub", getProfile());
                makeLine(20.125, 11.75, 33.875, 41.25); show(t + " short", getProfile());
                makeLine(5, 7, 50, 30, 5); show(t + " wide", getProfile());
                makeLine(5, 5, 20, 30, 45, 10, 55, 40); show(t + " polyline", getProfile());
                makeSelection("freeline", newArray(5.5, 9.25, 14.75, 20.5, 26.125), newArray(30.5, 28.25, 27, 29.5, 33.75));
                show(t + " freeline", getProfile());
            }
            setOption("InterpolateLines", true);
            makeLine(3.5, 40.25, 57.75, 2.5); show("interpolated again", getProfile());
            """#, on: .gray8, .gray16, .gray32, .rgb),
        .init("rectangle profiles and the alt key", show + #"""
            for (k = 1; k <= nImages; k++) {
                selectImage(k);
                t = getTitle();
                makeRectangle(10, 5, 20, 15); show(t + " rect", getProfile());
                setKeyDown("alt"); show(t + " rows", getProfile()); setKeyDown("none");
                makeRectangle(50, 40, 20, 15); show(t + " edge", getProfile());
                setKeyDown("alt"); show(t + " edge rows", getProfile()); setKeyDown("none");
                makeRectangle(10.5, 5.25, 20.25, 15.75); show(t + " subpixel", getProfile());
                makeRectangle(5, 5, 1, 30); show(t + " column", getProfile());
                setKeyDown("alt"); show(t + " column rows", getProfile()); setKeyDown("none");
                makeRectangle(10, 10, 15, 12, 6); show(t + " rounded", getProfile());
            }
            print(isKeyDown("alt"), isKeyDown("shift"));
            setKeyDown("alt");
            print(isKeyDown("alt"), isKeyDown("shift"));
            run("Select None");
            print(isKeyDown("alt"));
            setKeyDown("alt shift");
            print(isKeyDown("alt"), isKeyDown("shift"));
            makeRectangle(1, 1, 8, 8);
            print(isKeyDown("alt"), isKeyDown("shift"), selectionType());
            setKeyDown("alt");
            makeLine(2, 3, 40, 30);
            print(isKeyDown("alt"));
            """#, on: .gray8, .gray16, .gray32, .rgb),
        .init("profiles of stacks and calibrated images", show + #"""
            for (k = 1; k <= nImages; k++) {
                selectImage(k);
                t = getTitle();
                if (nSlices > 1) setSlice(2);
                makeLine(5, 7, 50, 30); show(t + " line", getProfile());
                makeLine(5, 7, 50, 30, 6); show(t + " wide", getProfile());
                makeLine(5, 5, 20, 30, 45, 10); show(t + " polyline", getProfile());
                makeRectangle(10, 5, 20, 15); show(t + " rect", getProfile());
            }
            selectImage(1);
            run("Properties...", "unit=micron pixel_width=0.5 pixel_height=0.25 voxel_depth=1");
            makeLine(5, 7, 50, 30); show("non-square", getProfile());
            """#, on: .stack16, .calibrated, .functionCalibrated8, .functionCalibrated16, .hyperstack),
        .init("wide polylines and freelines, angles and arrows", show + #"""
            for (k = 1; k <= nImages; k++) {
                selectImage(k);
                getLine(x1, y1, x2, y2, w);
                print(getTitle(), selectionType(), w);
                show(getTitle(), getProfile());
                run("Select None");
            }
            """#, on: .polylineROI, .subpixelPolylineROI, .freelineROI, .subpixelFreelineROI, .angleROI, .arrowROI),
    ]

    /// `getHistogram` with every bin count and range ImageJ supports.
    static let histograms: [MacroParityCase] = [
        .init("8-bit and RGB histograms", show + #"""
            for (k = 1; k <= nImages; k++) {
                selectImage(k);
                t = getTitle();
                bins = newArray(256, 1, 2, 10, 64, 100, 255, 257, 1000);
                for (b = 0; b < bins.length; b++) {
                    getHistogram(values, counts, bins[b]);
                    showHist(t + " " + bins[b], values, counts);
                }
                makeRectangle(10, 5, 20, 15);
                getHistogram(values, counts, 256); showHist(t + " rect", values, counts);
                getHistogram(values, counts, 64); showHist(t + " rect 64 (whole image)", values, counts);
                makeOval(12, 9, 33, 21);
                getHistogram(values, counts, 256); showHist(t + " oval", values, counts);
                makeLine(5, 5, 40, 30);
                getHistogram(values, counts, 256); showHist(t + " line", values, counts);
                makePoint(20, 15);
                getHistogram(values, counts, 256); showHist(t + " point", values, counts);
                run("Select None");
                getHistogram(0, counts, 256);
                print(counts.length);
                getStatistics(area, mean, min, max, std, hist);
                print(area, mean, min, max, std, hist[0], hist[100], hist[128], hist[200]);
            }
            """#, on: .gray8, .rgb, .functionCalibrated8),
        .init("16-bit histograms", show + #"""
            t = getTitle();
            bins = newArray(256, 1, 3, 10, 100, 1000, 4096);
            for (b = 0; b < bins.length; b++) {
                getHistogram(values, counts, bins[b]);
                showHist(t + " " + bins[b], values, counts);
            }
            ranges = newArray(1000, 2000, 0, 65535, 1500.5, 3000.25, 4000, 100, 5000, 6000, -100, 500, 0, 0, 1234, 1234);
            for (r = 0; r < ranges.length; r += 2) {
                getHistogram(values, counts, 50, ranges[r], ranges[r + 1]);
                showHist(t + " " + ranges[r] + "-" + ranges[r + 1], values, counts);
            }
            getHistogram(values, counts, 65536);
            s = "65536 " + counts.length + ":";
            for (i = 0; i < 65536; i++) if (counts[i] > 0) s = s + " " + i + "=" + counts[i];
            print(s);
            makeRectangle(10, 5, 20, 15);
            getHistogram(values, counts, 256); showHist(t + " rect", values, counts);
            getHistogram(values, counts, 20, 1000, 3000); showHist(t + " rect range", values, counts);
            counts2 = newArray(65536);
            getHistogram(0, counts2, 65536);
            n = 0;
            for (i = 0; i < 65536; i++) n += counts2[i];
            print(n);
            makeOval(12, 9, 33, 21);
            getHistogram(values, counts, 30); showHist(t + " oval", values, counts);
            """#, on: .gray16),
        .init("calibrated 16-bit histograms", show + #"""
            t = getTitle();
            getHistogram(values, counts, 256); showHist(t, values, counts);
            getHistogram(values, counts, 40); showHist(t + " 40", values, counts);
            getHistogram(values, counts, 40, 50, 150); showHist(t + " calibrated range", values, counts);
            """#, on: .functionCalibrated16),
        .init("32-bit histograms", show + #"""
            t = getTitle();
            bins = newArray(256, 1, 7, 100, 1000);
            for (b = 0; b < bins.length; b++) {
                getHistogram(values, counts, bins[b]);
                showHist(t + " " + bins[b], values, counts);
            }
            ranges = newArray(-1, 1, 0, 0, 2, 1, -10, 10, 0.5, 0.75, 5, 6);
            for (r = 0; r < ranges.length; r += 2) {
                getHistogram(values, counts, 64, ranges[r], ranges[r + 1]);
                showHist(t + " " + ranges[r] + "-" + ranges[r + 1], values, counts);
            }
            makeRectangle(10, 5, 20, 15);
            getHistogram(values, counts, 33); showHist(t + " rect", values, counts);
            run("Select None");
            setPixel(3, 3, NaN);
            setPixel(4, 3, 1/0);
            getHistogram(values, counts, 16); showHist(t + " NaN", values, counts);
            """#, on: .gray32),
        .init("histogram range on an 8-bit image", show + #"""
            getHistogram(values, counts, 256, 0, 100);
            print("not reached");
            """#, on: .gray8),
    ]
}
