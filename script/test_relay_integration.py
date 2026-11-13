#!/usr/bin/env python3
"""Run the Swift/Rust/Postgres loopback check using a temporary installation."""
import json
import http.client
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit

root = Path(__file__).resolve().parents[1]
binary = root / "backend/target/debug/dayfold-server"
database = urlsplit(os.environ.get("DATABASE_URL", ""))
if database.hostname not in {"127.0.0.1", "localhost", "::1"}:
    sys.exit("Set DATABASE_URL to the disposable local PostgreSQL database first.")
if not binary.is_file():
    sys.exit("Build dayfold-server and start the local relay before this check.")
result = subprocess.run([str(binary), "provision"], cwd=root, capture_output=True)
if result.returncode:
    sys.exit("Could not provision the local integration installation.")
installation = json.loads(result.stdout)
status = 1
try:
    installation["origin"] = "http://127.0.0.1:8080"
    with tempfile.TemporaryDirectory(prefix="dayfold-relay-test-") as directory:
        credential_file = Path(directory) / "installation.json"
        credential_file.touch(mode=0o600)
        credential_file.write_text(json.dumps(installation))
        environment = dict(os.environ, DAYFOLD_RELAY_INTEGRATION_FILE=str(credential_file))
        result = subprocess.run([
            "swift", "test", "--package-path", "Packages/CalendarCore", "--scratch-path", ".build/core",
            "--cache-path", ".build/xcode/SourcePackages", "--filter", "localRelayHTTPStreamsReminderClaimsAndRestartResume",
        ], cwd=root, env=environment)
        status = result.returncode
finally:
    # The test normally revokes itself. HTTP 401 confirms that the old bearer
    # is already unusable; the CLI intentionally reports that case as an error.
    cleaned = False
    try:
        connection = http.client.HTTPConnection("127.0.0.1", 8080, timeout=5)
        connection.request("DELETE", "/v1/device", headers={"Authorization": "Bearer " + installation["token"]})
        cleaned = connection.getresponse().status in {204, 401}
        connection.close()
    except OSError:
        pass
    if not cleaned:
        cleaned = subprocess.run([str(binary), "revoke", installation["device_id"]], cwd=root, capture_output=True).returncode == 0
    if not cleaned:
        print("Temporary installation cleanup failed; revoke it through the operator CLI.", file=sys.stderr)
        status = 1
sys.exit(status)
