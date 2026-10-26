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
    ]
}
