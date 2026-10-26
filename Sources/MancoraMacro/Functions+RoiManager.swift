// The ROI Manager: roiManager(cmd, ...) and RoiManager.*, ported from
// ImageJ 1.54p's Functions.java and the parts of RoiManager they run.
// Combining ROIs (and, or, xor, split) needs ShapeRoi's geometry and
// drawing their outlines needs Roi.drawPixels, so those run in ImageJ.

import Foundation
import MancoraCommands
import MancoraCore
import MancoraIO
import MancoraProcess

extension Functions {
    /// Whether `roiManager(cmd)` (lowercased, as ImageJ compares it) runs natively.
    static func isNativeRoiManagerCommand(_ cmd: String) -> Bool {
        let native: Set<String> = [
            "open", "save", "save selected", "rename", "associate", "centered", "usenames", "add", "select", "count",
            "size", "index", "translate", "reset", "delete", "deselect", "measure", "update", "update2", "show all",
            "show none", "show all with labels", "show all without labels", "sort", "set color", "set fill color",
            "set line width", "remove channel info", "remove slice info", "remove frame info", "fill", "debug",
            "enable interrupts",
        ]
        if native.contains(cmd) || javaStartsWith(cmd, "multi measure") { return true }
        // "multi-measure" with " one" (a row per slice); without it ImageJ's Analyzer rows.
        if javaStartsWith(cmd, "multi-measure") { return javaContains(cmd, " one") }
        // RoiManager.runCommand deselects for any other command with "all" in it.
        return javaContains(cmd, "all") && !["add & draw", "multi plot"].contains(cmd)
    }

    /// `getIndexes()`: the selected entries, or all of them when none is.
    private func roiManagerIndexes() -> [Int] {
        let rm = session.roiManager
        return rm.selected.isEmpty ? Array(rm.entries.indices) : rm.selected
    }

