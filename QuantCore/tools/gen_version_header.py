#!/usr/bin/env python3
"""
ALXQuant Version Header Generator
Reads manifest.json and generates MQL5/Include/ALXQuantCore/Version.mqh
Single source of truth for all MQL5 component versions.
"""

import json
import sys
from pathlib import Path
from datetime import datetime, timezone


def parse_version(v: str) -> tuple:
    """Parse semantic version string to tuple (major, minor, patch)."""
    parts = v.split('.')
    major = int(parts[0]) if parts else 0
    minor = int(parts[1]) if len(parts) > 1 else 0
    patch = int(parts[2]) if len(parts) > 2 else 0
    return (major, minor, patch)


def format_version_mqh(v: str) -> str:
    """Format version for MQL5 #property (2 segments: major.minor)."""
    major, minor, _ = parse_version(v)
    return f"{major}.{minor:02d}"


def format_version_const(v: str) -> str:
    """Format version for MQL5 #define constant (3 segments)."""
    return v


def escape_cpp_string(s: str) -> str:
    """Escape string for C++ literal."""
    return s.replace('\\', '\\\\').replace('"', '\\"')


def generate_version_header(manifest_path: Path, output_path: Path) -> None:
    with open(manifest_path, 'r', encoding='utf-8') as f:
        manifest = json.load(f)

    platform_version = manifest['platform']
    components = manifest['components']
    contracts = manifest.get('contracts', {})

    # Sort components for stable output
    sorted_components = sorted(components.items(), key=lambda x: x[0])

    lines = []
    lines.append("//+------------------------------------------------------------------+")
    lines.append("//| Version.mqh — ALXQuant Platform Version & Compatibility        |")
    lines.append(f"//| Generated: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S')} UTC          |")
    lines.append(f"//| Platform: {platform_version:<45}|")
    lines.append("//| DO NOT EDIT MANUALLY — generated from manifest.json            |")
    lines.append("//+------------------------------------------------------------------+")
    lines.append("#property strict")
    lines.append(f"#property version \"{format_version_mqh(platform_version)}\"")
    lines.append("")
    lines.append("//--- Platform version (3 segments) ---")
    lines.append(f'#define ALX_PLATFORM_VERSION "{format_version_const(platform_version)}"')
    lines.append(f'#define ALX_PLATFORM_MAJOR {parse_version(platform_version)[0]}')
    lines.append(f'#define ALX_PLATFORM_MINOR {parse_version(platform_version)[1]}')
    lines.append(f'#define ALX_PLATFORM_PATCH {parse_version(platform_version)[2]}')
    lines.append("")
    lines.append("//--- Contract versions ---")
    for cname, cinfo in contracts.items():
        fv = cinfo.get('format_version', 0)
        lines.append(f'#define ALX_CONTRACT_{cname.upper()}_FORMAT_VERSION {fv}')
    lines.append("")
    lines.append("//--- Component versions ---")
    for cname, cinfo in sorted_components:
        const_name = cname.replace(':', '_').replace('-', '_').replace('.', '_').upper()
        ver = cinfo['version']
        lines.append(f'#define ALX_MODULE_{const_name}_VERSION "{format_version_const(ver)}"')
    lines.append("")
    lines.append("//--- Version compatibility checker ---")
    lines.append("class CVersionCheck")
    lines.append("{")
    lines.append("public:")
    lines.append("    // Parse version string 'X.Y.Z' -> (major, minor, patch)")
    lines.append("    static bool ParseVersion(const string &ver, int &major, int &minor, int &patch)")
    lines.append("    {")
    lines.append("        int p1 = StringFind(ver, \".\");")
    lines.append("        if(p1 < 0) return false;")
    lines.append("        int p2 = StringFind(ver, \".\", p1 + 1);")
    lines.append("        if(p2 < 0) p2 = StringLen(ver);")
    lines.append("        major = (int)StringToInteger(StringSubstr(ver, 0, p1));")
    lines.append("        minor = (int)StringToInteger(StringSubstr(ver, p1 + 1, p2 - p1 - 1));")
    lines.append("        if(p2 < StringLen(ver))")
    lines.append("            patch = (int)StringToInteger(StringSubstr(ver, p2 + 1));")
    lines.append("        else")
    lines.append("            patch = 0;")
    lines.append("        return true;")
    lines.append("    }")
    lines.append("")
    lines.append("    // Check if version satisfies range spec: '>=10.0.0,<11.0.0'")
    lines.append("    static bool CheckRange(const string &current_ver, const string &range_spec, const string &label)")
    lines.append("    {")
    lines.append("        int c_maj, c_min, c_pat;")
    lines.append("        if(!ParseVersion(current_ver, c_maj, c_min, c_pat))")
    lines.append("        {")
    lines.append("            Print(\"[VERSION] \", label, \": invalid current version format: \", current_ver);")
    lines.append("            return false;")
    lines.append("        }")
    lines.append("        // Split by comma for multiple constraints")
    lines.append("        string specs[];")
    lines.append("        int count = StringSplit(range_spec, ',', specs);")
    lines.append("        for(int i = 0; i < count; i++)")
    lines.append("        {")
    lines.append("            string spec = StringTrimLeft(StringTrimRight(specs[i]));")
    lines.append("            if(StringLen(spec) == 0) continue;")
    lines.append("            // Parse operator + version")
    lines.append("            string op = \"\";")
    lines.append("            string ver = \"\";")
    lines.append("            if(StringSubstr(spec, 0, 2) == \">=\") { op = \">=\"; ver = StringSubstr(spec, 2); }")
    lines.append("            else if(StringSubstr(spec, 0, 2) == \"<=\") { op = \"<=\"; ver = StringSubstr(spec, 2); }")
    lines.append("            else if(StringSubstr(spec, 0, 1) == \">\") { op = \">\"; ver = StringSubstr(spec, 1); }")
    lines.append("            else if(StringSubstr(spec, 0, 1) == \"<\") { op = \"<\"; ver = StringSubstr(spec, 1); }")
    lines.append("            else if(StringSubstr(spec, 0, 1) == \"=\") { op = \"==\"; ver = StringSubstr(spec, 1); }")
    lines.append("            else { op = \"==\"; ver = spec; }")
    lines.append("            int r_maj, r_min, r_pat;")
    lines.append("            if(!ParseVersion(ver, r_maj, r_min, r_pat))")
    lines.append("            {")
    lines.append("                Print(\"[VERSION] \", label, \": invalid range spec: \", spec);")
    lines.append("                return false;")
    lines.append("            }")
    lines.append("            bool ok = false;")
    lines.append("            if(op == \">=\") ok = (c_maj > r_maj) || (c_maj == r_maj && c_min > r_min) || (c_maj == r_maj && c_min == r_min && c_pat >= r_pat);")
    lines.append("            else if(op == \">\") ok = (c_maj > r_maj) || (c_maj == r_maj && c_min > r_min) || (c_maj == r_maj && c_min == r_min && c_pat > r_pat);")
    lines.append("            else if(op == \"<=\") ok = (c_maj < r_maj) || (c_maj == r_maj && c_min < r_min) || (c_maj == r_maj && c_min == r_min && c_pat <= r_pat);")
    lines.append("            else if(op == \"<\") ok = (c_maj < r_maj) || (c_maj == r_maj && c_min < r_min) || (c_maj == r_maj && c_min == r_min && c_pat < r_pat);")
    lines.append("            else if(op == \"==\") ok = (c_maj == r_maj && c_min == r_min && c_pat == r_pat);")
    lines.append("            if(!ok)")
    lines.append("            {")
    lines.append("                Print(\"[VERSION] INCOMPATIBLE: \", label, \" v\", current_ver, \" does not satisfy \", spec, \" (requires \", range_spec, \")\");")
    lines.append("                return false;")
    lines.append("            }")
    lines.append("        }")
    lines.append("        return true;")
    lines.append("    }")
    lines.append("")
    lines.append("    // Convenience: validate a module against its declared requirement")
    lines.append("    static bool ValidateModule(const string &module_name, const string &current_ver, const string &range_spec)")
    lines.append("    {")
    lines.append("        return CheckRange(current_ver, range_spec, module_name);")
    lines.append("    }")
    lines.append("};")
    lines.append("")

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text('\n'.join(lines), encoding='utf-8')
    print(f"Generated: {output_path}")


if __name__ == "__main__":
    root = Path(__file__).parent.parent
    repo_root = root.parent
    manifest = root / "manifest.json"
    output = repo_root / "MQL5" / "MQL5" / "Include" / "ALXQuantCore" / "Version.mqh"
    try:
        generate_version_header(manifest, output)
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)