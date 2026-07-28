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


def run_inspect(dap, args):
    """P4: after a stopped event, dump scopes/variables/evaluate on the top frame"""
    tid = int(args[0]) if args else 1

    print("[*] stackTrace")
    dap.request("stackTrace", {"threadId": tid, "startFrame": 0, "levels": 10})

    frame_id = None
    deadline = time.time() + 15
    while time.time() < deadline:
        try:
            msg = dap.recv_msg(timeout=15)
        except (TimeoutError, ConnectionError) as e:
            print("  !!", e)
            return
        show(msg)
        if msg.get("type") == "response" and msg.get("command") == "stackTrace":
            frames = msg.get("body", {}).get("stackFrames", [])
            for f in frames[:6]:
                src = f.get("source", {})
                print(f"    frame {f.get('id')}: {f.get('name')} @ {src.get('path') or src.get('name')}:{f.get('line')}")
            if frames:
                frame_id = frames[0].get("id")
            break

    if frame_id is None:
        print("RESULT: INSPECT FAIL (no frames)")
        return

    print(f"[*] scopes frameId={frame_id}")
    dap.request("scopes", {"frameId": frame_id})
    var_refs = []
    deadline = time.time() + 15
    while time.time() < deadline:
        try:
            msg = dap.recv_msg(timeout=15)
        except (TimeoutError, ConnectionError) as e:
            print("  !!", e)
            return
        show(msg)
        if msg.get("type") == "response" and msg.get("command") == "scopes":
            for s in msg.get("body", {}).get("scopes", []):
                print(f"    scope: {s.get('name')} ref={s.get('variablesReference')}")
                if s.get("variablesReference"):
                    var_refs.append((s.get("name"), s["variablesReference"]))
            break

    for name, ref in var_refs[:2]:
        print(f"[*] variables {name} (ref={ref})")
        dap.request("variables", {"variablesReference": ref})
        deadline = time.time() + 15
        while time.time() < deadline:
            try:
                msg = dap.recv_msg(timeout=15)
            except (TimeoutError, ConnectionError) as e:
                print("  !!", e)
                return
            show(msg)
            if msg.get("type") == "response" and msg.get("command") == "variables":
                for v in msg.get("body", {}).get("variables", [])[:10]:
                    print(f"      {v.get('name')} = {v.get('value')} ({v.get('type')})")
                break

    print("[*] evaluate 'pass + fail'")
    dap.request("evaluate", {"expression": "pass + fail", "frameId": frame_id, "context": "watch"})
    deadline = time.time() + 15
    while time.time() < deadline:
        try:
            msg = dap.recv_msg(timeout=15)
        except (TimeoutError, ConnectionError) as e:
            print("  !!", e)
            return
        show(msg)
        if msg.get("type") == "response" and msg.get("command") == "evaluate":
            print(f"    => {msg.get('body', {}).get('result')}")
            break

    print("RESULT: P4 INSPECT DONE")


def run_diag(dap, args):
    """attach -> configurationDone -> threads -> pause -> stopped -> stackTrace"""
    do_initialize(dap)

    print("[*] sending attach")
    dap.request("attach", {"stopOnEntry": False})
    print("[*] sending configurationDone")
    dap.request("configurationDone")

    # drain events until configurationDone response
    deadline = time.time() + 15
    while time.time() < deadline:
        msg = dap.recv_msg(timeout=15)
        show(msg)
        if msg.get("type") == "response" and msg.get("command") == "configurationDone":
            break

    print("[*] threads")
    dap.request("threads")
    print("[*] pause (will stop at next Lua line event)")
    dap.request("pause", {"threadId": 1})

    tid = 1
    stopped = None
    deadline = time.time() + 60
    while time.time() < deadline:
        try:
            msg = dap.recv_msg(timeout=60)
        except (TimeoutError, ConnectionError) as e:
            print("  !!", e)
            break
        show(msg)
        if msg.get("type") == "response" and msg.get("command") == "threads":
            for t in msg.get("body", {}).get("threads", []):
                print(f"    thread {t.get('id')}: {t.get('name')}")
        if msg.get("type") == "event" and msg.get("event") == "stopped":
            stopped = msg
            tid = msg.get("body", {}).get("threadId", 1)
            break

    if not stopped:
        print("RESULT: DIAG FAIL (pause produced no stopped event)")
        sys.exit(2)

    print(f"RESULT: PAUSE OK (reason={stopped.get('body', {}).get('reason')})")
    print("[*] stackTrace")
    dap.request("stackTrace", {"threadId": tid, "startFrame": 0, "levels": 10})
    deadline = time.time() + 15
    while time.time() < deadline:
        try:
            msg = dap.recv_msg(timeout=15)
        except (TimeoutError, ConnectionError) as e:
            print("  !!", e)
            break
        show(msg)
        if msg.get("type") == "response" and msg.get("command") == "stackTrace":
            for f in msg.get("body", {}).get("stackFrames", [])[:6]:
                src = f.get("source", {})
                print(f"    frame: {f.get('name')} @ {src.get('path') or src.get('name')}:{f.get('line')}")
            break

    print("[*] continue")
    dap.request("continue", {"threadId": tid})
    print("RESULT: DIAG DONE")

    # Chain into P4 inspection while still stopped? No — diag continues above.
    # For P4, run: diag then immediately inspect on next stop (see "breakdiag").