    func roiManager() throws(MacroSignal) -> Double {
        let cmd = try getFirstString().lowercased()
        var path: String?
        var color: String?
        var lineWidth = 1.0
        var index = 0
        var dx = 0.0, dy = 0.0
        var countOrIndex = Double.nan
        let twoArgCommand = ["open", "save", "rename", "set color", "set fill color", "set line width", "associate",
            "centered", "usenames", "save selected"].contains(cmd)
        let select = cmd == "select"
        var multiSelect = false
        let add = cmd == "add"
        if twoArgCommand {
            path = try getLastString()
        } else if add {
            if interp.nextToken() == ch(",") {
                try interp.getComma()
                color = try interp.getString()
            }
            if interp.nextToken() == ch(",") {
                try interp.getComma()
                lineWidth = try interp.getExpression()
            }
            try interp.getRightParen()
        } else if select {
            try interp.getComma()
            multiSelect = isArrayArg()
            if !multiSelect {
                index = jIntI(try interp.getExpression())
                try interp.getRightParen()
            }
        } else if cmd == "translate" {
            dx = try getNextArg()
            dy = try getLastArg()
        } else {
            try interp.getRightParen()
        }
        var rm = session.roiManager
        defer { session.roiManager = rm }
        if multiSelect {
            let indexes = try getNumericArray().map { jIntI($0) }
            try interp.getRightParen()
            for i in indexes where i < 0 || i >= rm.count { try interp.fail("Invalid index: \(i)") }
            rm.selected = indexes
            if indexes.count == 1 { try setSelection(rm.entries[indexes[0]].roi) }
            return .nan
        }
        switch cmd {
        case "open":
            session.roiManager = rm
            try roiManagerOpen(path!)
            rm = session.roiManager
        case "save", "save selected":
            try roiManagerSave(rm, to: path!, selected: cmd == "save selected")
        case "rename":
            guard let i = rm.selected.first else { try interp.fail("Exactly one item in the list must be selected.") }
            rm.entries[i].name = path!
            rm.entries[i].roi.name = path!
        case "add":
            let open = try image()
            guard var roi = open.roi else { try interp.fail("The active image does not have a selection.") }
            if open.image.stack.count > 1 && roi.position == .none {
                let d = open.image.dimensions
                roi.position = open.isHyperstackPosition ? .hyperstack(channel: d.channels > 1 ? open.channel + 1 : 0,
                    slice: d.slices > 1 ? open.slice + 1 : 0, frame: d.frames > 1 ? open.frame + 1 : 0) : .stack(open.currentSliceNumber)
            }
            // The manager names the ROI with its label.
            let name = roi.name ?? Self.roiManagerLabel(open, roi)
            roi.name = name
            // runCommand("Add", color, lineWidth): a color (cyan if unreadable) and a width above 1 apply to the copy.
            var width = Int(Int32(truncatingIfNeeded: javaMathRound(lineWidth)))
            if width > 100 { width = 1 }
            if width > 1 {
                roi.strokeWidth = Float(width)
                roi.scalesStrokeWidth = true
            }
            if let color { roi.strokeColor = Self.decodeColor(color, 0xFF00_FFFF) }
            rm.entries.append(.init(name: name, roi: roi))
        case "select":
            try checkIndex(index, 0, rm.count - 1)
            rm.selected = [index]
            let entry = rm.entries[index]
            try selectRoiPosition(entry.roi)
            try setSelection(entry.roi)
        case "count", "size":
            countOrIndex = Double(rm.count)
        case "index":
            countOrIndex = Double(rm.selected.first ?? -1)
        case "translate":
            let targets = rm.selected.isEmpty ? Array(rm.entries.indices) : rm.selected
            for i in targets { rm.entries[i].roi = Self.translated(rm.entries[i].roi, dx: dx, dy: dy) }
            return .nan
        case "reset":
            rm = RoiManagerList()
        case "delete":
            if rm.selected.isEmpty {
                rm = RoiManagerList()
            } else {
                let remove = Set(rm.selected)
                rm.entries = rm.entries.enumerated().filter { !remove.contains($0.offset) }.map(\.element)
                rm.selected = []
            }
        case "measure":
            session.roiManager = rm
            try roiManagerMeasure()
        case "update", "update2":
            guard let i = rm.selected.first, let roi = try image().roi else { break }
            rm.entries[i].roi = roi
        case "set color", "set fill color", "set line width":
            session.roiManager = rm
            let value = path!
            switch cmd {
            case "set color": try setRoiProperties(color: Self.decodeColor(value, 0xFF00_FFFF), lineWidth: -1, fill: nil)
            case "set fill color": try setRoiProperties(color: nil, lineWidth: -1, fill: Self.decodeColor(value, 0xFF00_FFFF))
            default: try setRoiProperties(color: nil, lineWidth: jIntI(toolsParseDouble(value, 0)), fill: nil)
            }
            rm = session.roiManager
        case "remove channel info", "remove slice info", "remove frame info":
            session.roiManager = rm
            removePositions(channels: cmd == "remove channel info", frames: cmd == "remove frame info")
            rm = session.roiManager
        case "fill":
            session.roiManager = rm
            try roiManagerFill()
        case _ where javaStartsWith(cmd, "multi measure") || javaStartsWith(cmd, "multi-measure"):
            session.roiManager = rm
            try multiMeasure(cmd)
            rm = session.roiManager
        case "show all", "show none", "show all with labels", "show all without labels", "usenames", "associate",
            "centered", "sort", "debug", "enable interrupts":
            if cmd == "sort" { rm.entries.sort { javaCompare($0.name, $1.name) < 0 } }
        case _ where cmd == "deselect" || javaContains(cmd, "all"):
            // RoiManager.deselect(): the list's selection only.
            rm.selected = []
        default:
            try unsupported("roiManager(\"\(cmd)\")")
        }
        return countOrIndex
    }

    /// Opens a `.roi` file or a `RoiSet.zip` into the ROI Manager.
    func roiManagerOpen(_ path: String) throws(MacroSignal) {
        do {
            if path.lowercased().hasSuffix(".zip") {
                for entry in try RoiSet.read(path: path) {
                    session.roiManager.entries.append(.init(name: entry.name, roi: entry.roi))
                }
            } else {
                let roi = try RoiCodec.read(path: path)
                let name = roi.name ?? (Self.javaFileName(path) as NSString).deletingPathExtension
                session.roiManager.entries.append(.init(name: name, roi: roi))
            }
        } catch {
            try interp.fail("\(error)")
        }
    }

