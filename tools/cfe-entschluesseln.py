#!/usr/bin/env python3
"""Entschluesselt CloudFree-Dateien (Format CFE1) ohne die App.

Dieses Skript existiert, damit die Daten nicht davon abhaengen, dass die App
noch laeuft. Xcode-Projekte veralten, ein iOS-Update bricht etwas, und
vielleicht hat man das Ding fuenf Jahre nicht angefasst. Der Sicherungscode
und diese Datei genuegen.

Es braucht nichts ausser Python 3 - kein pip, kein cryptography, kein
openssl. AES und GCM stehen weiter unten ausgeschrieben. Das ist langsamer
als eine Bibliothek, aber die Dateien sind klein, und es laeuft auch dort,
wo man nichts installieren kann oder will.

Aufruf:

    python3 cfe-entschluesseln.py --code "ixri hlca ..." datei.txt
    python3 cfe-entschluesseln.py --code @code.txt --aus klartext/ ablage/*.txt

    --app     Welche App die Datei geschrieben hat. Der Schluessel wird je
              App abgeleitet; mit dem falschen Namen schlaegt die Pruefung
              fehl. Voreinstellung: CloudFreeReminder.
    --name    Urspruenglicher Dateiname, falls die Datei umbenannt wurde. Er
              geht in die Authentisierung ein und muss stimmen.
    --aus     Verzeichnis fuer die entschluesselten Dateien. Ohne Angabe geht
              der Klartext nach stdout.

Der Sicherungscode darf gruppiert, umbrochen oder mit eingeschlepptem
Trennstrich uebergeben werden - er wird bereinigt. "@datei" liest ihn aus
einer Datei, das haelt ihn aus der Prozessliste heraus.
"""

import argparse
import base64
import hashlib
import hmac
import os
import struct
import sys

MAGIC = b"CFE1"
HKDF_SALT = b"CloudFree-Inhaltsverschluesselung-v1"


# --------------------------------------------------------------------------
# AES (nur Verschluesselung - CTR und GHASH brauchen nichts anderes)
# --------------------------------------------------------------------------

SBOX = bytes.fromhex(
    "637c777bf26b6fc53001672bfed7ab76ca82c97dfa5947f0add4a2af9ca472c0"
    "b7fd9326363ff7cc34a5e5f171d8311504c723c31896059a071280e2eb27b275"
    "09832c1a1b6e5aa0523bd6b329e32f8453d100ed20fcb15b6acbbe394a4c58cf"
    "d0efaafb434d338545f9027f503c9fa851a3408f929d38f5bcb6da2110fff3d2"
    "cd0c13ec5f974417c4a77e3d645d197360814fdc222a908846eeb814de5e0bdb"
    "e0323a0a4906245cc2d3ac629195e479e7c8376d8dd54ea96c56f4ea657aae08"
    "ba78252e1ca6b4c6e8dd741f4bbd8b8a703eb5664803f60e613557b986c11d9e"
    "e1f8981169d98e949b1e87e9ce5528df8ca1890dbfe6426841992d0fb054bb16"
)

RCON = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36,
        0x6C, 0xD8, 0xAB, 0x4D]


def _xtime(a):
    a <<= 1
    if a & 0x100:
        a = (a ^ 0x1B) & 0xFF
    return a


