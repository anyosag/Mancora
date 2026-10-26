// Mancora's Java bridge helper inside Fiji: starts ImageJ2 (a SciJava context
// with the legacy layer, so ImageJ 1.x is Fiji's patched ij.jar and its
// plugins and SciJava's commands both work), then answers requests as
// MancoraBridgeHelper does, with SciJava's modules, scripts and languages added.
//
//   java <Fiji's JVM options> -cp <Fiji's jars and plugins>:<helper> MancoraFijiBridge
//
// Compiled with MancoraBridgeHelper.java against Fiji's class path.
//
// Methods added:
//   languages                             -> {languages: [{name, extensions[], aliases[]}]}
//   module {command, parameters{}, inputs[], titles[], outputDir, interactive}
//                                         -> {outputs[], log, results, values{}}
//   script {language, code, parameters{}, inputs[], titles[], outputDir, interactive}
//                                         -> {outputs[], log, results, values{}, value}
//
// "command" is a SciJava module's identifier ("command:<class>"), a command's
// class, a menu path ("Plugins > Tracking > TrackMate") or a menu label. An
// ImageJ 1.x command found that way runs as "run" would run it, with the
// parameters as its options. "parameters" are the module's inputs by name,
// converted to each input's type as SciJava converts them (an image input
// takes an image's title); unset image inputs take the active image. Image
// outputs come back as images; other outputs in "values", and a script's
// return value as "value".
//
// A batch request never asks: unset inputs keep their defaults, and nothing
// is displayed. An interactive one runs SciJava's pre- and postprocessors as
// Fiji does, so unset inputs are asked for in a dialog.

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

public class MancoraFijiBridge {
    public static void main(String[] args) throws Exception {
        PrintStream protocol = new PrintStream(new FileOutputStream(FileDescriptor.out), true, "UTF-8");
        // What starting Fiji prints stays off the protocol.
        ByteArrayOutputStream startup = new ByteArrayOutputStream();
        PrintStream quiet = new PrintStream(startup, true, "UTF-8");
        System.setOut(quiet);
        System.setErr(quiet);
        // Nothing here may load an ij.* class before the context starts: its
        // legacy service patches ImageJ 1.x as the classes load.
        org.scijava.Context context = new org.scijava.Context();
        MancoraFijiExtension.serve(context, protocol, new String(startup.toByteArray(), StandardCharsets.UTF_8));
    }
}

final class MancoraFijiExtension implements MancoraBridgeHelper.Extension {
    final org.scijava.Context context;
    final org.scijava.module.ModuleService modules;
    final org.scijava.command.CommandService commands;
    final org.scijava.script.ScriptService scripts;
    final org.scijava.plugin.PluginService plugins;
    final org.scijava.convert.ConvertService convert;
    final String startupLog;

    MancoraFijiExtension(org.scijava.Context context, String startupLog) {
        this.context = context;
        this.startupLog = startupLog;
        modules = context.service(org.scijava.module.ModuleService.class);
        commands = context.service(org.scijava.command.CommandService.class);
        scripts = context.service(org.scijava.script.ScriptService.class);
        plugins = context.service(org.scijava.plugin.PluginService.class);
        convert = context.service(org.scijava.convert.ConvertService.class);
    }

    static void serve(org.scijava.Context context, PrintStream protocol, String startupLog) throws Exception {
        MancoraBridgeHelper.serve(protocol, new MancoraFijiExtension(context, startupLog));
    }

    @Override
    public void describe(Map<String, Object> hello) {
        Map<String, Object> fiji = new LinkedHashMap<>();
        org.scijava.app.AppService apps = context.getService(org.scijava.app.AppService.class);
        if (apps != null) for (org.scijava.app.App app : apps.getApps().values()) fiji.put(app.getTitle(), app.getVersion());
        hello.put("fiji", fiji);
        hello.put("startupLog", startupLog);
    }

