"""Read-only service checks in a temporary directory on an OpenWrt router.

Requires paramiko. No configuration is applied and no service is restarted.
Usage: python tests/subscription-router-check.py [router-address]
"""
import pathlib
import shlex
import sys

import paramiko


root = pathlib.Path(__file__).resolve().parent.parent
client = paramiko.SSHClient()
client.load_system_host_keys()
client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
try:
    client.connect(
        sys.argv[1] if len(sys.argv) > 1 else "192.168.1.1",
        username="root", password="", look_for_keys=False, allow_agent=False,
        timeout=10,
    )
except paramiko.AuthenticationException:
    client.get_transport().auth_none("root")


def run(command):
    _, stdout, stderr = client.exec_command(command, timeout=90)
    output = stdout.read().decode()
    error = stderr.read().decode()
    if stdout.channel.recv_exit_status():
        # Do not print generated configurations or parser diagnostics.
        raise RuntimeError("Remote check failed: " + error[-3000:])
    return output


def upload(path, data):
    stdin, stdout, stderr = client.exec_command("cat > " + shlex.quote(path))
    stdin.channel.sendall(data.encode())
    stdin.channel.shutdown_write()
    stdout.read()
    if stdout.channel.recv_exit_status():
        raise RuntimeError("Temporary upload failed")


remote = run("mktemp -d /tmp/podkop-subscription-test.XXXXXX").strip()
try:
    run(f"mkdir -p {remote}/podkop/files/usr/lib {remote}/tests")
    for file in (root / "podkop/files/usr/lib").glob("*.sh"):
        upload(
            remote + "/podkop/files/usr/lib/" + file.name,
            file.read_text(encoding="utf-8").replace(
                'PODKOP_LIB="/usr/lib/podkop"',
                f'PODKOP_LIB="{remote}/podkop/files/usr/lib"',
            ),
        )
    upload(remote + "/tests/subscriptions.sh",
           (root / "tests/subscriptions.sh").read_text(encoding="utf-8"))
    sandbox = remote + "/integration"
    run("mkdir -p " + sandbox)
    library = (root / "podkop/files/usr/lib/subscriptions.sh").read_text(encoding="utf-8")
    library = library.replace("/tmp/podkop-subscription", sandbox + "/podkop-subscription")
    library = library.replace("/etc/config/podkop", sandbox + "/config/podkop")
    library = library.replace("/etc/init.d/sing-box", sandbox + "/service")
    upload(remote + "/integration-library.sh", library)
    upload(remote + "/tests/subscription-update.sh",
           (root / "tests/subscription-update.sh").read_text(encoding="utf-8"))
    source = (root / "podkop/files/usr/bin/podkop").read_text(encoding="utf-8")
    source = source.replace('PODKOP_LIB="/usr/lib/podkop"',
                            f'PODKOP_LIB="{remote}/podkop/files/usr/lib"')
    # Load definitions, replacing only the top-level command dispatcher.
    source = source[:source.index('\ncase "$1" in\n')]
    source += f"""
log() {{ :; }}
config_set main connection_type proxy
config_set main proxy_config_type selector
config_set main subscription_enabled 1
config_set main selector_proxy_links 'socks5://127.0.0.1:1080#Test'
SUBSCRIPTION_CHECK_PATH="{remote}/candidate.json"
sing_box_init_config
jq -e '.outbounds | any(.tag | startswith("main-sub-"))' "$SUBSCRIPTION_CHECK_PATH" >/dev/null
echo 'Full candidate generation and sing-box check passed'
"""
    upload(remote + "/check", source)
    print(run(f"cd {remote} && ash tests/subscriptions.sh").strip())
    print(run(f"ash {remote}/tests/subscription-update.sh {sandbox} {remote}/integration-library.sh").strip())
    run(f"ash -n {remote}/check && ash -n {remote}/podkop/files/usr/lib/subscriptions.sh")
    print(run(f"ash {remote}/check").strip())
finally:
    run("rm -rf " + shlex.quote(remote))
    client.close()
