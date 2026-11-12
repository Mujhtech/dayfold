#!/usr/bin/env python3
"""Exercise a running local Dayfold relay without contacting Google or APNs.

The service must already be running against the same DATABASE_URL used here.
Two temporary installations are provisioned by the CLI and revoked on exit.
Fake APNs tokens are registered only with --expect-apns-disabled, after the
server reports that provider delivery is disabled. Default checks register none.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


BACKEND = Path(__file__).resolve().parents[1]


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class SmokeFailure(Exception):
    pass


def timestamp(value: datetime) -> str:
    return value.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


class Relay:
    def __init__(self, base_url: str):
        parsed = urllib.parse.urlsplit(base_url)
        if (
            parsed.scheme != "http"
            or parsed.hostname not in {"localhost", "127.0.0.1", "::1"}
            or parsed.username
            or parsed.password
            or parsed.path not in {"", "/"}
            or parsed.query
            or parsed.fragment
        ):
            raise SmokeFailure("--base-url must be an HTTP loopback origin")
        self.base_url = base_url.rstrip("/")
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), NoRedirects()
        )

    def request(self, method, path, *, token=None, body=None, headers=None, expected=200):
        request_headers = dict(headers or {})
        request_headers["Accept"] = "application/json"
        if token:
            request_headers["Authorization"] = f"Bearer {token}"
        payload = None
        if body is not None:
            payload = json.dumps(body).encode("utf-8")
            request_headers["Content-Type"] = "application/json"
        elif method == "POST":
            payload = b""
        request = urllib.request.Request(
            self.base_url + path, data=payload, headers=request_headers, method=method
        )
        try:
            with self.opener.open(request, timeout=5) as response:
                status, raw = response.status, response.read(1_000_000)
        except urllib.error.HTTPError as error:
            status, raw = error.code, error.read(1_000_000)
        except urllib.error.URLError as error:
            raise SmokeFailure(f"{method} {path}: local service unavailable") from error
        accepted = (expected,) if isinstance(expected, int) else expected
        if status not in accepted:
            # Never echo headers, request bodies, or arbitrary server output.
            raise SmokeFailure(f"{method} {path}: expected {accepted}, received {status}")
        if not raw:
            return None
        try:
            return json.loads(raw)
        except ValueError as error:
            if status >= 400:
                # Axum's query/path extraction rejections can be plain text.
                # The expected status was checked above; never echo their body.
                return None
            raise SmokeFailure(f"{method} {path}: response is not JSON") from error

    def notifications(self, token, after=0):
        page = self.request("GET", f"/v1/notifications?after={after}", token=token)
        items = page.get("notifications")
        if not isinstance(items, list):
            raise SmokeFailure("notification page lacks a notifications array")
        return items

    def first_sse(self, token, after):
        request = urllib.request.Request(
            self.base_url + "/v1/events",
            headers={
                "Authorization": f"Bearer {token}",
                "Last-Event-ID": str(after),
                "Accept": "text/event-stream",
            },
        )
        fields = {}
        try:
            with self.opener.open(request, timeout=5) as response:
                for _ in range(50):
                    line = response.readline(65_536).decode("utf-8").rstrip("\r\n")
                    if not line:
                        if fields:
                            return fields
                        continue
                    if line.startswith(":"):
                        continue
                    key, separator, value = line.partition(":")
                    if separator:
                        fields[key] = value.lstrip(" ")
        except (OSError, ValueError) as error:
            raise SmokeFailure("SSE replay did not return a valid event") from error
        raise SmokeFailure("SSE replay did not return an event")


def cli(args, *command):
    if args.server_binary:
        invocation = [str(Path(args.server_binary).resolve()), *command]
    else:
        invocation = [
            "cargo", "run", "--quiet", "--manifest-path", str(BACKEND / "Cargo.toml"),
            "-p", "dayfold-server", "--", *command,
        ]
    result = subprocess.run(invocation, capture_output=True, text=True, check=False)
    if result.returncode:
        # A DB connection error can contain the URL. Keep captured diagnostics private.
        raise SmokeFailure(f"relay CLI {command[0]} failed (exit {result.returncode})")
    return result.stdout


def provision(args):
    try:
        device = json.loads(cli(args, "provision"))
        uuid.UUID(device["device_id"])
        if not isinstance(device["token"], str) or len(device["token"]) != 64:
            raise ValueError("invalid token")
        return device
    except (ValueError, KeyError, TypeError) as error:
        raise SmokeFailure("provision must print JSON with device_id and token") from error


def check(condition, message):
    if not condition:
        raise SmokeFailure(message)


def run(args):
    relay = Relay(args.base_url)
    relay.request("GET", "/readyz")
    devices = []
    try:
        first = provision(args)
        devices.append(first)
        second = provision(args)
        devices.append(second)
        token, other_token = first["token"], second["token"]
        relay.request("GET", "/v1/notifications", expected=401)
        relay.request("GET", "/v1/notifications", token="f" * 64, expected=401)
        relay.request("GET", "/v1/capabilities", expected=401)
        capabilities = relay.request("GET", "/v1/capabilities", token=token)
        check(type(capabilities.get("apns_enabled")) is bool,
              "capabilities did not report an APNs configuration boolean")
        if args.expect_apns_disabled:
            check(capabilities["apns_enabled"] is False,
                  "this check requires APNs to be disabled")
            fake_push = {"token": uuid.uuid4().hex * 2, "environment": "sandbox"}
            relay.request("PUT", "/v1/device/push", body=fake_push, expected=401)
            relay.request("PUT", "/v1/device/push", token=token, body=fake_push, expected=204)
            relay.request("PUT", "/v1/device/push", token=other_token, body=fake_push, expected=409)
            relay.request("PUT", "/v1/device/push", token=token, body=fake_push, expected=204)
            print("PASS exclusive APNs registration and owner refresh with provider delivery disabled")
        print("PASS authenticated provisioning and rejected missing/invalid credentials")
        print("PASS authenticated APNs capability discovery")

        scope = str(uuid.uuid4())
        expires = timestamp(utcnow() + timedelta(hours=1))
        channel = relay.request(
            "POST", "/v1/channels", token=token,
            body={"scope_id": scope, "expires_at": expires}, expected=201,
        )
        resource = "local-smoke-resource-" + uuid.uuid4().hex
        webhook_headers = {
            "X-Goog-Channel-Id": channel["id"],
            "X-Goog-Channel-Token": channel["token"],
            "X-Goog-Resource-Id": resource,
            "X-Goog-Resource-State": "sync",
            "X-Goog-Message-Number": "1",
        }
        wrong_headers = dict(webhook_headers, **{"X-Goog-Channel-Token": "invalid"})
        relay.request("POST", "/v1/webhooks/google", headers=wrong_headers, expected=401)
        relay.request("POST", "/v1/webhooks/google", headers=webhook_headers, expected=204)
        rebound_headers = dict(webhook_headers, **{"X-Goog-Resource-Id": "wrong-resource"})
        relay.request("POST", "/v1/webhooks/google", headers=rebound_headers, expected=409)
        activation = {"resource_id": resource, "expires_at": expires}
        relay.request(
            "PUT", f"/v1/channels/{channel['id']}", token=other_token,
            body=activation, expected=404,
        )
        relay.request("DELETE", f"/v1/channels/{channel['id']}", token=other_token, expected=404)
        relay.request("PUT", f"/v1/channels/{channel['id']}", token=token, body=activation)
        relay.request(
            "PUT", f"/v1/channels/{channel['id']}", token=token,
            body={"resource_id": "wrong-resource", "expires_at": expires}, expected=409,
        )
        baseline = relay.notifications(token)
        check(len(baseline) == 1, "initial sync did not create exactly one hint")
        webhook_headers["X-Goog-Resource-State"] = "exists"
        for number in ("10", "10", "8"):
            webhook_headers["X-Goog-Message-Number"] = number
            relay.request("POST", "/v1/webhooks/google", headers=webhook_headers, expected=204)
        hints = relay.notifications(token)
        check(len(hints) == len(baseline) + 2, "duplicate or out-of-order webhook handling failed")
        check(all(item["kind"] == "calendar_changed" and item["subject_id"] == scope for item in hints),
              "webhook routed to the wrong scope")
        check(all(item.get("revision") is None for item in hints), "calendar hint has a reminder revision")
        check(not relay.notifications(other_token), "one installation received another's hints")
        relay.request("POST", "/v1/notifications/ack", token=other_token,
                      body={"sequence": hints[-1]["sequence"]}, expected=400)
        relay.request("GET", f"/v1/notifications?device_id={first['device_id']}",
                      token=other_token, expected=400)
        check(relay.notifications(token) == hints,
              "foreign inbox access or acknowledgement changed the owner's hints")
        print("PASS early sync, channel ownership, token/resource validation, webhook deduplication and reordering")

        first_hint = hints[0]
        event = relay.first_sse(token, first_hint["sequence"])
        check(event.get("event") == "notification", "SSE event type is incorrect")
        try:
            data = json.loads(event.get("data", "{}"))
        except ValueError as error:
            raise SmokeFailure("SSE notification data is not JSON") from error
        check(int(event.get("id", -1)) == data["sequence"] > first_hint["sequence"],
              "SSE did not replay after Last-Event-ID")
        relay.request(
            "GET", "/v1/notifications?after=0", token=token,
            headers={"Last-Event-ID": "1"}, expected=400,
        )
        print("PASS SSE replay and conflicting-cursor rejection")

        cursor = hints[-1]["sequence"]
        reminder_id, cancelled_id = str(uuid.uuid4()), str(uuid.uuid4())
        due = utcnow() + timedelta(seconds=2)
        reminder = {
            "revision": 1,
            "due_at": timestamp(due),
            "expires_at": timestamp(due + timedelta(minutes=5)),
        }
        relay.request("PUT", f"/v1/reminders/{reminder_id}", token=token, body=reminder, expected=204)
        relay.request("PUT", f"/v1/reminders/{reminder_id}", token=token, body=reminder, expected=204)
        relay.request("PUT", f"/v1/reminders/{cancelled_id}", token=token, body=reminder, expected=204)
        relay.request("DELETE", f"/v1/reminders/{cancelled_id}?revision=2", token=token, expected=204)
        relay.request("PUT", f"/v1/reminders/{cancelled_id}", token=token, body=reminder, expected=409)
        deadline = time.monotonic() + 20
        observed = []
        while time.monotonic() < deadline:
            observed = relay.notifications(token, cursor)
            if any(item["kind"] == "reminder_due" for item in observed):
                break
            time.sleep(0.5)
        reminders = [item for item in observed if item["kind"] == "reminder_due"]
        check(len(reminders) == 1 and reminders[0]["subject_id"] == reminder_id,
              "due reminder was missing, duplicated, or cancellation failed")
        check(reminders[0].get("revision") == 1, "reminder notification lost its schedule revision")
        time.sleep(1.5)
        check(len(relay.notifications(token, cursor)) == 1, "reminder was materialized more than once")
        latest = reminders[0]["sequence"]
        relay.request("POST", "/v1/notifications/ack", token=token,
                      body={"sequence": latest}, expected=204)
        check(not relay.notifications(token, latest), "cursor replay returned acknowledged prefix again")
        bounds = relay.request("GET", "/v1/notifications/cursor", token=token)
        check(bounds["current"] == latest, "recovery cursor did not reflect the latest committed notification")
        print("PASS scheduled reminders, idempotent writes, cancellation tombstones, durable acknowledgement and cursor")

        claim_path = f"/v1/notifications/{reminders[0]['id']}/claim"
        relay.request("POST", claim_path, expected=401)
        check(relay.request("POST", claim_path, token=other_token) == {"claimed": False},
              "another installation claimed the reminder")
        check(relay.request("POST", f"/v1/notifications/{uuid.uuid4()}/claim", token=token)
              == {"claimed": False}, "missing notification was claimable")
        check(relay.request("POST", f"/v1/notifications/{first_hint['id']}/claim", token=token)
              == {"claimed": False}, "calendar hint was claimable as a reminder")
        # An SSE cursor acknowledgement must leave reminder delivery ownership
        # intact. Before any APNs attempt the client can still explicitly claim it.
        for _ in range(2):
            check(relay.request("POST", claim_path, token=token) == {"claimed": True},
                  "acknowledgement suppressed the reminder or repeat claim was not idempotent")
        relay.request("DELETE", f"/v1/reminders/{reminder_id}?revision=2", token=token, expected=204)
        check(relay.request("POST", claim_path, token=token) == {"claimed": False},
              "cancelled reminder remained claimable")
        print("PASS reminder claim authentication, ownership, post-ACK delivery, idempotency and cancellation")

        relay.request("DELETE", f"/v1/device/{first['device_id']}", token=other_token, expected=404)
        relay.request("DELETE", "/v1/device", token=other_token, expected=204)
        relay.request("GET", "/v1/capabilities", token=other_token, expected=401)
        relay.request("GET", "/v1/capabilities", token=token)
        relay.request("DELETE", "/v1/device", token=token, expected=204)
        relay.request("GET", "/v1/notifications", token=token, expected=401)
        print("PASS installation revocation cannot target another installation")
        print("All local smoke checks passed; no Google or APNs requests were made.")
    finally:
        failures = 0
        for device in devices:
            try:
                relay.request("DELETE", "/v1/device", token=device["token"], expected=(204, 401))
            except Exception:
                try:
                    cli(args, "revoke", device["device_id"])
                except Exception:
                    failures += 1
        if failures:
            raise SmokeFailure(f"cleanup could not revoke {failures} temporary installation(s)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:8080")
    parser.add_argument("--server-binary", help="Use an already built dayfold-server executable")
    parser.add_argument("--expect-apns-disabled", action="store_true",
                        help="Fail unless the server reports APNs delivery disabled")
    args = parser.parse_args()
    try:
        run(args)
    except (SmokeFailure, KeyboardInterrupt) as error:
        print(f"FAIL {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