def run_breakdiag(dap, args):
    """P3+P4 combined: attach -> setBP -> stop -> stack/scopes/variables/eval -> continue"""
    line = int(args[0])
    source_path = args[1] if len(args) > 1 else "script\\war3map.lua"

    do_initialize(dap)
    print("[*] sending attach")
    dap.request("attach", {"stopOnEntry": False})
    print(f"[*] setBreakpoints {source_path}:{line}")
    dap.request("setBreakpoints", {
        "source": {"path": source_path},
        "breakpoints": [{"line": line}],
    })
    print("[*] sending configurationDone")
    dap.request("configurationDone")

    tid = 1
    stopped = None
    deadline = time.time() + 60
    while time.time() < deadline:
        try:
            msg = dap.recv_msg(timeout=60)
        except (TimeoutError, ConnectionError) as e:
            print("  !!", e)
            break
        show(msg)
        if msg.get("type") == "response" and msg.get("command") == "setBreakpoints":
            bps = msg.get("body", {}).get("breakpoints", [])
            print(f"[*] breakpoint verified = {all(b.get('verified') for b in bps) if bps else False}")
        if msg.get("type") == "event" and msg.get("event") == "stopped":
            stopped = msg
            tid = msg.get("body", {}).get("threadId", 1)
            break

    if not stopped:
        print("RESULT: BREAK FAIL (no stopped event)")
        sys.exit(2)
    print(f"RESULT: BREAKPOINT HIT (reason={stopped.get('body', {}).get('reason')})")

    run_inspect(dap, [str(tid)])

    print("[*] next (step over)")
    dap.request("next", {"threadId": tid})
    step_stopped = None
    deadline = time.time() + 15
    while time.time() < deadline:
        try:
            msg = dap.recv_msg(timeout=15)
        except (TimeoutError, ConnectionError):
            break
        show(msg)
        if msg.get("type") == "event" and msg.get("event") == "stopped":
            step_stopped = msg
            break
    print("RESULT: STEP OVER OK" if step_stopped else "RESULT: STEP OVER FAIL")

    print("[*] continue")
    dap.request("continue", {"threadId": tid})
    print("RESULT: P3+P4 DONE")


def run_break(dap, args):
    """attach -> setBreakpoints -> wait stopped -> stackTrace -> next -> continue"""
    line = int(args[0])
    source_path = args[1] if len(args) > 1 else "script\\war3map.lua"

    do_initialize(dap)

    print("[*] sending attach")
    dap.request("attach", {"stopOnEntry": False})

    print(f"[*] setBreakpoints {source_path}:{line}")
    dap.request("setBreakpoints", {
        "source": {"path": source_path},
        "breakpoints": [{"line": line}],
    })

    print("[*] sending configurationDone")
    dap.request("configurationDone")

    tid = 1
    bp_verified = None
    stopped = None
    deadline = time.time() + 45
    while time.time() < deadline:
        try:
            msg = dap.recv_msg(timeout=45)
        except (TimeoutError, ConnectionError) as e:
            print("  !!", e)
            break
        show(msg)
        if msg.get("type") == "response" and msg.get("command") == "setBreakpoints":
            bps = msg.get("body", {}).get("breakpoints", [])
            bp_verified = all(b.get("verified") for b in bps) if bps else False
            print(f"[*] breakpoint verified = {bp_verified}")
        if msg.get("type") == "event" and msg.get("event") == "stopped":
            stopped = msg
            tid = msg.get("body", {}).get("threadId", 1)
            break

    if not stopped:
        print("RESULT: BREAK FAIL (no stopped event)")
        sys.exit(2)
    print(f"RESULT: BREAKPOINT HIT (reason={stopped.get('body', {}).get('reason')}, verified={bp_verified})")

    print("[*] stackTrace")
    dap.request("stackTrace", {"threadId": tid, "startFrame": 0, "levels": 5})
    print("[*] next (step over)")
    dap.request("next", {"threadId": tid})

    step_stopped = None
    deadline = time.time() + 15
    while time.time() < deadline:
        try:
            msg = dap.recv_msg(timeout=15)
        except (TimeoutError, ConnectionError) as e:
            print("  !!", e)
            break
        show(msg)
        if msg.get("type") == "response" and msg.get("command") == "stackTrace":
            frames = msg.get("body", {}).get("stackFrames", [])
            for f in frames[:3]:
                print(f"    frame: {f.get('name')} @ {f.get('source', {}).get('path') or f.get('source', {}).get('name')}:{f.get('line')}")
        if msg.get("type") == "event" and msg.get("event") == "stopped":
            step_stopped = msg
            break

    print("RESULT: STEP OVER OK" if step_stopped else "RESULT: STEP OVER FAIL")

    print("[*] continue")
    dap.request("continue", {"threadId": tid})
    deadline = time.time() + 8
    while time.time() < deadline:
        try:
            msg = dap.recv_msg(timeout=8)
        except (TimeoutError, ConnectionError):
            break
        show(msg)
        if msg.get("type") == "response" and msg.get("command") == "continue":
            break
    print("RESULT: P3 DONE")


def do_initialize(dap):
    print("[*] sending initialize")
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
    while time.time() < deadline:
        msg = dap.recv_msg(timeout=15)
        show(msg)
        if msg.get("type") == "response" and msg.get("command") == "initialize":
            if msg.get("success"):
                print("RESULT: HANDSHAKE OK")
                return
            break
    print("RESULT: HANDSHAKE FAIL")
    sys.exit(1)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 4278
    mode = sys.argv[2] if len(sys.argv) > 2 else "handshake"
    rest = sys.argv[3:]

    if mode == "break":
        print(f"[*] connecting 127.0.0.1:{port} ...")
        dap = DAP(port=port)
        print("[*] connected")
        run_break(dap, rest)
        return

    if mode == "breakdiag":
        print(f"[*] connecting 127.0.0.1:{port} ...")
        dap = DAP(port=port)
        print("[*] connected")
        run_breakdiag(dap, rest)
        return

    if mode == "diag":
        print(f"[*] connecting 127.0.0.1:{port} ...")
        dap = DAP(port=port)
        print("[*] connected")
        run_diag(dap, rest)
        return

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
