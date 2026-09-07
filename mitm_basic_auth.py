import base64
import os

from mitmproxy import http

USER = os.environ.get("CFT_BASIC_AUTH_USER", "")
PASSWORD = os.environ.get("CFT_BASIC_AUTH_PASS", "")
EXPECTED = "Basic " + base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()


def request(flow: http.HTTPFlow) -> None:
    if not USER:
        return

    if flow.request.headers.get("Authorization", "") != EXPECTED:
        flow.response = http.Response.make(
            401,
            b"Authentication required",
            {"WWW-Authenticate": 'Basic realm="cft"'},
        )
