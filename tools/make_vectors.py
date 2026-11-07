"""Erzeugt Testvektoren mit msmart-ng für die Swift-Tests (Tests/MideaKitTests/vectors.json).

Abhängigkeit: Python 3.9+ und msmart-ng (`pip install msmart-ng==$MSMART_NG`, siehe MSMART_NG unten). Nutzt private
msmart-APIs (`lan._Packet`, `lan._LanProtocolV3`, `Command._message_id`) – bei einer anderen msmart-Version können
sich Namen ändern; dann die Version unten anheben und die Tests prüfen.

Aufruf (aus der Projektwurzel):  python3 tools/make_vectors.py Tests/MideaKitTests/vectors.json

Die Datei wird **zusammengeführt**, nicht überschrieben: Schlüssel, die dieses Skript nicht erzeugt (`udpid`,
`nethomeSign`, `smarthome`, `discovery` – Cloud-Signaturen nach midea-beautiful-air/midea_ac_lan und eine echte
Discovery-Antwort der PortaSplit), bleiben unverändert erhalten. `_generator` hält die benutzte msmart-ng-Version fest.
Vektoren nie ändern, damit eine Plattform grün wird (AGENTS.md, Abschnitt 11.3).
"""
import json, os, sys
from datetime import datetime, timezone
from importlib.metadata import version as pkg_version
from unittest import mock
import msmart.lan as lan
from msmart.device.AC.command import (Command, GetStateCommand, GetCapabilitiesCommand, GetGroupDataCommand,
    ToggleDisplayCommand, GetPropertiesCommand, SetPropertiesCommand, SetStateCommand, PropertyId)

# Erwartete msmart-ng-Version (leer = jede).
MSMART_NG = os.environ.get("MSMART_NG", "")
KEEP = ("udpid", "nethomeSign", "smarthome", "discovery")

if len(sys.argv) != 2:
    sys.exit("Aufruf: python3 tools/make_vectors.py Tests/MideaKitTests/vectors.json")
installed = pkg_version("msmart-ng")
if MSMART_NG and installed != MSMART_NG:
    sys.exit(f"msmart-ng {installed} installiert, erwartet {MSMART_NG} (MSMART_NG)")

def fixed(cmd):
    Command._message_id = 0x10 - 1  # nächste ID = 0x10
    return cmd.tobytes().hex()

v = {}
v["getState"] = fixed(GetStateCommand())
v["getCapabilities"] = fixed(GetCapabilitiesCommand())
v["getGroup4"] = fixed(GetGroupDataCommand(4))
v["toggleDisplay"] = fixed(ToggleDisplayCommand())
v["getOutSilent"] = fixed(GetPropertiesCommand([PropertyId.OUT_SILENT]))
v["setOutSilentOn"] = fixed(SetPropertiesCommand({PropertyId.OUT_SILENT: True}))
sets = []
for p, t, m, f, eco, turbo, sw, beep in [(True, 22.5, 2, 102, False, False, 0, True), (False, 16.0, 5, 1, True, False, 12, False),
                                       (True, 30.0, 4, 80, False, True, 0, True), (True, 17.0, 3, 20, False, False, 12, True)]:
    c = SetStateCommand(); c.power_on=p; c.target_temperature=t; c.operational_mode=m; c.fan_speed=f; c.eco=eco
    c.turbo=turbo; c.swing_mode=sw; c.beep_on=beep; c.fahrenheit=False; c.freeze_protection=False; c.sleep=False
    c.follow_me=False; c.purifier=False; c.target_humidity=40
    sets.append({"power": p, "temp": t, "mode": m, "fan": f, "eco": eco, "turbo": turbo, "swing": sw, "beep": beep, "frame": fixed(c)})
v["setState"] = sets

# V2-Paket mit festem Zeitpunkt
when = datetime(2026, 10, 31, 12, 34, 56, 780000, tzinfo=timezone.utc)
class FakeDT(datetime):
    @classmethod
    def now(cls, tz=None): return when
with mock.patch.object(lan, "datetime", FakeDT):
    v["v2"] = {"deviceId": 20015998343868, "frame": v["getState"], "epoch": when.timestamp(),
               "packet": lan._Packet.encode(20015998343868, bytes.fromhex(v["getState"])).hex()}

# V3-Verschlüsselung mit festem Schlüssel und festem Padding (0xAB)
key = bytes(range(32))
p = lan._LanProtocolV3(); p._local_key = key; p._packet_id = 5
with mock.patch.object(lan, "get_random_bytes", lambda n: bytes([0xAB]) * n):
    v["v3"] = {"localKey": key.hex(), "packetId": 5, "data": v["v2"]["packet"],
               "packet": p._encode_encrypted_request(5, bytes.fromhex(v["v2"]["packet"])).hex()}

# Handshake: Antwort aus bekanntem Klartext bauen, erwarteter Sitzungsschlüssel = Klartext XOR key
from hashlib import sha256
plain = bytes(range(100, 132)); ck = bytes(range(200, 232))
resp = lan.Security.encrypt_aes_cbc(ck, plain) + sha256(plain).digest()
v["handshake"] = {"key": ck.hex(), "response": resp.hex(), "localKey": p._get_local_key(ck, memoryview(resp)).hex()}
# Eigenschaften
v["setIECOOn"] = fixed(SetPropertiesCommand({PropertyId.IECO: (1, True)}))
v["setSelfCleanOn"] = fixed(SetPropertiesCommand({PropertyId.SELF_CLEAN: True}))
v["setSoundOff"] = fixed(SetPropertiesCommand({PropertyId.SOUND: False}))
v["getProps3"] = fixed(GetPropertiesCommand([PropertyId.IECO, PropertyId.OUT_SILENT, PropertyId.SELF_CLEAN]))
c = SetStateCommand(); c.power_on=True; c.target_temperature=21.0; c.operational_mode=4; c.fan_speed=40; c.eco=False
c.turbo=False; c.swing_mode=0; c.beep_on=True; c.fahrenheit=False; c.freeze_protection=True; c.purifier=True
v["setStateIonFrost"] = fixed(c)

# Zusammenführen: nicht erzeugte Schlüssel aus der bestehenden Datei übernehmen.
old = json.load(open(sys.argv[1])) if os.path.exists(sys.argv[1]) else {}
missing = [k for k in KEEP if k not in old]
if missing:
    sys.exit(f"Abbruch: {sys.argv[1]} enthält {missing} nicht – diese Vektoren erzeugt das Skript nicht.")
merged = dict(old)
merged.update(v)
merged["_generator"] = {"script": "tools/make_vectors.py", "msmart-ng": installed}
with open(sys.argv[1], "w") as f:
    json.dump(merged, f, indent=1)
print("ok", len(v), "erzeugt,", len(KEEP), "übernommen, msmart-ng", installed)