    @Override
    public Map<String, Object> handle(String method, Map<String, Object> params) throws Exception {
        switch (method) {
            case "languages":
                return languages();
            case "module":
                return runModule(params);
            case "script":
                return runScript(params);
            default:
                return null;
        }
    }

    // MARK: Menus

    /** SciJava modules in the application's menus that ImageJ 1.x's menu bar doesn't hold (it holds most). */
    @Override
    public void addMenus(List<Object> menus, Set<String> listed) {
        List<org.scijava.module.ModuleInfo> found = new ArrayList<>();
        for (org.scijava.module.ModuleInfo info : modules.getModules()) {
            org.scijava.MenuPath path = info.getMenuPath();
            if (path == null || path.isEmpty() || path.getLeaf() == null) continue;
            if (!org.scijava.UIDetails.APPLICATION_MENU_ROOT.equals(info.getMenuRoot())) continue;
            if (listed.contains(path.getLeaf().getName())) continue;
            found.add(info);
        }
        found.sort(Comparator.comparing(i -> i.getMenuPath().getMenuString()));
        for (org.scijava.module.ModuleInfo info : found) {
            List<String> names = new ArrayList<>();
            for (org.scijava.MenuEntry entry : info.getMenuPath()) names.add(entry.getName());
            String identifier = info.getIdentifier();
            Map<String, Object> entry = MancoraBridgeHelper.menuEntry(names, info.getMenuPath().getLeaf().getName(),
                identifier == null ? "command:" + info.getDelegateClassName() : identifier, accelerator(info));
            if (identifier != null && identifier.startsWith("legacy:")) entry.put("kind", "imagej1");
            menus.add(entry);
            listed.add(info.getMenuPath().getLeaf().getName());
        }
    }

    static String accelerator(org.scijava.module.ModuleInfo info) {
        org.scijava.input.Accelerator key = info.getMenuPath().getLeaf().getAccelerator();
        return key == null ? null : key.toString();
    }

    // MARK: Languages

    Map<String, Object> languages() {
        List<Object> list = new ArrayList<>();
        for (org.scijava.script.ScriptLanguage language : scripts.getLanguages()) {
            Map<String, Object> l = new LinkedHashMap<>();
            l.put("name", language.getLanguageName());
            l.put("extensions", new ArrayList<Object>(language.getExtensions()));
            l.put("aliases", new ArrayList<Object>(language.getNames()));
            list.add(l);
        }
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("languages", list);
        return result;
    }

    org.scijava.script.ScriptLanguage language(String name) {
        org.scijava.script.ScriptLanguage language = scripts.getLanguageByName(name);
        if (language == null) language = scripts.getLanguageByExtension(name.startsWith(".") ? name.substring(1) : name);
        if (language == null) {
            for (org.scijava.script.ScriptLanguage l : scripts.getLanguages())
                if (l.getLanguageName().equalsIgnoreCase(name)) return l;
            List<String> known = new ArrayList<>();
            for (org.scijava.script.ScriptLanguage l : scripts.getLanguages()) known.add(l.getLanguageName());
            throw new IllegalArgumentException("No script language \"" + name + "\" (Fiji has " + String.join(", ", known) + ")");
        }
        return language;
    }

    // MARK: Modules and scripts

    /** A module by identifier, class, menu path or menu label. */
    org.scijava.module.ModuleInfo find(String command) {
        org.scijava.module.ModuleInfo info = modules.getModuleById(command);
        if (info != null) return info;
        info = commands.getCommand(command);
        if (info != null) return info;
        String wanted = menuKey(command);
        for (org.scijava.module.ModuleInfo m : modules.getModules()) {
            org.scijava.MenuPath path = m.getMenuPath();
            if (path != null && !path.isEmpty() && menuKey(path.getMenuString()).equals(wanted)) return m;
        }
        for (org.scijava.module.ModuleInfo m : modules.getModules()) {
            org.scijava.MenuPath path = m.getMenuPath();
            if (path != null && path.getLeaf() != null && path.getLeaf().getName().trim().equals(command.trim())) return m;
        }
        throw new IllegalArgumentException("Unrecognized command: \"" + command + "\"");
    }

