#!/usr/bin/env python3
"""Create the sas-technology bootstrap GitHub App and store its credentials.

Run once, as an org owner, with `gh` logged in:

    python3 scripts/create-bootstrap-app.py

It uses GitHub's app-manifest flow, so two clicks happen in your browser:
  1. "Create GitHub App"   (the app is created from the manifest below)
  2. "Install"             (choose All repositories)

Then it stores the credentials in sas-technology/.github, never printing or
writing the private key:
  - variable   BOOTSTRAP_APP_CLIENT_ID
  - secret     BOOTSTRAP_APP_PRIVATE_KEY  (in the `org-bootstrap` environment,
               which only the `main` branch can use)
"""

import html
import http.server
import json
import secrets
import subprocess
import sys
import threading
import urllib.parse
import urllib.request
import webbrowser

ORG = "sas-technology"
REPO = ".github"
ENVIRONMENT = "org-bootstrap"
APP_NAME = "sas-technology-bootstrap"
PORT = 8765
TIMEOUT_SECONDS = 600

PERMISSIONS = {
    "administration": "write",  # merge settings, immutable releases
    "contents": "write",  # branches and the standard files
    "pull_requests": "write",  # the adoption PRs
    "metadata": "read",
    "members": "read",  # does the CODEOWNERS team have access?
}

STATE = secrets.token_urlsafe(16)
RESULT = {}


def gh(*args, stdin=None):
    return subprocess.run(["gh", *args], input=stdin, text=True, capture_output=True)


def manifest():
    return {
        "name": APP_NAME,
        "url": f"https://github.com/{ORG}/{REPO}",
        "redirect_url": f"http://localhost:{PORT}/callback",
        "public": False,
        "default_permissions": PERMISSIONS,
        "default_events": [],
    }


def start_page():
    action = f"https://github.com/organizations/{ORG}/settings/apps/new?state={STATE}"
    body = html.escape(json.dumps(manifest()), quote=True)
    return (
        "<!doctype html><meta charset=utf-8><title>Create app</title>"
        f'<form id=f method=post action="{action}">'
        f'<input type=hidden name=manifest value="{body}"></form>'
        "<p>Sending you to GitHub to create the app...</p>"
        "<script>document.getElementById('f').submit()</script>"
    )


def convert(code):
    req = urllib.request.Request(
        f"https://api.github.com/app-manifests/{urllib.parse.quote(code)}/conversions",
        method="POST",
        headers={"Accept": "application/vnd.github+json"},
        data=b"",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def store(app):
    """Save the credentials in the repo. The private key goes straight to gh's stdin."""
    target = f"{ORG}/{REPO}"
    env = gh(
        "api", "-X", "PUT", f"repos/{target}/environments/{ENVIRONMENT}", "--input", "-",
        stdin=json.dumps({"deployment_branch_policy": {"protected_branches": False, "custom_branch_policies": True}}),
    )
    if env.returncode:
        return f"could not create the {ENVIRONMENT} environment: {env.stderr.strip()}"
    # 422 when the policy already exists is fine.
    gh("api", "-X", "POST", f"repos/{target}/environments/{ENVIRONMENT}/deployment-branch-policies", "-f", "name=main")
    var = gh("variable", "set", "BOOTSTRAP_APP_CLIENT_ID", "--repo", target, "--body", app["client_id"])
    if var.returncode:
        return f"could not set BOOTSTRAP_APP_CLIENT_ID: {var.stderr.strip()}"
    sec = gh("secret", "set", "BOOTSTRAP_APP_PRIVATE_KEY", "--env", ENVIRONMENT, "--repo", target, stdin=app["pem"])
    if sec.returncode:
        return f"could not store the private key: {sec.stderr.strip()}"
    return None


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, status, text):
        data = text.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(url.query)
        if url.path == "/":
            return self.send(200, start_page())
        if url.path != "/callback":
            return self.send(404, "not found")
        if query.get("state", [""])[0] != STATE or "code" not in query:
            RESULT["error"] = "state mismatch or missing code"
            return self.send(400, "Rejected: state mismatch.")
        try:
            app = convert(query["code"][0])
        except Exception as exc:  # report and stop; the app can be deleted and the script re-run
            RESULT["error"] = f"could not exchange the manifest code: {exc}"
            return self.send(500, "Could not finish. See the terminal.")
        problem = store(app)
        RESULT.update(slug=app["slug"], id=app["id"], html_url=app["html_url"], error=problem)
        install = f"https://github.com/apps/{app['slug']}/installations/new"
        self.send(
            200,
            "<!doctype html><meta charset=utf-8><title>Install</title>"
            f"<p>App created. <a href='{install}'>Install it on {ORG}</a> "
            "and choose <b>All repositories</b>.</p>"
            f"<script>location.href={json.dumps(install)}</script>",
        )
        threading.Thread(target=self.server.shutdown, daemon=True).start()


def main():
    if gh("auth", "status").returncode:
        sys.exit("gh is not logged in. Run: gh auth login")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.timeout = TIMEOUT_SECONDS
    timer = threading.Timer(TIMEOUT_SECONDS, server.shutdown)
    timer.daemon = True
    timer.start()
    url = f"http://localhost:{PORT}/"
    print(f"Opening {url} - click 'Create GitHub App' on GitHub, then 'Install'.", flush=True)
    webbrowser.open(url)
    server.serve_forever()
    timer.cancel()
    if "slug" not in RESULT:
        sys.exit(f"No app was created. {RESULT.get('error', 'Timed out waiting for the browser.')}")
    print(f"Created app '{RESULT['slug']}' (id {RESULT['id']}): {RESULT['html_url']}")
    if RESULT["error"]:
        sys.exit(
            f"Storing credentials failed: {RESULT['error']}\n"
            f"Generate a new private key at {RESULT['html_url']} and store it as the "
            f"{ENVIRONMENT} environment secret BOOTSTRAP_APP_PRIVATE_KEY."
        )
    print(f"Stored BOOTSTRAP_APP_CLIENT_ID and BOOTSTRAP_APP_PRIVATE_KEY in {ORG}/{REPO}.")
    print(f"Now install the app: https://github.com/apps/{RESULT['slug']}/installations/new (All repositories).")


if __name__ == "__main__":
    main()
