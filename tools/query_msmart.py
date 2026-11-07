"""Liest den Zustand der Anlage per msmart-ng (nur lesend) – zum Vergleich mit der App.

Abhängigkeit: Python 3.9+, `pip install msmart-ng`. Token/Schlüssel aus einer Sicherungsdatei (Format wie
„Zugangsdaten sichern …“); die Datei enthält Geheimnisse – nicht ins OneDrive/Repo legen.
Aufruf:  python3 tools/query_msmart.py <sicherung.json>
Die Anlage nimmt nur eine Verbindung an: vorher Klimacontrol beenden.
"""
import asyncio, json, sys
from msmart.device import AirConditioner as AC

async def main(path):
    d = json.load(open(path))["devices"][0]
    dev = AC(ip=d["ip"], port=d["port"], device_id=d["deviceId"])
    await dev.authenticate(bytes.fromhex(d["token"]), bytes.fromhex(d["key"]))
    await dev.get_capabilities()
    await dev.refresh()
    out = {k: str(getattr(dev, k, None)) for k in ("online","power_state","operational_mode","target_temperature","indoor_temperature","outdoor_temperature","fan_speed","eco","turbo","swing_mode","display_on","out_silent","beep","filter_alert")}
    out["supported_modes"] = [str(m) for m in dev.supported_operation_modes]
    out["supported_fan"] = [str(m) for m in dev.supported_fan_speeds]
    print(json.dumps(out, indent=1))

asyncio.run(main(sys.argv[1]))
