import sys
import os
import glob
import re

def fix_vtk_file(filepath):
    print(f"Processing: {filepath}")
    with open(filepath, 'rb') as f:
        raw_start = f.read(1024)
        marker = b'LOOKUP_TABLE default\n'
        idx = raw_start.find(marker)
        if idx == -1:
            print("  -> Skipping: 'LOOKUP_TABLE default\\n' not found in header.")
            return False
        header_len = idx + len(marker)
        f.seek(0)
        full_content = f.read()

    header_text = full_content[:idx].decode('ascii', errors='ignore')
    binary_data = full_content[header_len:]

    # Case 1: 3-component velocity file (SCALARS data float 3 -> VECTORS Velocity float)
    if 'SCALARS data float 3' in header_text:
        pos_scalars = header_text.rfind('SCALARS')
        clean_header = (header_text[:pos_scalars] + 'VECTORS Velocity float\n').encode('ascii')
    # Case 2: flags file (convert POINT_DATA Nx Ny Nz -> CELL_DATA with DIMENSIONS Nx+1 Ny+1 Nz+1
    # so every single solid lattice site is rendered as a true 3D voxel cube without 8-corner averaging)
    elif 'unsigned_char 1' in header_text and 'POINT_DATA' in header_text:
        m_dim = re.search(r'DIMENSIONS\s+(\d+)\s+(\d+)\s+(\d+)', header_text)
        m_org = re.search(r'ORIGIN\s+([-\d.Ee+]+)\s+([-\d.Ee+]+)\s+([-\d.Ee+]+)', header_text)
        m_spc = re.search(r'SPACING\s+([-\d.Ee+]+)\s+([-\d.Ee+]+)\s+([-\d.Ee+]+)', header_text)
        if not (m_dim and m_org and m_spc):
            print("  -> Skipping: could not parse DIMENSIONS/ORIGIN/SPACING.")
            return False
        nx, ny, nz = (int(m_dim.group(1)), int(m_dim.group(2)), int(m_dim.group(3)))
        ox, oy, oz = (float(m_org.group(1)), float(m_org.group(2)), float(m_org.group(3)))
        sx, sy, sz = (float(m_spc.group(1)), float(m_spc.group(2)), float(m_spc.group(3)))
        new_hdr = header_text
        new_hdr = re.sub(r'DIMENSIONS\s+\d+\s+\d+\s+\d+', f'DIMENSIONS {nx+1} {ny+1} {nz+1}', new_hdr)
        new_hdr = re.sub(r'ORIGIN\s+[-\d.Ee+]+\s+[-\d.Ee+]+\s+[-\d.Ee+]+',
                         f'ORIGIN {ox-0.5*sx:.8E} {oy-0.5*sy:.8E} {oz-0.5*sz:.8E}', new_hdr)
        new_hdr = new_hdr.replace('POINT_DATA', 'CELL_DATA')
        clean_header = (new_hdr + 'LOOKUP_TABLE default\n').encode('ascii')
    else:
        print("  -> Skipping: unrecognized scalar format.")
        return False

    base, ext = os.path.splitext(filepath)
    out_path = f"{base}_fixed{ext}"
    with open(out_path, 'wb') as f:
        f.write(clean_header + binary_data)
    print(f"  -> Successfully created: {out_path} ({os.path.getsize(out_path):,} bytes)")
    return True

def main():
    if len(sys.argv) > 1:
        targets = sys.argv[1:]
    else:
        targets = []
        for pattern in ['u-*.vtk', 'bin/export/u-*.vtk', 'export/u-*.vtk', '*u-*.vtk',
                        'flags-*.vtk', 'bin/export/flags-*.vtk', 'export/flags-*.vtk', '*flags-*.vtk']:
            for match in glob.glob(pattern):
                if not match.endswith('_fixed.vtk') and match not in targets:
                    targets.append(match)
    if not targets:
        print("No .vtk files specified or found.")
        return
    for t in targets:
        if os.path.isfile(t) and not t.endswith('_fixed.vtk'):
            fix_vtk_file(t)

if __name__ == '__main__':
    main()
