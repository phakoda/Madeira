#!/usr/bin/env python3
"""Read Simulator PNG pixels without installing an image-processing runtime."""
from pathlib import Path
import struct
import zlib


def green_pixel_count(path: Path) -> int:
    data = path.read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('Expected a PNG Simulator screenshot')
    cursor = 8
    compressed = bytearray()
    dimensions = None
    while cursor + 12 <= len(data):
        length = struct.unpack_from('>I', data, cursor)[0]
        kind = data[cursor + 4:cursor + 8]
        payload = data[cursor + 8:cursor + 8 + length]
        if len(payload) != length:
            raise ValueError('Truncated PNG chunk')
        if kind == b'IHDR':
            width, height, depth, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', payload)
            if depth != 8 or color not in (2, 6) or compression or filtering or interlace:
                raise ValueError('Expected non-interlaced 8-bit RGB or RGBA screenshot')
            dimensions = width, height, 3 if color == 2 else 4
        elif kind == b'IDAT':
            compressed.extend(payload)
        cursor += 12 + length
    if not dimensions:
        raise ValueError('Missing PNG dimensions')
    width, height, channels = dimensions
    stride = width * channels
    pixels = zlib.decompress(compressed)
    if len(pixels) != (stride + 1) * height:
        raise ValueError('Incorrect PNG scanline size')
    previous = bytearray(stride)
    count = 0
    for y in range(height):
        start = y * (stride + 1)
        filter_type = pixels[start]
        row = bytearray(pixels[start + 1:start + 1 + stride])
        for x in range(stride):
            left = row[x - channels] if x >= channels else 0
            above = previous[x]
            corner = previous[x - channels] if x >= channels else 0
            if filter_type == 0: predictor = 0
            elif filter_type == 1: predictor = left
            elif filter_type == 2: predictor = above
            elif filter_type == 3: predictor = (left + above) // 2
            elif filter_type == 4:
                estimate = left + above - corner
                distances = [abs(estimate - value) for value in (left, above, corner)]
                predictor = (left, above, corner)[distances.index(min(distances))]
            else: raise ValueError('Invalid PNG scanline filter')
            row[x] = (row[x] + predictor) & 255
        for x in range(0, stride, channels):
            red, green, blue = row[x:x + 3]
            # Account for display color conversion and edge interpolation.
            if red < 80 and green > 110 and blue < 110 and green > red * 2 and green > blue * 2:
                count += 1
        previous = row
    return count
