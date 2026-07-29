#!/usr/bin/env python3
import json
import os
import shutil
import socket
import subprocess
import sys
import time


HOME = os.path.expanduser("~")
VPHONE = os.environ.get("VBOUND_VPHONE_CLI", "/opt/homebrew/bin/vphone-cli")
VM_NAME = os.environ.get("VBOUND_VM_NAME", "vphone")
SSH_PASSWORD = os.environ.get("VBOUND_SSH_PASSWORD", "alpine")
THEOS = os.environ.get("THEOS", os.path.join(HOME, "theos"))
forward_process = None


TOOLS = [
    {"name": "vphone_status", "description": "Return vphone-cli, VM, and connected-device status.", "inputSchema": {"type": "object", "properties": {}}},
    {"name": "vphone_boot", "description": "Start a vphone VM in the background.", "inputSchema": {"type": "object", "properties": {"vm_name": {"type": "string"}}}},
    {"name": "vphone_create_vm", "description": "Create a jailbroken vphone VM.", "inputSchema": {"type": "object", "properties": {"vm_name": {"type": "string"}}, "required": ["vm_name"]}},
    {"name": "vphone_shutdown", "description": "Shut down the connected vphone device.", "inputSchema": {"type": "object", "properties": {}}},
    {"name": "vphone_launch_discord", "description": "Restart and launch Discord on vphone.", "inputSchema": {"type": "object", "properties": {}}},
    {"name": "vphone_build_tweak", "description": "Build and deploy the Unbound tweak from a source directory.", "inputSchema": {"type": "object", "properties": {"directory": {"type": "string"}}, "required": ["directory"]}},
    {"name": "vphone_build_addons", "description": "Build Unbound addons from a source directory.", "inputSchema": {"type": "object", "properties": {"directory": {"type": "string"}}, "required": ["directory"]}},
    {"name": "vphone_shell", "description": "Run a shell command on vphone as mobile.", "inputSchema": {"type": "object", "properties": {"command": {"type": "string"}}, "required": ["command"]}},
    {"name": "vphone_logs", "description": "Collect recent Unbound and React Native logs.", "inputSchema": {"type": "object", "properties": {"seconds": {"type": "integer"}}}},
    {"name": "vphone_mount", "description": "Mount vphone's mobile home directory in Finder.", "inputSchema": {"type": "object", "properties": {}}},
    {"name": "vphone_unmount", "description": "Unmount vphone's Finder mount.", "inputSchema": {"type": "object", "properties": {}}},
    {"name": "vphone_migrate_vm", "description": "Clone a legacy ~/vphone-cli/vm into the Homebrew vphone VM library.", "inputSchema": {"type": "object", "properties": {"vm_name": {"type": "string"}}}},
    {"name": "vphone_setup", "description": "Install vphone-cli and vbound host dependencies through Homebrew and pipx.", "inputSchema": {"type": "object", "properties": {}}},
]