    /// `RoiManager.save`: one ROI to a ".roi" path, else a ".zip" of all (or the selected) entries.
    private func roiManagerSave(_ rm: RoiManagerList, to path: String, selected: Bool) throws(MacroSignal) {
        let indexes = rm.selected.isEmpty ? Array(rm.entries.indices) : rm.selected
        do {
            if javaEndsWith(path, ".roi") {
                guard let first = indexes.first else { try interp.fail("The list is empty") }
                try Data(RoiCodec.encode(rm.entries[first].roi)).write(to: URL(fileURLWithPath: path))
                return
            }
            if !javaEndsWith(path, ".zip") && !path.isEmpty { try interp.fail("Name must end with '.zip'") }
            if path.isEmpty { try unsupported("roiManager(\"save\") with a save dialog") }
            if rm.count == 0 { try interp.fail("The list is empty") }
            let entries = (selected ? indexes : Array(rm.entries.indices)).map {
                RoiSet.Entry(name: rm.entries[$0].name, roi: rm.entries[$0].roi)
            }
            try Data(RoiSet.encode(entries)).write(to: URL(fileURLWithPath: path))
        } catch let signal as MacroSignal {
            throw signal
        } catch {
            try interp.fail("\(error)")
        }
    }

    /// `RoiManager.measure`: each selected ROI (all of them when none is), on its own plane.
    private func roiManagerMeasure() throws(MacroSignal) {
        let rm = session.roiManager
        let indexes = rm.selected.isEmpty ? Array(rm.entries.indices) : rm.selected
        if indexes.isEmpty { try interp.fail("The ROI Manager is empty") }
        let original = try image()
        for i in indexes {
            let roi = rm.entries[i].roi
            try selectRoiPosition(roi)
            try setSelection(roi)
            try runCommand("Measure", options: nil)
        }
        try modifyImage { open in
            (open.channel, open.slice, open.frame) = (original.channel, original.slice, original.frame)
            open.roi = original.roi
        }
    }

    /// `RoiManager.setProperties(color, lineWidth, fillColor)` without its
    /// dialog: every entry (or the selected ones) takes the stroke color and
    /// width given, and the fill color, cleared when none is given; the
    /// image's selection takes the ones given.
    private func setRoiProperties(color: UInt32?, lineWidth: Int, fill: UInt32?) throws(MacroSignal) {
        let indexes = roiManagerIndexes()
        if indexes.isEmpty { return }
        func apply(_ roi: inout Roi, clearingFill: Bool) {
            if let color { roi.strokeColor = color }
            if lineWidth >= 0 {
                roi.strokeWidth = Float(lineWidth)
                if lineWidth > 0 { roi.scalesStrokeWidth = true }
            }
            if fill != nil || clearingFill {
                roi.fillColor = fill
                if fill != nil && roi.isArea { roi.strokeColor = nil }
            }
        }
        for i in indexes { apply(&session.roiManager.entries[i].roi, clearingFill: true) }
        if var roi = session.context.current?.roi {
            apply(&roi, clearingFill: false)
            try setSelection(roi)
        }
    }

    /// `RoiManager.getSliceNumber(label)`: the slice in a "ssss-yyyy-xxxx" label, or -1.
    static func sliceNumber(inLabel label: String) -> Int {
        let chars = Array(label.utf16)
        func dash(_ i: Int) -> Bool { i < chars.count && chars[i] == 0x2D }
        var digits = 0
        if chars.count >= 14 && dash(4) && dash(9) {
            digits = 4
        } else if chars.count >= 17 && dash(5) && dash(11) {
            digits = 5
        } else if chars.count >= 20 && dash(6) && dash(13) {
            digits = 6
        } else {
            return -1
        }
        let n = toolsParseDouble(javaSubstring(label, 0, digits), -1)
        return jIntI(n)
    }

    /// `RoiManager.removePositions`: drops the slice from the labels and the
    /// chosen parts of each entry's position.
    private func removePositions(channels: Bool, frames: Bool) {
        let slices = !(channels || frames)
        for i in roiManagerIndexes() {
            var entry = session.roiManager.entries[i]
            if Self.sliceNumber(inLabel: entry.name) > 0 {
                entry.name = javaSubstring(entry.name, 5)
                entry.roi.name = entry.name
            }
            switch entry.roi.position {
            case .hyperstack(var c, var z, var t):
                if channels { c = 0 }
                if slices { z = 0 }
                if frames { t = 0 }
                entry.roi.position = .hyperstack(channel: c, slice: z, frame: t)
            case .stack where slices:
                entry.roi.position = .none
            default:
                break
            }
            session.roiManager.entries[i] = entry
        }
    }

