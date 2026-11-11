#!/usr/bin/env python3
"""Root-only isolated packet test. All tables, sets, interfaces and sysctls live in unshare --net."""
import os
from pathlib import Path
import subprocess
import sys
import time


def run(*args):
    return subprocess.check_output(args, stderr=subprocess.STDOUT, timeout=8)


def inside():
    children = []
    servers = []
    try:
        for _ in range(2):
            children.append(subprocess.Popen(['unshare', '--net', 'sleep', '90']))
        client, server = [p.pid for p in children]
        time.sleep(.3)
        run('ip', 'link', 'set', 'lo', 'up')
        for name, pid, router_ip, peer_ip in [('csclient', client, '198.18.0.1/30', '198.18.0.2/30'),
                                               ('csserver', server, '172.31.251.1/24', '172.31.251.4/24')]:
            run('ip', 'link', 'add', name, 'type', 'veth', 'peer', 'name', name+'p')
            run('ip', 'link', 'set', name+'p', 'netns', str(pid))
            run('ip', 'addr', 'add', router_ip, 'dev', name)
            run('ip', 'link', 'set', name, 'up')
            prefix = ['nsenter', '-t', str(pid), '-n']
            run(*prefix, 'ip', 'link', 'set', 'lo', 'up')
            run(*prefix, 'ip', 'addr', 'add', peer_ip, 'dev', name+'p')
            run(*prefix, 'ip', 'link', 'set', name+'p', 'up')
            run(*prefix, 'ip', 'route', 'add', 'default', 'via', router_ip.split('/')[0])
        run('ip', 'addr', 'add', '203.0.113.2/32', 'dev', 'lo')
        run('sysctl', '-q', '-w', 'net.ipv4.ip_forward=1')
        for port in ['80', '443']:
            servers.append(subprocess.Popen(['nsenter', '-t', str(server), '-n', 'python3', '-m', 'http.server', port],
                                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        for chain in ['DOCKER-USER', 'FUNTIDESK_HTTPS_CS', 'CROWDSEC_CHAIN']:
            run('iptables', '-N', chain)
        run('iptables', '-A', 'FORWARD', '-j', 'DOCKER-USER')
        run('iptables', '-A', 'FUNTIDESK_HTTPS_CS', '-j', 'CROWDSEC_CHAIN')
        # Run the exact scoped forwarding rule shipped in the drop-in.
        template = Path(__file__).resolve().parents[2] / 'infra/funtidesk-analytics/crowdsec-forward.conf'
        for line in template.read_text().splitlines():
            if line.startswith('ExecStartPre=') and ' -C DOCKER-USER ' in line:
                run('/bin/sh', '-c', line.split("/bin/sh -c '", 1)[1][:-1])
        run('ipset', 'create', 'cs-test-blocked', 'hash:ip')
        run('iptables', '-A', 'CROWDSEC_CHAIN', '-m', 'set', '--match-set', 'cs-test-blocked', 'src', '-j', 'DROP')
        for port in ['80', '443']:
            run('iptables', '-t', 'nat', '-A', 'PREROUTING', '-d', '203.0.113.2', '-p', 'tcp', '--dport', port,
                '-j', 'DNAT', '--to-destination', '172.31.251.4:'+port)
        time.sleep(.3)

        def probe(host, port):
            code = "import urllib.request; o=urllib.request.build_opener(urllib.request.ProxyHandler({})); print(o.open('http://%s:%s',timeout=1).status)" % (host, port)
            p = subprocess.run(['nsenter', '-t', str(client), '-n', 'python3', '-c', code], capture_output=True, timeout=4)
            return p.returncode == 0 and p.stdout.strip() == b'200'

        assert probe('203.0.113.2', 443)
        run('ipset', 'add', 'cs-test-blocked', '198.18.0.2')
        assert not probe('203.0.113.2', 443), 'Banned DNAT HTTPS passed'
        assert probe('203.0.113.2', 80), 'Unrelated published port affected'
        assert probe('172.31.251.4', 443), 'Non-DNAT flow affected'
        run('ipset', 'del', 'cs-test-blocked', '198.18.0.2')
        assert probe('203.0.113.2', 443), 'Access did not return after unban'
        print('ISOLATED_PACKET_TEST_OK: DNAT block/unblock; other port and non-DNAT preserved')
    finally:
        for p in servers+children:
            p.terminate()
        for p in servers+children:
            p.wait(timeout=5)


if __name__ == '__main__':
    if os.geteuid() != 0:
        sys.exit('Requires root and network namespace capabilities')
    if '--inside' in sys.argv:
        inside()
    else:
        subprocess.run(['unshare', '--net', sys.executable, str(Path(__file__).resolve()), '--inside'], check=True)
