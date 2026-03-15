#!/usr/bin/env python3
"""
Parse Doxygen XML output from Qt6 headers and generate:
  1. module.modulemap  - Swift module map so Swift can import Qt6
  2. qt6-api-summary.json - JSON summary of all extracted Qt6 classes/enums

Following Swift's guide on wrapping C/C++ libraries:
https://www.swift.org/documentation/articles/wrapping-c-cpp-library-in-swift.html

Usage:
    python3 parse_doxygen_xml.py \\
        --xml-dir <doxygen-xml-output> \\
        --qt6-include-dir <path/to/qt6> \\
        --qt6-version <version> \\
        --output-dir <Sources/CQt6Widgets>
"""

import argparse
import json
import os
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path


# Qt6 modules that are part of the public API exposed to Swift.
# Excludes internal platform-integration modules (EglFs, Kms, Fb, Input, etc.).
PUBLIC_QT6_MODULES = [
    "QtCore",
    "QtGui",
    "QtWidgets",
    "QtNetwork",
    "QtSql",
    "QtXml",
    "QtDBus",
    "QtTest",
    "QtConcurrent",
    "QtOpenGL",
    "QtOpenGLWidgets",
    "QtPrintSupport",
]


def get_text(element) -> str:
    """Return all text inside an XML element, stripping leading/trailing whitespace."""
    if element is None:
        return ""
    return "".join(element.itertext()).strip()


def qt_module_from_path(header_path: str, qt6_include_dir: str) -> str:
    """Derive the Qt module name from a header file path."""
    if not header_path:
        return "QtCore"
    try:
        rel = Path(header_path).relative_to(qt6_include_dir)
        first = rel.parts[0] if rel.parts else ""
        if first.startswith("Qt"):
            return first
    except ValueError:
        pass
    # Fall back to scanning the path string
    for mod in PUBLIC_QT6_MODULES:
        if mod in header_path:
            return mod
    return "QtCore"


def parse_params(member_el) -> list:
    """Extract a list of {type, name} dicts from a <memberdef> element."""
    params = []
    for param in member_el.findall("param"):
        ptype = get_text(param.find("type"))
        pname = get_text(param.find("declname"))
        if ptype or pname:
            params.append({"type": ptype, "name": pname})
    return params


def parse_enum_values(member_el) -> list:
    """Extract enum values from a <memberdef kind='enum'> element."""
    values = []
    for ev in member_el.findall("enumvalue"):
        name = get_text(ev.find("name"))
        initializer = get_text(ev.find("initializer"))
        entry = {"name": name}
        if initializer:
            entry["value"] = initializer
        values.append(entry)
    return values


def parse_compound(compound_file: Path, qt6_include_dir: str) -> dict | None:
    """
    Parse a single Doxygen compound XML file (class/struct).

    Returns a dict describing the class or None if the file should be skipped.
    """
    try:
        tree = ET.parse(compound_file)
    except ET.ParseError:
        return None

    root = tree.getroot()
    cd = root.find("compounddef")
    if cd is None:
        return None

    kind = cd.get("kind", "")
    if kind not in ("class", "struct"):
        return None

    name = get_text(cd.find("compoundname"))
    if not name:
        return None

    # Only keep public Qt classes (start with Q but not Q_)
    if not (name.startswith("Q") and not name.startswith("Q_")):
        return None

    location = cd.find("location")
    header_path = location.get("file", "") if location is not None else ""
    qt_module = qt_module_from_path(header_path, qt6_include_dir)

    # Base classes
    bases = [get_text(b) for b in cd.findall("basecompoundref") if get_text(b)]

    methods = []
    properties = []
    enums = []

    for section in cd.findall("sectiondef"):
        for member in section.findall("memberdef"):
            member_kind = member.get("kind", "")
            member_name = get_text(member.find("name"))
            if not member_name:
                continue

            if member_kind in ("function", "slot", "signal"):
                methods.append(
                    {
                        "name": member_name,
                        "kind": member_kind,
                        "return_type": get_text(member.find("type")),
                        "params": parse_params(member),
                    }
                )
            elif member_kind == "property":
                properties.append(
                    {
                        "name": member_name,
                        "type": get_text(member.find("type")),
                    }
                )
            elif member_kind == "enum":
                enums.append(
                    {
                        "name": member_name,
                        "values": parse_enum_values(member),
                    }
                )

    entry = {
        "name": name,
        "kind": kind,
        "module": qt_module,
        "header": header_path,
    }
    if bases:
        entry["bases"] = bases
    if methods:
        entry["methods"] = methods
    if properties:
        entry["properties"] = properties
    if enums:
        entry["enums"] = enums

    return entry


def parse_all_compounds(xml_dir: str, qt6_include_dir: str) -> list:
    """Parse all compound XML files listed in Doxygen's index.xml."""
    xml_path = Path(xml_dir)
    index_file = xml_path / "index.xml"

    if not index_file.exists():
        print(f"ERROR: index.xml not found in {xml_dir}", file=sys.stderr)
        sys.exit(1)

    try:
        index_tree = ET.parse(index_file)
    except ET.ParseError as exc:
        print(f"ERROR: Could not parse index.xml: {exc}", file=sys.stderr)
        sys.exit(1)

    index_root = index_tree.getroot()
    classes = []

    for compound in index_root.findall("compound"):
        if compound.get("kind") not in ("class", "struct"):
            continue
        refid = compound.get("refid", "")
        if not refid:
            continue
        compound_file = xml_path / f"{refid}.xml"
        if not compound_file.exists():
            continue
        entry = parse_compound(compound_file, qt6_include_dir)
        if entry is not None:
            classes.append(entry)

    return classes


