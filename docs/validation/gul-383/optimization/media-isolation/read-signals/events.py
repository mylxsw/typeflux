"""Private mmap event format shared with observe.c; no paths or file contents."""
import ctypes
import json
import os
from pathlib import Path
import struct


class Event(ctypes.LittleEndianStructure):
    _fields_ = [(name, ctypes.c_uint64) for name in ['committed', 'sequence']] + [
        (name, ctypes.c_double) for name in ['uptime', 'entered']] + [
        (name, ctypes.c_int64) for name in ['size', 'count', 'result', 'offset']] + [
        (name, ctypes.c_uint64) for name in ['start_seconds', 'start_microseconds']] + [
        (name, ctypes.c_int32) for name in ['kind', 'pid', 'target', 'descriptor', 'status', 'error']]


def create(path, capacity=50000):
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.ftruncate(fd, 32 + capacity * ctypes.sizeof(Event))
        os.write(fd, struct.pack('<QQQQ', 0, 0, capacity, ctypes.sizeof(Event)))
    finally:
        os.close(fd)


def read(path):
    data = Path(path).read_bytes()
    if len(data) < 32:
        raise ValueError('Incomplete event header')
    count, dropped, capacity, size = struct.unpack_from('<QQQQ', data)
    if size != ctypes.sizeof(Event) or len(data) != 32 + capacity * size:
        raise ValueError('Event format mismatch')
    rows = []
    for i in range(min(count, capacity)):
        event = Event.from_buffer_copy(data[32 + i * size:32 + (i + 1) * size])
        if event.committed != 1:
            continue
        rows.append({name: getattr(event, name) for name, _ in Event._fields_ if name != 'committed'})
    return {'reserved': count, 'dropped': dropped, 'incomplete': min(count, capacity) - len(rows),
            'events': sorted(rows, key=lambda event: event['uptime'])}


def export(source, target):
    result = read(source)
    Path(target).write_text(json.dumps(result, indent=2) + '\n')
    return result
