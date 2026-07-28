# tools/dap_probe.py — Minimal DAP client for verifying jass.debugger (P2/P3)
#
# Usage:
#   python tools/dap_probe.py [port] [script]
#     port   : debugger listen port (default 4278)
#     script : "handshake" (default) — initialize only
#              "attach"              — initialize + attach + configurationDone
#
# Prints every DAP message received (truncated) and a final verdict line.

import json
import socket
import sys
import time


class DAP:
    def __init__(self, host="127.0.0.1", port=4278, timeout=10):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(timeout)
        self.buf = b""
        self.seq = 1

    def send(self, msg):
        data = json.dumps(msg).encode()
        self.sock.sendall(b"Content-Length: %d\r\n\r\n" % (len(data),) + data)

    def request(self, command, arguments=None):
        seq = self.seq
        self.seq += 1
        msg = {"seq": seq, "type": "request", "command": command}
        if arguments is not None:
            msg["arguments"] = arguments
        self.send(msg)
        return seq

    def recv_msg(self, timeout=10):
        end = time.time() + timeout
        while True:
            while b"\r\n\r\n" not in self.buf:
                if time.time() > end:
                    raise TimeoutError("waiting for DAP header")
                chunk = self.sock.recv(65536)
                if not chunk:
                    raise ConnectionError("connection closed by peer")
                self.buf += chunk
            head, self.buf = self.buf.split(b"\r\n\r\n", 1)
            length = None
            for line in head.split(b"\r\n"):
                if line.lower().startswith(b"content-length:"):
                    length = int(line.split(b":", 1)[1].strip())
            if length is None:
                continue
            while len(self.buf) < length:
                if time.time() > end:
                    raise TimeoutError("waiting for DAP body")
                chunk = self.sock.recv(65536)
                if not chunk:
                    raise ConnectionError("connection closed by peer")
                self.buf += chunk
            body, self.buf = self.buf[:length], self.buf[length:]
            return json.loads(body)


def show(msg):
    s = json.dumps(msg, ensure_ascii=False)
    print("  <<", s[:500])


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 4278
    mode = sys.argv[2] if len(sys.argv) > 2 else "handshake"

    print(f"[*] connecting 127.0.0.1:{port} ...")
    dap = DAP(port=port)
    print("[*] connected, sending initialize")
    dap.request("initialize", {
        "clientID": "kimi-dap-probe",
        "clientName": "Kimi DAP Probe",
        "adapterID": "lua-debug",
        "linesStartAt1": True,
        "columnsStartAt1": True,
        "pathFormat": "path",
        "supportsVariableType": True,
    })

    deadline = time.time() + 15
    init_ok = False
    while time.time() < deadline:
        msg = dap.recv_msg(timeout=15)
        show(msg)
        if msg.get("type") == "response" and msg.get("command") == "initialize":
            init_ok = bool(msg.get("success"))
            break

    if not init_ok:
        print("RESULT: HANDSHAKE FAIL")
        sys.exit(1)
    print("RESULT: HANDSHAKE OK")

    if mode != "attach":
        return

    print("[*] sending attach")
    dap.request("attach", {"stopOnEntry": False})
    print("[*] sending configurationDone")
    dap.request("configurationDone")

    deadline = time.time() + 20
    attach_ok = False
    while time.time() < deadline:
        try:
            msg = dap.recv_msg(timeout=20)
        except (TimeoutError, ConnectionError) as e:
            print("  !!", e)
            break
        show(msg)
        if msg.get("type") == "response" and msg.get("command") == "attach":
            attach_ok = bool(msg.get("success"))
            if not attach_ok:
                break
        if msg.get("type") == "response" and msg.get("command") == "configurationDone":
            break

    print("RESULT: ATTACH OK" if attach_ok else "RESULT: ATTACH FAIL")
    sys.exit(0 if attach_ok else 2)


if __name__ == "__main__":
    main()
