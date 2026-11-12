#!/usr/bin/env python3
"""Verify durable replay across a process restart using a disposable local database.

Starts its own loopback server on port 8081. Requires DATABASE_URL and a built
server. APNs credentials are removed from the child environment. Never stops an
existing service. The temporary installation is revoked after the check.
"""
import argparse
from datetime import timedelta
import json
import os
from pathlib import Path
import subprocess
import socket
import sys
import time
import urllib.parse
import uuid

from smoke import Relay, SmokeFailure, check, cli, provision, timestamp, utcnow


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server-binary", default=str(Path(__file__).resolve().parents[1] / "target/debug/dayfold-server"))
    args = parser.parse_args()
    database = urllib.parse.urlsplit(os.environ.get("DATABASE_URL", ""))
    if database.hostname not in {"127.0.0.1", "localhost", "::1"}:
        raise SmokeFailure("DATABASE_URL must identify a disposable loopback database")
    relay = Relay("http://127.0.0.1:8081")
    child_env = dict(os.environ)
    for name in ("TEAM_ID", "KEY_ID", "TOPIC", "KEY_FILE"):
        child_env.pop("DAYFOLD_APNS_" + name, None)
    process = None
    device = None

    def start():
        try:
            with socket.socket() as probe:
                probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                probe.bind(("127.0.0.1", 8081))
        except OSError as error:
            raise SmokeFailure("port 8081 is in use; leaving its service untouched") from error
        child = subprocess.Popen(
            [args.server_binary, "serve", "--allow-legacy-dev-auth", "--bind", "127.0.0.1:8081", "--public-origin", "https://relay.example.test"],
            env=child_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if child.poll() is not None:
                raise SmokeFailure("temporary server failed to start; ensure port 8081 is unused")
            try:
                relay.request("GET", "/readyz")
                # Check this child still owns the new listener, rather than accepting
                # an existing server's ready response while this child fails to bind.
                time.sleep(0.1)
                if child.poll() is None:
                    return child
            except SmokeFailure:
                time.sleep(0.1)
        child.kill()
        child.wait()
        raise SmokeFailure("temporary server readiness timed out")

    try:
        process = start()
        device = provision(args)
        token = device["token"]
        channel = relay.request("POST", "/v1/channels", token=token, expected=201, body={
            "scope_id": str(uuid.uuid4()), "expires_at": timestamp(utcnow() + timedelta(hours=1)),
        })
        relay.request("POST", "/v1/webhooks/google", expected=204, headers={
            "X-Goog-Channel-Id": channel["id"], "X-Goog-Channel-Token": channel["token"],
            "X-Goog-Resource-Id": "restart-test-resource", "X-Goog-Resource-State": "sync",
            "X-Goog-Message-Number": "1",
        })
        before = relay.notifications(token)
        check(len(before) == 1, "expected one unacknowledged hint")
        # Abrupt process loss, not a graceful drain, exercises the durable boundary.
        process.kill()
        process.wait(timeout=5)
        process = start()
        after = relay.notifications(token)
        check(before == after, "notification changed or disappeared across process restart")
        event = relay.first_sse(token, 0)
        check(json.loads(event["data"])["id"] == before[0]["id"], "SSE did not replay the persisted hint")
        relay.request("POST", "/v1/notifications/ack", token=token, body={"sequence": before[0]["sequence"]}, expected=204)
        relay.request("DELETE", "/v1/device", token=token, expected=204)
        device = None
        process.terminate()
        process.wait(timeout=10)
        check(process.returncode == 0, "graceful shutdown did not exit successfully")
        process = None
        print("PASS crash/restart preserves notification identity and SSE replay")
        print("PASS explicit acknowledgement, revocation, and graceful shutdown")
    finally:
        try:
            if device:
                cli(args, "revoke", device["device_id"])
        finally:
            if process and process.poll() is None:
                process.kill()
                process.wait()


if __name__ == "__main__":
    try:
        main()
    except (SmokeFailure, subprocess.TimeoutExpired, KeyboardInterrupt) as error:
        print(f"FAIL {error}", file=sys.stderr)
        sys.exit(1)
