"""Offline ISAAC-64 helpers for caller-supplied Moments media and numeric keys.

The generator is independently expressed from Bob Jenkins's public-domain
ISAAC-64 reference (https://burtleburtle.net/bob/c/isaac64.c). Protocol ordering
was investigated using hicccc77/WeFlow's services/wasmService.ts and
services/snsService.ts (https://github.com/hicccc77/WeFlow; upstream license:
CC BY-NC-SA 4.0). No upstream application or WASM executes in this module.
No networking, key discovery, process inspection, or filesystem access occurs.

ISAAC XOR alone is unauthenticated. A caller must validate the resulting image
with an image decoder before recording it as a successful backup.
"""
from __future__ import annotations

MASK = (1 << 64) - 1


def _key(value):
    if isinstance(value, bool) or not isinstance(value, (int, str)):
        raise ValueError('key must be an unsigned 64-bit integer or decimal string')
    if isinstance(value, str):
        value = value.strip()
        if not value or any(character not in '0123456789' for character in value):
            raise ValueError('key must contain decimal digits only')
        value = int(value)
    if not 0 <= value <= MASK:
        raise ValueError('key is outside the unsigned 64-bit range')
    return value


def _mix(words):
    a, b, c, d, e, f, g, h = words
    a = (a - e) & MASK; f ^= h >> 9; h = (h + a) & MASK
    b = (b - f) & MASK; g ^= (a << 9) & MASK; a = (a + b) & MASK
    c = (c - g) & MASK; h ^= b >> 23; b = (b + c) & MASK
    d = (d - h) & MASK; a ^= (c << 15) & MASK; c = (c + d) & MASK
    e = (e - a) & MASK; b ^= d >> 14; d = (d + e) & MASK
    f = (f - b) & MASK; c ^= (e << 20) & MASK; e = (e + f) & MASK
    g = (g - c) & MASK; d ^= f >> 17; f = (f + g) & MASK
    h = (h - d) & MASK; e ^= (g << 14) & MASK; g = (g + h) & MASK
    return [a, b, c, d, e, f, g, h]


class _Isaac64:
    def __init__(self, key=0, *, _seed_words=None):
        # The private multiword hook is solely for published reference vectors;
        # the Moments format uses one caller-supplied uint64 in slot zero.
        seed_words = [_key(key)] if _seed_words is None else [_key(word) for word in _seed_words]
        if len(seed_words) > 256:
            raise ValueError('too many seed words')
        seed = seed_words + [0] * (256 - len(seed_words))
        self.memory = [0] * 256
        self.a = self.b = self.c = 0
        state = [0x9e3779b97f4a7c13] * 8
        for _ in range(4):
            state = _mix(state)
        for source in (seed, self.memory):
            for offset in range(0, 256, 8):
                state = _mix([(state[i] + source[offset + i]) & MASK for i in range(8)])
                self.memory[offset:offset + 8] = state
        self.results = self.generate()
        self.remaining = 256

    def generate(self):
        self.c = (self.c + 1) & MASK
        self.b = (self.b + self.c) & MASK
        output = []
        for index in range(256):
            x = self.memory[index]
            if index % 4 == 0:
                self.a = ~(self.a ^ (self.a << 21)) & MASK
            elif index % 4 == 1:
                self.a ^= self.a >> 5
            elif index % 4 == 2:
                self.a = (self.a ^ (self.a << 12)) & MASK
            else:
                self.a ^= self.a >> 33
            self.a = (self.a + self.memory[(index + 128) & 255]) & MASK
            y = (self.memory[(x >> 3) & 255] + self.a + self.b) & MASK
            self.memory[index] = y
            self.b = (self.memory[(y >> 11) & 255] + x) & MASK
            output.append(self.b)
        return output

    def next_word(self):
        if not self.remaining:
            self.results = self.generate()
            self.remaining = 256
        self.remaining -= 1
        return self.results[self.remaining]


def keystream(key, length):
    """Return the SNS byte stream, resetting the generator for this payload.

    Read each 256-word result block backwards, encode each word big-endian,
    and truncate only after generating the final complete 8-byte word. This
    was verified against a nonaligned, multiblock encrypted image sample;
    reversing only the unaligned requested byte count gives a shifted stream.
    """
    if isinstance(length, bool) or not isinstance(length, int) or length < 0:
        raise ValueError('length must be a nonnegative integer')
    generator = _Isaac64(key)
    result = bytearray()
    for _ in range((length + 7) // 8):
        result.extend(generator.next_word().to_bytes(8, 'big'))
    return bytes(result[:length])


def decrypt_image(data, key):
    """XOR a complete image payload using its caller-supplied numeric media key."""
    if not isinstance(data, (bytes, bytearray, memoryview)):
        raise TypeError('data must be bytes-like')
    source = bytes(data)
    stream = keystream(key, len(source))
    return bytes(left ^ right for left, right in zip(source, stream))
