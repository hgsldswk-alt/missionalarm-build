"""Render ExportOptions.plist for the release job. No credentials are read here."""
import os
import pathlib
import plistlib
import sys

path = pathlib.Path(__file__).with_name("ExportOptions.plist")
data = plistlib.loads(path.read_bytes())
app_id = os.environ.get("APP_ID", "com.hgsldswk.missionalarm")
data["teamID"] = os.environ["TEAM_ID"]
data["provisioningProfiles"] = {
    app_id: "MissionAlarm AppStore",
    app_id + ".widget": "MissionAlarm Widget AppStore",
}
sys.stdout.buffer.write(plistlib.dumps(data))