    /** A menu path compared without the spaces around its separators. */
    static String menuKey(String path) {
        StringBuilder b = new StringBuilder();
        for (String part : path.split(">")) {
            if (b.length() > 0) b.append('>');
            b.append(part.trim());
        }
        return b.toString();
    }

    Map<String, Object> runModule(Map<String, Object> params) throws Exception {
        String command = (String) params.get("command");
        if (command == null) throw new IllegalArgumentException("module: no command");
        org.scijava.module.ModuleInfo info = find(command);
        Map<String, Object> parameters = parameters(params);
        String identifier = info.getIdentifier();
        if (identifier != null && identifier.startsWith("legacy:")) {
            // ImageJ 1.x's command: run as "run" does, the parameters as its options.
            Map<String, Object> run = new LinkedHashMap<>(params);
            org.scijava.MenuPath path = info.getMenuPath();
            run.put("command", path != null && path.getLeaf() != null ? path.getLeaf().getName() : info.getTitle());
            run.put("options", options(parameters));
            return MancoraBridgeHelper.runWithImages("run", run);
        }
        return withImages(params, request -> {
            org.scijava.module.Module module = modules.createModule(info);
            return execute(module, parameters, request.interactive, command);
        });
    }

    Map<String, Object> runScript(Map<String, Object> params) throws Exception {
        String code = (String) params.get("code");
        if (code == null) throw new IllegalArgumentException("script: no code");
        Object name = params.get("language");
        org.scijava.script.ScriptLanguage language = language(name == null ? "ijm" : String.valueOf(name));
        Map<String, Object> parameters = parameters(params);
        return withImages(params, request -> {
            String extension = language.getExtensions().isEmpty() ? "txt" : language.getExtensions().get(0);
            org.scijava.script.ScriptInfo info = new org.scijava.script.ScriptInfo(context, "Mancora." + extension, new StringReader(code));
            org.scijava.script.ScriptModule module = (org.scijava.script.ScriptModule) modules.createModule(info);
            module.setLanguage(language);
            Writer out = new OutputStreamWriter(System.out, StandardCharsets.UTF_8);
            module.setOutputWriter(out);
            // A script's exception is logged, not thrown (with no error writer
            // set): caught here, it's reported as the script's error.
            Thread self = Thread.currentThread();
            List<String> errors = Collections.synchronizedList(new ArrayList<>());
            org.scijava.log.LogListener listener = message -> {
                if (message.level() != org.scijava.log.LogLevel.ERROR || Thread.currentThread() != self) return;
                Throwable t = message.throwable();
                errors.add(t != null ? String.valueOf(rootCause(t)) : String.valueOf(message.text()));
            };
            org.scijava.log.LogService log = context.getService(org.scijava.log.LogService.class);
            if (log != null) log.addLogListener(listener);
            Map<String, Object> result;
            try {
                result = execute(module, parameters, request.interactive, "The script");
            } finally {
                if (log != null) log.removeLogListener(listener);
                out.flush();
            }
            Object value = module.getReturnValue();
            result.put("value", value == null ? null : String.valueOf(value));
            if (!errors.isEmpty()) result.put("scriptError", String.join("\n", errors));
            return result;
        });
    }

    static Throwable rootCause(Throwable t) {
        while (t.getCause() != null && t.getCause() != t
            && (t instanceof javax.script.ScriptException || t instanceof java.lang.reflect.InvocationTargetException))
            t = t.getCause();
        return t;
    }

    interface Body {
        Map<String, Object> run(MancoraBridgeHelper.Request request) throws Exception;
    }

