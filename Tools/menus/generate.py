#!/usr/bin/env python3
"""Writes Resources/Bridge/imagej-menus.tsv: ImageJ 1.54p's menu bar, as
ij.Menus builds it from IJ_Props.txt.

Each line is  <menu path> TAB <command> TAB <shortcut>, where the path is
like "Image>Adjust", the command is the menu item's command name ("-" for
a separator, ">Name" for a submenu), and the shortcut is ImageJ's key: a
lowercase letter means Ctrl/Cmd, uppercase adds Shift.

Usage: Tools/menus/generate.py <IJ_Props.txt> > Resources/Bridge/imagej-menus.tsv
"""
import re
import sys

props = {}
for line in open(sys.argv[1], encoding="latin-1"):
    line = line.rstrip("\n")
    if "=" in line and not line.startswith("#"):
        key, value = line.split("=", 1)
        props[key.strip()] = value.strip(" \t\r")

out = []


def emit(path, command, shortcut=""):
    out.append(f"{path}\t{command}\t{shortcut}")


def parse_item(value):
    """`"Label[s]",class` -> (command, shortcut), as Menus.addPluginItem reads
    it: a final [letter] or [digit] is a shortcut and leaves the name (a
    space before it stays: "Install... [M]" is the command "Install... ");
    other brackets ("In [+]", "Next Slice [>]") are part of the name."""
    m = re.match(r'"(.*)"\s*,', value)
    label = (m.group(1) if m else value.strip('"')).replace("\\\\", "\\")
    shortcut = ""
    if label.endswith("]") and label.rfind("[") > 0:
        bracket = label.rfind("[")
        key = label[bracket + 1:-1]
        if len(key) == 1 and key.isalnum():
            label, shortcut = label[:bracket], key
    return label, shortcut


def submenu(parent, name, key=None):
    """Menus.addSubMenu: items <key>01, <key>02, ... from IJ_Props."""
    key = key or name.lower().split(" ")[0]
    path = f"{parent}>{name.replace('_', ' ').strip()}"
    emit(parent, ">" + name.replace("_", " ").strip())
    for n in range(1, 100):
        value = props.get(f"{key}{n:02d}")
        if value is None:
            break
        if value == "-":
            emit(path, "-")
        elif value.startswith(">"):
            sub = value[2:-1]
            submenu(path, sub)
        else:
            emit(path, *parse_item(value))
    return path


def item(path, command, shortcut=""):
    emit(path, command, shortcut)


def sep(path):
    emit(path, "-")


# File (Menus.java, addMenuBar)
submenu("File", "New")
item("File", "Open...", "o")
item("File", "Open Next", "O")
submenu("File", "Open Samples", "open")
emit("File", ">Open Recent")
submenu("File", "Import")
sep("File")
item("File", "Close", "w")
item("File", "Close All", "W")
item("File", "Save", "s")
submenu("File", "Save As", "save")
item("File", "Revert", "R")
sep("File")
item("File", "Page Setup...")
item("File", "Print...", "p")
sep("File")
item("File", "Quit")

# Edit
item("Edit", "Undo", "z")
sep("Edit")
for command, key in [("Cut", "x"), ("Copy", "c"), ("Copy to System", ""), ("Paste", "v"), ("Paste Control...", "")]:
    item("Edit", command, key)
sep("Edit")
for command, key in [("Clear", ""), ("Clear Outside", ""), ("Fill", "f"), ("Draw", "d"), ("Invert", "I")]:
    item("Edit", command, key)
sep("Edit")
submenu("Edit", "Selection")
submenu("Edit", "Options")

# Image
emit("Image", ">Type")
for command in ["8-bit", "16-bit", "32-bit", "8-bit Color", "RGB Color", "-", "RGB Stack", "HSB Stack", "HSB (32-bit)", "Lab Stack"]:
    emit("Image>Type", command)
sep("Image")
submenu("Image", "Adjust")
item("Image", "Show Info...", "i")
item("Image", "Properties...", "P")
submenu("Image", "Color")
stacks = submenu("Image", "Stacks")
submenu(stacks, "Animation_", "animation_")
submenu(stacks, "Tools_", "tools_")
submenu("Image", "Hyperstacks")
sep("Image")
item("Image", "Crop", "X")
item("Image", "Duplicate...", "D")
item("Image", "Rename...")
item("Image", "Scale...", "e")
submenu("Image", "Transform")
submenu("Image", "Zoom")
submenu("Image", "Overlay")
sep("Image")
submenu("Image", "Lookup Tables", "lookup")

# Process
item("Process", "Smooth", "S")
item("Process", "Sharpen")
item("Process", "Find Edges")
item("Process", "Find Maxima...")
item("Process", "Enhance Contrast...")
for name in ["Noise", "Shadows", "Binary", "Math", "FFT", "Filters"]:
    submenu("Process", name)
sep("Process")
submenu("Process", "Batch")
item("Process", "Image Calculator...")
item("Process", "Subtract Background...")
item("Process", "Repeat Command", "R")

# Analyze
for command, key in [("Measure", "m"), ("Analyze Particles...", ""), ("Summarize", ""), ("Distribution...", ""),
                     ("Label", ""), ("Clear Results", ""), ("Set Measurements...", "")]:
    item("Analyze", command, key)
sep("Analyze")
item("Analyze", "Set Scale...")
item("Analyze", "Calibrate...")
item("Analyze", "Histogram", "h")
item("Analyze", "Plot Profile", "k")
item("Analyze", "Surface Plot...")
submenu("Analyze", "Gels")
submenu("Analyze", "Tools")

# Plugins (plug-inNN keys)
for n in range(1, 100):
    value = props.get(f"plug-in{n:02d}")
    if value is None:
        break
    if value == "-":
        sep("Plugins")
    elif value.startswith(">"):
        submenu("Plugins", value[2:-1])
    else:
        emit("Plugins", *parse_item(value))

# Window
for command in ["Show All", "Main Window [return]", "Put Behind [tab]", "Cascade", "Tile"]:
    item("Window", command)

# Help
item("Help", "ImageJ Website...")
sep("Help")
item("Help", "Dev. Resources...")
item("Help", "Macro Functions...")
sep("Help")
item("Help", "Release Notes...")
sep("Help")
submenu("Help", "About Plugins", "about")
item("Help", "About ImageJ...")

print("# ImageJ 1.54p's menus (Tools/menus/generate.py): path<TAB>command<TAB>shortcut")
print("\n".join(out))