def command(args, cwd=None, timeout=None):
    try:
        environment = os.environ.copy()
        environment["THEOS"] = THEOS
        environment["PATH"] = ":".join([
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/homebrew/opt/coreutils/libexec/gnubin",
            "/usr/sbin",
            os.path.join(HOME, ".bun", "bin"),
            os.path.join(HOME, ".local", "bin"),
            environment.get("PATH", "/usr/bin:/bin"),
        ])
        result = subprocess.run(args, cwd=cwd, env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        return result.returncode == 0, result.stdout.strip()
    except Exception as error:
        return False, str(error)


def device_udid():
    ok, output = command(["pymobiledevice3", "usbmux", "list"], timeout=10)
    if not ok:
        return None, output
    try:
        devices = json.loads(output)
    except json.JSONDecodeError:
        return None, output
    for device in devices:
        if device.get("ProductType") == "iPhone99,11":
            return device.get("UDID") or device.get("SerialNumber") or device.get("Identifier") or device.get("UniqueDeviceID"), ""
    return None, "No vphone device is connected."


def ensure_forward():
    global forward_process
    try:
        with socket.create_connection(("127.0.0.1", 2222), timeout=1):
            return True, ""
    except OSError:
        pass
    if forward_process is None or forward_process.poll() is not None:
        environment = os.environ.copy()
        environment["THEOS"] = THEOS
        environment["PATH"] = ":".join([
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/homebrew/opt/coreutils/libexec/gnubin",
            "/usr/sbin",
            os.path.join(HOME, ".bun", "bin"),
            os.path.join(HOME, ".local", "bin"),
            environment.get("PATH", "/usr/bin:/bin"),
        ])
        try:
            forward_process = subprocess.Popen(
                ["pymobiledevice3", "usbmux", "forward", "2222", "22"],
                env=environment,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except Exception as error:
            return False, str(error)
    for _ in range(20):
        try:
            with socket.create_connection(("127.0.0.1", 2222), timeout=1):
                return True, ""
        except OSError:
            time.sleep(0.25)
    return False, "Could not forward vphone SSH to 127.0.0.1:2222."


def ssh(command_text):
    ensure_forward()
    return command(["sshpass", "-p", SSH_PASSWORD, "ssh", "-p", "2222", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "PubkeyAuthentication=no", "mobile@127.0.0.1", command_text], timeout=90)


def ssh_password_literal():
    return SSH_PASSWORD.replace("'", "'\\\"'\\\"'")


def tool_result(name, arguments):
    vm_name = arguments.get("vm_name", VM_NAME).strip() or VM_NAME
    if name == "vphone_status":
        ok, info = command([VPHONE, "vm", "info", vm_name, "--json"], timeout=15)
        udid, device_message = device_udid()
        return ok, json.dumps({"vphone_cli": VPHONE, "vm": vm_name, "vm_info": info, "udid": udid, "device_message": device_message}, indent=2)
    if name == "vphone_boot":
        try:
            subprocess.Popen([VPHONE, "vm", "launch", vm_name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            return True, f"Started {vm_name} in the background."
        except Exception as error:
            return False, str(error)
    if name == "vphone_create_vm":
        return command([VPHONE, "vm", "create", vm_name, "--variant", "jb"], timeout=3600)
    if name == "vphone_shutdown":
        udid, message = device_udid()
        return command(["pymobiledevice3", "diagnostics", "shutdown", "--udid", udid], timeout=15) if udid else (False, message)
    if name == "vphone_launch_discord":
        return ssh("echo '" + ssh_password_literal() + "' | sudo -S killall -9 Discord; uiopen --bundleid com.hammerandchisel.discord")
    if name == "vphone_shell":
        return ssh(arguments["command"])
    if name == "vphone_logs":
        seconds = max(1, min(int(arguments.get("seconds", 10)), 60))
        return command(["pymobiledevice3", "syslog", "live", "--format", "json"], timeout=seconds)
    if name == "vphone_mount":
        sshfs = shutil.which("sshfs")
        mountpoint = os.path.join(HOME, "vphone")
        if not sshfs:
            return False, "sshfs is unavailable. Install macFUSE and SSHFS first."
        os.makedirs(mountpoint, exist_ok=True)
        ok, output = ensure_forward()
        if not ok:
            return ok, output
        return command(["sshpass", "-p", SSH_PASSWORD, sshfs, "-p", "2222", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "PubkeyAuthentication=no", "-o", "reconnect", "mobile@127.0.0.1:/var/mobile", mountpoint], timeout=30)
    if name == "vphone_unmount":
        mountpoint = os.path.join(HOME, "vphone")
        ok, output = command(["umount", mountpoint], timeout=20)
        return (ok, output) if ok else command(["diskutil", "unmount", "force", mountpoint], timeout=20)
    if name == "vphone_migrate_vm":
        source = os.path.join(HOME, "vphone-cli", "vm")
        destination = os.path.join(HOME, ".vphone", "VMs", vm_name)
        if not os.path.isdir(source):
            return False, f"Legacy VM was not found at {source}."
        if os.path.exists(destination):
            return False, f"Destination already exists at {destination}."
        os.makedirs(os.path.dirname(destination), exist_ok=True)
        return command(["/bin/cp", "-cR", source, destination], timeout=900)
    if name == "vphone_setup":
        packages = ["python@3.13", "aria2", "wget", "gnu-tar", "openssl@3", "ldid-procursus", "sshpass", "keystone", "libusb", "ipsw", "zstd", "make", "pipx"]
        ok, output = command(["brew", "install"] + packages, timeout=1800)
        if not ok:
            return ok, output
        ok, output = command(["brew", "install", "zqxwce/tap/vphone-cli"], timeout=900)
        if not ok:
            return ok, output
        ok, output = command(["pipx", "install", "pymobiledevice3"], timeout=900)
        if not ok:
            return ok, output
        return command([VPHONE, "setup"], timeout=900)
    if name == "vphone_build_tweak":
        directory = os.path.expanduser(arguments["directory"])
        ok, output = command(["gmake", "package", "DEBUG=1"], cwd=directory, timeout=1800)
        if not ok:
            return ok, output
        packages = os.path.join(directory, "packages")
        debs = [os.path.join(packages, item) for item in os.listdir(packages) if item.endswith(".deb")]
        if not debs:
            return False, "No package was produced."
        package = max(debs, key=os.path.getmtime)
        ok, output = ensure_forward()
        if not ok:
            return ok, output
        ok, output = command(["sshpass", "-p", SSH_PASSWORD, "scp", "-P", "2222", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "PubkeyAuthentication=no", package, "mobile@127.0.0.1:/var/mobile/Documents/vbound.deb"], timeout=120)
        if not ok:
            return ok, output
        return ssh("echo '" + ssh_password_literal() + "' | sudo -S dpkg -i /var/mobile/Documents/vbound.deb && killall -9 Discord; uiopen --bundleid com.hammerandchisel.discord")
    if name == "vphone_build_addons":
        return command(["bunx", "ubd", "build"], cwd=os.path.expanduser(arguments["directory"]), timeout=1800)
    return False, f"Unknown tool: {name}"


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


for raw in sys.stdin:
    try:
        request = json.loads(raw)
        method = request.get("method")
        request_id = request.get("id")
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": request_id, "result": {"protocolVersion": "2025-03-26", "capabilities": {"tools": {}}, "serverInfo": {"name": "vbound", "version": "1.3.0"}}})
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": request_id, "result": {"tools": TOOLS}})
        elif method == "tools/call":
            ok, output = tool_result(request["params"]["name"], request["params"].get("arguments", {}))
            send({"jsonrpc": "2.0", "id": request_id, "result": {"content": [{"type": "text", "text": output or ("Completed." if ok else "Failed.")}], "isError": not ok}})
        elif request_id is not None:
            send({"jsonrpc": "2.0", "id": request_id, "result": {}})
    except Exception as error:
        if 'request_id' in locals() and request_id is not None:
            send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32603, "message": str(error)}})
