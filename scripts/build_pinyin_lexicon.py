"""Compile the pinned AOSP PinyinIME UTF-16 dictionary into keyboard lookup tables."""
import argparse
import math
import struct
from pathlib import Path

# Source: Sogou mobile help, "双拼输入说明", including its zero initial O.
FINALS = {final: key for key, finals in {
    "q": "iu", "w": "ia ua", "e": "e", "r": "uan er", "t": "ue ve",
    "y": "uai v", "u": "u", "i": "i", "o": "o uo", "p": "un",
    "a": "a", "s": "ong iong", "d": "iang uang", "f": "en", "g": "eng",
    "h": "ang", "j": "an", "k": "ao", "l": "ai", ";": "ing", "z": "ei",
    "x": "ie", "c": "iao", "v": "ui", "b": "ou", "n": "in", "m": "ian",
}.items() for final in finals.split()}


def double_code(syllable):
    if syllable[:2] in ("zh", "ch", "sh"):
        initial = {"zh": "v", "ch": "i", "sh": "u"}[syllable[:2]]
        final = syllable[2:]
    elif syllable[0] in "aeo":
        initial, final = "o", syllable
    else:
        initial, final = syllable[0], syllable[1:]
    return initial + FINALS[final] if final in FINALS else None


def compile_table(rows, path):
    records = bytearray()
    offsets = []
    for key, cost, word, lengths in sorted(rows):
        offsets.append(len(records))
        records.extend((key + "\t" + lengths + "\t" + str(cost) + "\t" + word).encode())
    offsets.append(len(records))
    with path.open("wb") as out:
        out.write(struct.pack("<I", len(rows)))
        out.write(struct.pack(f"<{len(offsets)}I", *offsets))
        out.write(records)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dictionary", type=Path)
    parser.add_argument("output_directory", type=Path)
    args = parser.parse_args()
    full, double = [], []
    for line in args.dictionary.read_text(encoding="utf-16").splitlines():
        word, frequency, _, *syllables = line.split()
        cost = round(100 * math.log(100_000_000 / float(frequency)))
        lengths = "".join(str(len(s)) for s in syllables)
        full.append(("".join(syllables), cost, word, lengths))
        codes = [double_code(s) for s in syllables]
        if all(codes):
            double.append(("".join(codes), cost, word, "2" * len(codes)))
    for name, rows in [("FullPinyin", full), ("SogouPinyin", double)]:
        compile_table(rows, args.output_directory / (name + ".lex"))


if __name__ == "__main__":
    main()
