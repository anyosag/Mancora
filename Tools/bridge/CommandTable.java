// Writes ImageJ's command table (Menus.getCommands(): command name -> plugin
// class and argument) for the bridge helper, which installs it when it runs
// headless, where ImageJ 1.x can't build its AWT menus.
//
//   xvfb-run -a java -cp ij.jar Tools/bridge/CommandTable.java <out.tsv>
//
// (Any session with a display works; ImageJ needs AWT to build the table.)

import ij.IJ;
import ij.Menus;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.*;

public class CommandTable {
    public static void main(String[] args) throws Exception {
        ij.macro.Interpreter.batchMode = true;
        IJ.run("Close All");  // builds the menus (IJ.init) without opening a window
        Hashtable<?, ?> table = Menus.getCommands();
        TreeMap<String, String> sorted = new TreeMap<>();
        for (Map.Entry<?, ?> e : table.entrySet()) sorted.put(String.valueOf(e.getKey()), String.valueOf(e.getValue()));
        StringBuilder out = new StringBuilder("# ImageJ " + IJ.getVersion() + " command table: name<TAB>class(\"arg\")\n");
        for (Map.Entry<String, String> e : sorted.entrySet())
            out.append(e.getKey()).append('\t').append(e.getValue()).append('\n');
        Files.write(Paths.get(args[0]), out.toString().getBytes(StandardCharsets.UTF_8));
        System.out.println(sorted.size() + " commands");
        System.exit(0);
    }
}