    /// `RoiManager.drawOrFill(FILL)`: fills each area ROI with the
    /// foreground color, on its own slice, and removes the selection.
    private func roiManagerFill() throws(MacroSignal) {
        try setSelection(nil)
        for i in roiManagerIndexes() {
            let entry = session.roiManager.entries[i]
            guard entry.roi.isArea else { try unsupported("roiManager(\"fill\") of a line") }
            var slice = 0
            if case .stack(let n) = entry.roi.position { slice = n }
            if slice <= 0 { slice = Self.sliceNumber(inLabel: entry.name) }
            let open = try image()
            if slice >= 1 && slice <= open.image.stack.count {
                try modifyImage { open in
                    let p = open.image.dimensions.position(ofPlane: slice - 1)
                    (open.channel, open.slice, open.frame) = (p.channel, p.slice, p.frame)
                }
            }
            let current = try image()
            let width = current.image.width, height = current.image.height
            let region: MeasurementRegion
            do { region = try entry.roi.measurementRegion(width: width, height: height) } catch { try interp.fail("\(error)") }
            let value = EditCommands.fillValue(color: session.foreground, for: current)
            try modifyCurrentPlane { plane, _, _ in
                for y in max(region.y, 0)..<max(max(region.y, 0), min(region.y + region.height, height)) {
                    for x in max(region.x, 0)..<max(max(region.x, 0), min(region.x + region.width, width)) where region.contains(x, y) {
                        EditCommands.putFill(&plane, y * width + x, value)
                    }
                }
            }
        }
    }

    /// `RoiManager.multiMeasure` with a row per slice: a new Results table
    /// whose columns are each measurement of each ROI ("Mean1", "Mean(name)").
    private func multiMeasure(_ cmd: String) throws(MacroSignal) {
        let rois = roiManagerIndexes().map { session.roiManager.entries[$0].roi }
        if rois.isEmpty { try interp.fail("Multi-measure: no selection") }
        let original = try image()
        var nSlices = original.image.stack.count
        var measureAll = nSlices > 1
        var append = javaContains(cmd, "append")
        if javaStartsWith(cmd, "multi-measure") {
            measureAll = javaContains(cmd, " measure") && nSlices > 1
            append = javaContains(cmd, " append")
        }
        if append { try unsupported("roiManager(\"multi-measure append\")") }
        if javaStartsWith(cmd, "multi-measure") && !javaContains(cmd, " one") {
            try unsupported("roiManager(\"multi-measure\") without \"one\"")
        }
        if !measureAll { nSlices = 1 }
        var multi = ResultsTable.custom()
        session.context.results.reset()
        let labels = session.context.settings.measurements.contains(.labels)
        for slice in 1...nSlices {
            let plane = nSlices == 1 ? original.stackIndex : slice - 1
            try modifyImage { open in
                let p = open.image.dimensions.position(ofPlane: plane)
                (open.channel, open.slice, open.frame) = (p.channel, p.slice, p.frame)
            }
            let row = multi.addRow()
            if labels { multi.setLabel(original.image.title, row: row) }
            for (k, roi) in rois.enumerated() {
                try setSelection(roi)
                try runCommand("Measure", options: nil)
                let rt = session.context.results
                var suffix = String(k + 1)
                if let name = roi.name, !name.isEmpty,
                    name.utf16.count < 9 || !(name.unicodeScalars.first.map { ("0"..."9").contains($0) } ?? false)
                {
                    suffix = "(" + name + ")"
                }
                // Analyzer's float columns.
                for column in rt.columns where column != "Slice" {
                    multi.set(column + suffix, row: row, Double(Float(rt.number(column, row: rt.count - 1))))
                }
            }
        }
        session.context.results = multi
        try modifyImage { open in (open.channel, open.slice, open.frame) = (original.channel, original.slice, original.frame) }
        if rois.count > 1 { try setSelection(nil) }
    }

    /// Moves to a ROI's stack position, as selecting it in the ROI Manager does.
    private func selectRoiPosition(_ roi: Roi) throws(MacroSignal) {
        try modifyImage { open in
            let d = open.image.dimensions
            switch roi.position {
            case .none: break
            case .stack(let n):
                guard n >= 1 && n <= open.image.stack.count else { break }
                let p = d.position(ofPlane: n - 1)
                (open.channel, open.slice, open.frame) = (p.channel, p.slice, p.frame)
            case .hyperstack(let c, let z, let t):
                if c > 0 { open.channel = min(c, d.channels) - 1 }
                if z > 0 { open.slice = min(z, d.slices) - 1 }
                if t > 0 { open.frame = min(t, d.frames) - 1 }
            }
        }
    }