def find_public_modules(qt6_include_dir: str) -> list:
    """
    Return info about each public Qt6 module that has an umbrella header
    and is present in the include directory.
    """
    base = Path(qt6_include_dir)
    result = []
    for mod_name in PUBLIC_QT6_MODULES:
        mod_dir = base / mod_name
        umbrella = mod_dir / mod_name
        if mod_dir.is_dir() and umbrella.exists():
            result.append(
                {
                    "name": mod_name,
                    "path": str(mod_dir),
                    "umbrella_header": str(umbrella),
                }
            )
    return result


def generate_module_map(modules: list, qt6_version: str) -> str:
    """
    Generate a Swift module.modulemap for the supplied Qt6 modules.

    Each Qt6 module becomes a Swift module named C<Qt6Module>
    (e.g. QtCore -> CQt6Core, QtWidgets -> CQt6Widgets).

    The [system] attribute suppresses warnings from Qt headers.
    The `requires cplusplus` attribute enables Swift's C++ interoperability
    (Swift 5.9+, see SE-0384).

    Ref: https://www.swift.org/documentation/articles/wrapping-c-cpp-library-in-swift.html
    """
    lines = [
        f"// Swift module map for Qt6 {qt6_version}",
        "// Generated by scripts/generate_qt6_swift_module.sh",
        "//",
        "// This file exposes each public Qt6 C++ module as a Swift module so that",
        "// Swift source files can write `import CQt6Widgets` etc.",
        "//",
        "// Swift C++ interoperability (SE-0384, Swift 5.9+) allows direct use of",
        "// Qt6 C++ classes from Swift via these module declarations.",
        "//",
        "// Reference: https://www.swift.org/documentation/articles/wrapping-c-cpp-library-in-swift.html",
        "",
    ]

    for mod in modules:
        swift_name = mod["name"].replace("Qt", "CQt6", 1)
        umbrella = mod["umbrella_header"]
        lines += [
            f"module {swift_name} [system] {{",
            "    requires cplusplus",
            f'    header "{umbrella}"',
            "    export *",
            "}",
            "",
        ]

    return "\n".join(lines)


def build_api_summary(classes: list, modules: list, qt6_version: str) -> dict:
    """Build a structured JSON summary of the extracted Qt6 API."""
    by_module = defaultdict(list)
    for cls in classes:
        by_module[cls["module"]].append(cls["name"])

    module_stats = {}
    for mod in modules:
        name = mod["name"]
        cls_list = sorted(by_module.get(name, []))
        module_stats[name] = {
            "class_count": len(cls_list),
            "classes": cls_list,
            "umbrella_header": mod["umbrella_header"],
        }

    return {
        "qt6_version": qt6_version,
        "total_classes": len(classes),
        "modules": module_stats,
        "classes": classes,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Parse Doxygen XML from Qt6 headers and generate a Swift module map."
    )
    parser.add_argument(
        "--xml-dir",
        required=True,
        help="Directory containing Doxygen XML output (must contain index.xml).",
    )
    parser.add_argument(
        "--qt6-include-dir",
        required=True,
        help="Root Qt6 include directory (e.g. /usr/include/x86_64-linux-gnu/qt6).",
    )
    parser.add_argument(
        "--qt6-version",
        required=True,
        help="Qt6 version string (e.g. 6.4.2).",
    )
    parser.add_argument(
        "--module-map-out",
        required=True,
        help="Output path for the generated module.modulemap file.",
    )
    parser.add_argument(
        "--summary-out",
        required=True,
        help="Output path for the qt6-api-summary.json file.",
    )
    args = parser.parse_args()

    map_path = Path(args.module_map_out)
    summary_path = Path(args.summary_out)
    map_path.parent.mkdir(parents=True, exist_ok=True)
    summary_path.parent.mkdir(parents=True, exist_ok=True)

    print(f"[parse_doxygen_xml] Qt6 include dir : {args.qt6_include_dir}")
    print(f"[parse_doxygen_xml] Doxygen XML dir  : {args.xml_dir}")
    print(f"[parse_doxygen_xml] module.modulemap : {map_path}")
    print(f"[parse_doxygen_xml] API summary      : {summary_path}")

    # 1. Find available public Qt6 modules
    modules = find_public_modules(args.qt6_include_dir)
    if not modules:
        print("ERROR: No public Qt6 modules found. Check --qt6-include-dir.", file=sys.stderr)
        sys.exit(1)
    print(f"[parse_doxygen_xml] Found {len(modules)} public Qt6 modules: "
          f"{', '.join(m['name'] for m in modules)}")

    # 2. Parse all Doxygen compound XML files
    print("[parse_doxygen_xml] Parsing Doxygen XML...")
    classes = parse_all_compounds(args.xml_dir, args.qt6_include_dir)
    print(f"[parse_doxygen_xml] Extracted {len(classes)} Qt classes/structs")

    # 3. Generate module.modulemap
    module_map = generate_module_map(modules, args.qt6_version)
    map_path.write_text(module_map, encoding="utf-8")
    print(f"[parse_doxygen_xml] Wrote {map_path}")

    # 4. Generate JSON API summary (build artifact, not committed to repo)
    summary = build_api_summary(classes, modules, args.qt6_version)
    summary_path.write_text(
        json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    print(f"[parse_doxygen_xml] Wrote {summary_path}")
    print(
        f"[parse_doxygen_xml] Summary: {summary['total_classes']} classes across "
        f"{len(modules)} modules"
    )


if __name__ == "__main__":
    main()