    /** Opens the request's images, runs `body`, and returns what it made and changed. */
    Map<String, Object> withImages(Map<String, Object> params, Body body) throws Exception {
        try {
            MancoraBridgeHelper.Request request = MancoraBridgeHelper.beginWithImages(params);
            Map<String, Object> result = body.run(request);
            @SuppressWarnings("unchecked")
            List<ij.ImagePlus> images = (List<ij.ImagePlus>) result.remove("images");
            return MancoraBridgeHelper.finishWithImages(request, result, images);
        } finally {
            MancoraBridgeHelper.endRequest();
        }
    }

    /**
     * Runs a module on this thread (where the request's images are current),
     * its inputs set from `parameters`. A batch run leaves out what would
     * ask (input harvesters and file choosers), what would remember or
     * restore inputs between runs, and the display of outputs; an
     * interactive one runs as Fiji runs it.
     */
    Map<String, Object> execute(org.scijava.module.Module module, Map<String, Object> parameters, boolean interactive,
        String what) throws Exception {
        org.scijava.module.ModuleInfo info = module.getInfo();
        for (Map.Entry<String, Object> p : parameters.entrySet()) {
            org.scijava.module.ModuleItem<?> item = info.getInput(p.getKey());
            if (item == null) throw new IllegalArgumentException(what + " has no input \"" + p.getKey() + "\"");
            Object value = p.getValue();
            Object converted = value == null ? null : convert.convert(value, item.getType());
            if (value != null && converted == null)
                throw new IllegalArgumentException("\"" + p.getKey() + "\" can't be a " + item.getType().getSimpleName() + ": " + value);
            module.setInput(p.getKey(), converted);
            module.resolveInput(p.getKey());
        }
        List<org.scijava.module.process.PreprocessorPlugin> pre =
            plugins.createInstancesOfType(org.scijava.module.process.PreprocessorPlugin.class);
        List<org.scijava.module.process.PostprocessorPlugin> post =
            plugins.createInstancesOfType(org.scijava.module.process.PostprocessorPlugin.class);
        if (!interactive) {
            pre.removeIf(p -> p instanceof org.scijava.widget.InputHarvester || asks(p));
            post.removeIf(p -> p instanceof org.scijava.display.DisplayPostprocessor);
        }
        MancoraBridgeHelper.DialogWatchdog.reset();
        new org.scijava.module.ModuleRunner(context, module, pre, post).run();
        MancoraBridgeHelper.DialogWatchdog.check(what);
        if (module instanceof org.scijava.Cancelable && ((org.scijava.Cancelable) module).isCanceled()) {
            String reason = ((org.scijava.Cancelable) module).getCancelReason();
            throw new IllegalStateException(what + " was canceled" + (reason == null ? "" : ": " + reason));
        }
        Map<String, Object> result = new LinkedHashMap<>();
        Map<String, Object> values = new LinkedHashMap<>();
        List<ij.ImagePlus> images = new ArrayList<>();
        for (org.scijava.module.ModuleItem<?> item : info.outputs()) {
            Object value = module.getOutput(item.getName());
            ij.ImagePlus image = image(value, item.getName());
            if (image != null) images.add(image);
            else values.put(item.getName(), value(value));
        }
        result.put("values", values);
        result.put("images", images);
        return result;
    }

    /** Preprocessors that ask someone, or bring back or keep inputs between runs (a batch run uses the defaults). */
    static boolean asks(Object processor) {
        String name = processor.getClass().getName();
        return name.endsWith("FilePreprocessor") || name.endsWith("FileListPreprocessor") || name.endsWith("LoadInputsPreprocessor")
            || name.endsWith("SaveInputsPreprocessor") || name.contains("Harvester");
    }