    /// `RoiManager.getLabel`: "yyyy-xxxx" from the selection's center, with the slice first for stacks.
    static func roiManagerLabel(_ open: OpenImage, _ roi: Roi) -> String {
        let r = roi.bounds
        var xc = r.x + r.width / 2
        var yc = r.y + r.height / 2
        if xc < 0 { xc = 0 }
        if yc < 0 { yc = 0 }
        var digits = 4
        digits = max(digits, String(xc).count, String(yc).count)
        if digits == 4 && (open.image.stack.count >= 10000 || open.image.height >= 10000) { digits = 5 }
        func padded(_ n: Int) -> String {
            let s = "000000" + String(n)
            return String(s.suffix(digits))
        }
        var label = padded(yc) + "-" + padded(xc)
        if open.image.stack.count > 1 { label = padded(open.currentSliceNumber) + "-" + label }
        return label
    }

    // MARK: - RoiManager.*

    func doRoiManager() throws(MacroSignal) -> Variable? {
        let name = try memberName()
        switch name {
        case "associateROIsWithSlices", "restoreCentered", "useNamesAsLabels":
            // How the manager shows and restores ROIs; nothing is shown here.
            _ = try getBooleanArg()
        case "size":
            try interp.getParens()
            return Variable(Double(session.roiManager.count))
        case "selected":
            try interp.getParens()
            return Variable(Double(session.roiManager.selected.count))
        case "getName":
            let i = jIntI(try getArg())
            try checkIndex(i, 0, session.roiManager.count - 1)
            return Variable(session.roiManager.entries[i].name)
        case "getIndex":
            let label = try getStringArg()
            return Variable(Double(session.roiManager.entries.firstIndex { $0.name == label } ?? -1))
        case "select", "selectByName":
            let i: Int
            if name == "select" {
                i = jIntI(try getArg())
                try checkIndex(i, 0, session.roiManager.count - 1)
            } else {
                let label = try getStringArg()
                i = session.roiManager.entries.firstIndex { $0.name == label } ?? -1
            }
            // RoiManager.select(-1) only deselects.
            session.roiManager.selected = i < 0 ? [] : [i]
            guard i >= 0 else { return nil }
            try selectRoiPosition(session.roiManager.entries[i].roi)
            try setSelection(session.roiManager.entries[i].roi)
        case "selectGroup":
            let group = jIntI(try getArg())
            session.roiManager.selected = session.roiManager.entries.indices.filter { session.roiManager.entries[$0].roi.group == group }
        case "selectPosition":
            let c = jIntI(try getFirstArg())
            let z = jIntI(try getNextArg())
            let t = jIntI(try getLastArg())
            session.roiManager.selected = session.roiManager.entries.indices.filter { i in
                let (c2, z2, t2) = Self.cztPosition(session.roiManager.entries[i].roi)
                return (c != 0 && c == c2) || (z != 0 && z == z2) || (t != 0 && t == t2)
            }
        case "setPosition":
            let channel = jIntI(try getFirstArg())
            var position: Roi.Position
            if interp.nextToken() == ch(")") {
                try interp.getRightParen()
                position = channel <= 0 ? .none : .stack(channel)
            } else {
                let slice = jIntI(try getNextArg())
                let frame = jIntI(try getLastArg())
                position = .hyperstack(channel: max(channel, 0), slice: max(slice, 0), frame: max(frame, 0))
            }
            for i in roiManagerIndexes() { session.roiManager.entries[i].roi.position = position }
        case "translate":
            let dx = try getFirstArg()
            let dy = try getLastArg()
            let rm = session.roiManager
            for i in rm.selected.isEmpty ? Array(rm.entries.indices) : rm.selected {
                session.roiManager.entries[i].roi = Self.translated(rm.entries[i].roi, dx: dx, dy: dy)
            }
        case "delete":
            let i = jIntI(try getArg())
            if i >= 0 && i < session.roiManager.count {
                session.roiManager.entries.remove(at: i)
                session.roiManager.selected = session.roiManager.selected.compactMap { $0 == i ? nil : $0 > i ? $0 - 1 : $0 }
            }
        case "setGroup", "multiCrop", "scale", "rotate":
            try unsupported("RoiManager." + name)
        default:
            try interp.error("Unrecognized RoiManager function")
        }
        return nil
    }

    /// `getCPosition()`, `getZPosition()` (the stack position without a hyperstack one) and `getTPosition()`.
    static func cztPosition(_ roi: Roi) -> (Int, Int, Int) {
        switch roi.position {
        case .none: (0, 0, 0)
        case .stack(let n): (0, n, 0)
        case .hyperstack(let c, let z, let t): (c, z, t)
        }
    }
}
