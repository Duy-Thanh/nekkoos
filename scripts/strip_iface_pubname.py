#!/usr/bin/env python3
"""
strip_iface_pubname.py - Remove 'public name ...' from interface sections of .pas files.
FPC rule: public name must only appear in implementation section.
Usage: python3 strip_iface_pubname.py file1.pas file2.pas ...
"""
import re, sys

for path in sys.argv[1:]:
    with open(path) as f:
        lines = f.read().split('\n')
    in_interface = False
    result = []
    for line in lines:
        s = line.strip()
        if s == 'interface':
            in_interface = True
        elif s == 'implementation':
            in_interface = False
        if in_interface:
            # Remove "; public name '...';" at end of line
            line = re.sub(r";\s*public name\s+'[^']*';?\s*$", ";", line.rstrip())
            # Skip standalone "public name '...';" lines
            if re.match(r"^\s*public name\s+'[^']*';?\s*$", line):
                continue
        result.append(line)
    with open(path, 'w') as f:
        f.write('\n'.join(result))
    print(f"Fixed: {path}")
