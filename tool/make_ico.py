"""Packs PNG files into a Windows .ico (PNG-compressed entries, Vista+)."""
import struct, sys

def main(out, pngs):
    entries, blobs = [], []
    for path in pngs:
        data = open(path, 'rb').read()
        w, h = struct.unpack('>II', data[16:24])
        entries.append((w, h, data))
    header = struct.pack('<HHH', 0, 1, len(entries))
    offset = 6 + 16 * len(entries)
    dir_bytes = b''
    for w, h, data in entries:
        dir_bytes += struct.pack('<BBBBHHII', w % 256, h % 256, 0, 0, 1, 32, len(data), offset)
        offset += len(data)
    with open(out, 'wb') as f:
        f.write(header + dir_bytes + b''.join(d for _, _, d in entries))

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2:])