    /** An output as an ImageJ 1.x image, if it's an image. */
    ij.ImagePlus image(Object value, String name) {
        if (value instanceof ij.ImagePlus) return (ij.ImagePlus) value;
        if (value instanceof net.imagej.display.ImageDisplay) {
            net.imagej.display.ImageDisplayService displays = context.getService(net.imagej.display.ImageDisplayService.class);
            value = displays == null ? null : displays.getActiveDataset((net.imagej.display.ImageDisplay) value);
        }
        if (value instanceof net.imagej.Dataset || value instanceof net.imagej.ImgPlus
            || value instanceof net.imglib2.RandomAccessibleInterval) {
            Object converted = convert.convert(value, ij.ImagePlus.class);
            if (converted instanceof ij.ImagePlus) return (ij.ImagePlus) converted;
            if (value instanceof net.imagej.Dataset) value = ((net.imagej.Dataset) value).getImgPlus();
            @SuppressWarnings({ "unchecked", "rawtypes" })
            ij.ImagePlus wrapped = net.imglib2.img.display.imagej.ImageJFunctions.wrap((net.imglib2.RandomAccessibleInterval) value, name);
            return wrapped == null ? null : wrapped.duplicate();
        }
        return null;
    }

    /** An output as JSON: numbers, booleans and text as they are, tables as tab-separated text, anything else as text. */
    Object value(Object value) {
        if (value == null || value instanceof Boolean || value instanceof String) return value;
        if (value instanceof Number) {
            double d = ((Number) value).doubleValue();
            return Double.isNaN(d) || Double.isInfinite(d) ? String.valueOf(d) : value;
        }
        if (value instanceof org.scijava.table.Table) return table((org.scijava.table.Table<?, ?>) value);
        if (value instanceof ij.measure.ResultsTable) {
            ij.measure.ResultsTable rt = (ij.measure.ResultsTable) value;
            StringBuilder b = new StringBuilder(rt.getColumnHeadings()).append('\n');
            for (int r = 0; r < rt.size(); r++) b.append(rt.getRowAsString(r)).append('\n');
            return b.toString();
        }
        if (value.getClass().isArray()) {
            List<Object> list = new ArrayList<>();
            for (int i = 0; i < java.lang.reflect.Array.getLength(value); i++) list.add(value(java.lang.reflect.Array.get(value, i)));
            return list;
        }
        if (value instanceof Collection) {
            List<Object> list = new ArrayList<>();
            for (Object o : (Collection<?>) value) list.add(value(o));
            return list;
        }
        return String.valueOf(value);
    }

    static String table(org.scijava.table.Table<?, ?> table) {
        StringBuilder b = new StringBuilder();
        for (int c = 0; c < table.getColumnCount(); c++) {
            if (c > 0) b.append('\t');
            b.append(table.getColumnHeader(c));
        }
        b.append('\n');
        for (int r = 0; r < table.getRowCount(); r++) {
            for (int c = 0; c < table.getColumnCount(); c++) {
                if (c > 0) b.append('\t');
                b.append(table.get(c, r));
            }
            b.append('\n');
        }
        return b.toString();
    }

    @SuppressWarnings("unchecked")
    static Map<String, Object> parameters(Map<String, Object> params) {
        Object p = params.get("parameters");
        return p instanceof Map ? new LinkedHashMap<>((Map<String, Object>) p) : new LinkedHashMap<>();
    }

    /** Parameters as an ImageJ 1.x options string: `key=value`, bracketed when needed, and bare keys for true. */
    static String options(Map<String, Object> parameters) {
        StringBuilder b = new StringBuilder();
        for (Map.Entry<String, Object> p : parameters.entrySet()) {
            Object v = p.getValue();
            if (Boolean.FALSE.equals(v) || v == null) continue;
            if (b.length() > 0) b.append(' ');
            b.append(p.getKey());
            if (Boolean.TRUE.equals(v)) continue;
            String text = v instanceof Double && ((Double) v) == Math.rint((Double) v) && !Double.isInfinite((Double) v)
                ? String.valueOf(((Double) v).longValue()) : String.valueOf(v);
            b.append('=').append(text.isEmpty() || text.contains(" ") ? "[" + text + "]" : text);
        }
        return b.toString();
    }
}
