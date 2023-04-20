import sys
import socket
import subprocess
import time
import urllib.request
from pathlib import Path

import certifi


class PypiProxy:
    """
    Wrapper for mitmproxy.org

    We start an instance of mitmproxy to intercept requests by pip
    to ensure that pip doesn't see files which were published after
    the pypiSnapshotDate given to our script.
    It's generic enough that it should work with python mirrors
    besides pypi.org as well, but URLs for actual distribution files
    should not be intercepted for performance reasons and we
    currently just ignore files.pythonhosted.org by default.
    """

    def __init__(self, executable, args, env):
        self.env = env
        self.port = self.find_free_port()

        self.proc = subprocess.Popen(
            [
                executable,
                "--listen-port",
                str(self.port),
                "--anticache",
                *args,
            ],
            stdout=sys.stderr,
            stderr=sys.stderr,
            env=env,
        )
        self.wait("http://pypi.org", 10)
        self.cafile = self.generate_ca_bundle(".ca-cert.pem")

    def find_free_port(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.bind(("", 0))
        port = sock.getsockname()[1]
        sock.close()
        return port

    def wait(self, test_url, timeout):
        """
        Wait for a bit until a given url is reachable via the proxy,
        as the latter starts asynchronous.
        """
        timeout = time.time() + timeout
        req = urllib.request.Request(test_url)
        req.set_proxy(f"127.0.0.1:{self.port}", "http")

        while time.time() < timeout:
            try:
                res = urllib.request.urlopen(req, None, 5)
                if res.status < 400:
                    break
            except urllib.error.URLError:
                pass
            finally:
                time.sleep(1)

    def generate_ca_bundle(self, path):
        """
        Because we only proxy *some* calls, but ignore i.e.
        files.pythonhosted.org we need to combine upstream ca certificates
        and the one generated by mitm proxy.
        """
        home = Path(self.env["HOME"])
        path = home / path
        with open(home / ".mitmproxy/mitmproxy-ca-cert.pem", "r") as f:
            mitmproxy_cacert = f.read()
        with open(certifi.where(), "r") as f:
            certifi_cacert = f.read()
        with open(path, "w") as f:
            f.write(mitmproxy_cacert)
            f.write("\n")
            f.write(certifi_cacert)
        return path

    def kill(self):
        self.proc.kill()