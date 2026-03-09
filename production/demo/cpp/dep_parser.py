#!/usr/bin/env python3

import sys
import json
import re
from pathlib import Path


def parse_makefile_deps(dep_file_path, output_file_path):
    try:
        with open(dep_file_path, 'r') as f:
            content = f.read()

        content = re.sub(r'\\\s*\n\s*', ' ', content)
        match = re.search(r'.*?\s*:\s*(.+)', content)

        if not match:
            print(f"WARNING: cann't parse {dep_file_path}", file=sys.stderr)
            deps = []
        else:
            deps_str = match.group(1).strip()
            deps = [dep.strip() for dep in deps_str.split() if dep.strip()]

        target_file = output_file_path.replace('.dep.json', '.o')
        result = [{
            "file": target_file,
            "deps": deps
        }]

        with open(output_file_path, 'w') as f:
            json.dump(result, f, indent=2)

        print(f"Generated {output_file_path}")
        return True

    except Exception as e:
        print(f"ERROR: parse {dep_file_path} failure: {e}", file=sys.stderr)
        return False


def main():
    if len(sys.argv) != 3:
        print("usage: dep_parser.py <input.d> <output.dep.json>", file=sys.stderr)
        print("example: dep_parser.py build/main.d build/main.dep.json", file=sys.stderr)
        sys.exit(1)

    input_file = sys.argv[1]
    output_file = sys.argv[2]
    if not Path(input_file).exists():
        print(f"ERROR: input file {input_file} not exists", file=sys.stderr)
        sys.exit(1)

    success = parse_makefile_deps(input_file, output_file)
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
