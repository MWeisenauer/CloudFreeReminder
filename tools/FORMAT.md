# CFE1 – das Dateiformat der Inhaltsverschlüsselung

Die CloudFree-Apps verschlüsseln Dateien auf dem Gerät, bevor sie hochgeladen
werden. Auf dem Server – Fritz!Box wie Raspberry Pi – liegt nur Geheimtext.

Diese Beschreibung existiert, damit die Daten nicht davon abhängen, dass die
App noch läuft. Mit ihr und dem Sicherungscode kommt man an alles heran; das
Skript `cfe-entschluesseln.py` daneben tut genau das, ohne jede Abhängigkeit
außer Python 3.

## Aufbau einer Datei

```
Byte 0..3     "CFE1"      Kennung samt Formatversion
Byte 4..15    Nonce       12 Byte
Byte 16..n    Geheimtext
letzte 16     Tag         Authentisierung
```

Ab Byte 4 ist das genau `AES.GCM.SealedBox.combined` aus Apples CryptoKit,
also `Nonce ‖ Geheimtext ‖ Tag`.

Die kleinstmögliche gültige Datei ist **32 Byte** groß: Kennung, Nonce und Tag,
ohne Inhalt. Das ist die Verschlüsselung einer leeren Datei und kein Bruchstück
– ein Vergleich `>` statt `>=` an dieser Stelle weist sie fälschlich ab.

Verfahren: **AES-256-GCM**. Als zusätzlich authentisierte Daten (AAD) geht der
**Dateiname** ein, so wie er auf dem Server steht (z. B.
`0C5F9A2E-1111-2222-3333-444455556666.txt`). Wer eine Datei über eine andere
kopiert, bekommt deshalb einen Authentisierungsfehler statt fremden Inhalts.

## Warum die Kennung vorne steht

Sie ist der Grund, warum die Umstellung ohne Stichtag auskam. Beim Lesen
entscheidet die Kennung, ob entschlüsselt oder als Klartext geparst wird. Alte
und neue Dateien liegen nebeneinander, der Bestand wandert von selbst hinüber,
sobald eine Datei geschrieben wird.

Eine spätere Formatversion hieße `CFE2` und müsste `CFE1` weiterhin lesen
können.

## Der Schlüssel

Der **Sicherungscode** ist der Hauptschlüssel in Base64 – 32 Byte, 44 Zeichen.
Die App zeigt ihn in Vierergruppen an; Leerzeichen, Zeilenumbrüche und
eingeschleppte Trennstriche gehören nicht dazu.

Verschlüsselt wird nicht mit dem Hauptschlüssel selbst, sondern mit einem je App
abgeleiteten:

```
AppSchlüssel = HKDF-SHA256(
    IKM  = Hauptschlüssel (32 Byte),
    Salt = "CloudFree-Inhaltsverschluesselung-v1",
    Info = App-Bezeichner,
    L    = 32)
```

Der App-Bezeichner ist ein fester Text, **nicht** die Bundle-ID – die kann sich
ändern. Für die Erinnerungen lautet er `CloudFreeReminder`. Ein anderer
Bezeichner ergibt einen anderen Schlüssel und macht die Dateien unlesbar.

Dadurch genügt ein Sicherungscode für alle Apps, und der Schlüssel einer App
öffnet trotzdem nicht die Dateien einer anderen.

## Was das Format nicht verbirgt

Dateinamen, Anzahl, Größen und Änderungszeiten bleiben sichtbar; ein `NLST` auf
dem Server zeigt sie weiterhin. Die Dateinamen sind reine UUIDs und verraten
nichts über den Inhalt, aber der Umfang der Ablage ist erkennbar.

## Wiederherstellen ohne die App

```
python3 cfe-entschluesseln.py --code "@code.txt" --aus klartext/ ablage/*.txt
```

Geprüft gegen FIPS-197 (AES-256), die NIST-GCM-Testfälle 14 und 16, RFC 5869
(HKDF) – und gegen echte, vom Swift-Code erzeugte Dateien.