def _expand_key(key):
    """Schluesselplan fuer AES-256 (Nk=8, Nr=14) - 15 Rundenschluessel."""
    nk, nr = len(key) // 4, len(key) // 4 + 6
    w = [list(key[4 * i:4 * i + 4]) for i in range(nk)]
    for i in range(nk, 4 * (nr + 1)):
        t = list(w[i - 1])
        if i % nk == 0:
            t = t[1:] + t[:1]
            t = [SBOX[b] for b in t]
            t[0] ^= RCON[i // nk - 1]
        elif nk > 6 and i % nk == 4:
            t = [SBOX[b] for b in t]
        w.append([w[i - nk][j] ^ t[j] for j in range(4)])
    return [sum(w[4 * r:4 * r + 4], []) for r in range(nr + 1)], nr


def _encrypt_block(block, round_keys, nr):
    s = [block[i] ^ round_keys[0][i] for i in range(16)]
    for rnd in range(1, nr + 1):
        s = [SBOX[b] for b in s]
        # ShiftRows (spaltenweise Anordnung: Index = 4*Spalte + Zeile)
        s = [s[(i + 4 * (i % 4)) % 16] for i in range(16)]
        if rnd != nr:
            t = []
            for c in range(4):
                col = s[4 * c:4 * c + 4]
                d = col[0] ^ col[1] ^ col[2] ^ col[3]
                t += [col[i] ^ d ^ _xtime(col[i] ^ col[(i + 1) % 4])
                      for i in range(4)]
            s = t
        s = [s[i] ^ round_keys[rnd][i] for i in range(16)]
    return bytes(s)


# --------------------------------------------------------------------------
# GCM
# --------------------------------------------------------------------------

def _gf_mult(x, y):
    """Multiplikation im GF(2^128), wie GHASH sie definiert."""
    z, v = 0, y
    for i in range(128):
        if x & (1 << (127 - i)):
            z ^= v
        if v & 1:
            v = (v >> 1) ^ (0xE1 << 120)
        else:
            v >>= 1
    return z


def _ghash(h, data):
    y = 0
    for i in range(0, len(data), 16):
        block = data[i:i + 16].ljust(16, b"\x00")
        y = _gf_mult(y ^ int.from_bytes(block, "big"), h)
    return y


def _ctr(round_keys, nr, counter_block, data):
    out = bytearray()
    counter = int.from_bytes(counter_block, "big")
    for i in range(0, len(data), 16):
        counter = (counter & ~0xFFFFFFFF) | ((counter + 1) & 0xFFFFFFFF)
        stream = _encrypt_block(counter.to_bytes(16, "big"), round_keys, nr)
        chunk = data[i:i + 16]
        out += bytes(a ^ b for a, b in zip(chunk, stream))
    return bytes(out)


def aes_gcm_open(key, nonce, ciphertext, tag, aad):
    """Entschluesselt und prueft das Tag. Gibt None zurueck, wenn es nicht passt."""
    round_keys, nr = _expand_key(key)
    h = int.from_bytes(_encrypt_block(b"\x00" * 16, round_keys, nr), "big")

    if len(nonce) != 12:
        raise ValueError("Nur 12-Byte-Nonces sind vorgesehen.")
    j0 = nonce + b"\x00\x00\x00\x01"

    plaintext = _ctr(round_keys, nr, j0, ciphertext)

    pad_a = (-len(aad)) % 16
    pad_c = (-len(ciphertext)) % 16
    laengen = struct.pack(">QQ", len(aad) * 8, len(ciphertext) * 8)
    s = _ghash(h, aad + b"\x00" * pad_a + ciphertext + b"\x00" * pad_c + laengen)
    erwartet = bytes(a ^ b for a, b in
                     zip(s.to_bytes(16, "big"),
                         _encrypt_block(j0, round_keys, nr)))

    if not hmac.compare_digest(erwartet, tag):
        return None
    return plaintext


# --------------------------------------------------------------------------
# Schluesselableitung - muss zu CryptoKeyStore.appKey() passen
# --------------------------------------------------------------------------

def hkdf_sha256(ikm, salt, info, length=32):
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    out, t, i = b"", b"", 1
    while len(out) < length:
        t = hmac.new(prk, t + info + bytes([i]), hashlib.sha256).digest()
        out += t
        i += 1
    return out[:length]


def app_key(master_key, app_label):
    return hkdf_sha256(master_key, HKDF_SALT, app_label.encode("utf-8"))


def code_to_master_key(code):
    bereinigt = "".join(c for c in code
                        if not c.isspace() and c not in "-‐‑")
    try:
        roh = base64.b64decode(bereinigt, validate=True)
    except Exception:
        raise SystemExit("Der Sicherungscode ist kein gültiges Base64.")
    if len(roh) != 32:
        raise SystemExit(
            f"Der Sicherungscode ergibt {len(roh)} Byte, erwartet werden 32.")
    return roh


# --------------------------------------------------------------------------

def entschluesseln(pfad, schluessel, name):
    with open(pfad, "rb") as f:
        roh = f.read()

    if not roh.startswith(MAGIC):
        return None, "nicht verschlüsselt (keine CFE1-Kennung)"
    if len(roh) < len(MAGIC) + 12 + 16:
        return None, "unvollständig"

    rest = roh[len(MAGIC):]
    nonce, tag, ciphertext = rest[:12], rest[-16:], rest[12:-16]

    klartext = aes_gcm_open(schluessel, nonce, ciphertext, tag,
                            name.encode("utf-8"))
    if klartext is None:
        return None, ("Prüfung fehlgeschlagen – falscher Code, falsche App "
                      "oder falscher Dateiname")
    return klartext, None


def main():
    p = argparse.ArgumentParser(
        description="Entschluesselt CloudFree-Dateien (CFE1) ohne die App.")
    p.add_argument("dateien", nargs="+")
    p.add_argument("--code", required=True,
                   help='Sicherungscode, oder "@datei" zum Einlesen')
    p.add_argument("--app", default="CloudFreeReminder",
                   help="App, die die Datei geschrieben hat (Vorgabe: CloudFreeReminder)")
    p.add_argument("--name", help="ursprünglicher Dateiname, falls umbenannt")
    p.add_argument("--aus", help="Zielverzeichnis; ohne Angabe nach stdout")
    args = p.parse_args()

    code = args.code
    if code.startswith("@"):
        with open(code[1:], encoding="utf-8") as f:
            code = f.read()

    schluessel = app_key(code_to_master_key(code), args.app)

    if args.aus:
        os.makedirs(args.aus, exist_ok=True)

    fehler = 0
    for pfad in args.dateien:
        name = args.name or os.path.basename(pfad)
        try:
            klartext, problem = entschluesseln(pfad, schluessel, name)
        except OSError as e:
            klartext, problem = None, str(e)

        if problem:
            print(f"{pfad}: {problem}", file=sys.stderr)
            fehler += 1
            continue

        if args.aus:
            ziel = os.path.join(args.aus, os.path.basename(pfad))
            with open(ziel, "wb") as f:
                f.write(klartext)
            print(f"{pfad} → {ziel}")
        else:
            if len(args.dateien) > 1:
                print(f"===== {pfad} =====")
            sys.stdout.write(klartext.decode("utf-8", errors="replace"))
            if not klartext.endswith(b"\n"):
                sys.stdout.write("\n")

    return 1 if fehler else 0


if __name__ == "__main__":
    sys.exit(main())
