#!/usr/bin/env python3
import base64
import binascii
import ipaddress
import json
import os
from pathlib import Path
import pwd
import re
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time

CONTROL_PORT = 4041
SSH_PORT = 2222
MAX_FRAME_BYTES = 16_384
MAX_KEY_BYTES = 8_192
STATE_DIRECTORY = Path('/var/lib/omabox/ssh')
PENDING_OWNER = Path('/var/lib/omarchy/provisioning/pending')


class ProtocolError(ValueError):
    pass


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ProtocolError('Duplicate JSON field')
        result[key] = value
    return result


def reject_constant(value):
    raise ProtocolError('Invalid JSON constant')


def validate_public_key(value):
    if not isinstance(value, str) or len(value.encode('utf-8')) > MAX_KEY_BYTES:
        raise ProtocolError('Choose one OpenSSH public key smaller than 8 KiB.')
    value = value.strip(' \t\r\n')
    if any(ord(character) < 32 and character != '\t' for character in value):
        raise ProtocolError('The public key must contain exactly one line.')
    fields = value.split(None, 2)
    if len(fields) < 2:
        raise ProtocolError('Choose an OpenSSH public key, not a private key.')
    algorithm, encoded = fields[:2]
    try:
        wire = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error) as error:
        raise ProtocolError('The public key has invalid encoding.') from error
    offset = 0

    def read_string():
        nonlocal offset
        if offset + 4 > len(wire):
            raise ProtocolError('The public key is truncated.')
        length = struct.unpack_from('!I', wire, offset)[0]
        offset += 4
        if length > len(wire) - offset:
            raise ProtocolError('The public key is truncated.')
        result = wire[offset:offset + length]
        offset += length
        return result

    if read_string() != algorithm.encode('ascii', errors='replace'):
        raise ProtocolError('The public key type does not match its contents.')
    if algorithm == 'ssh-ed25519':
        if len(read_string()) != 32:
            raise ProtocolError('Invalid Ed25519 public key.')
    elif algorithm == 'ssh-rsa':
        exponent, modulus = read_string(), read_string()
        if not exponent or not modulus or exponent[0] & 128 or modulus[0] & 128:
            raise ProtocolError('Invalid RSA public key.')
        e, n = int.from_bytes(exponent, 'big'), int.from_bytes(modulus, 'big')
        if e < 3 or e % 2 == 0 or not 2048 <= n.bit_length() <= 16384:
            raise ProtocolError('RSA keys must contain at least 2048 bits.')
    elif algorithm in ('ecdsa-sha2-nistp256', 'ecdsa-sha2-nistp384', 'ecdsa-sha2-nistp521'):
        curve, point = read_string(), read_string()
        expected = {'nistp256': 65, 'nistp384': 97, 'nistp521': 133}[algorithm.removeprefix('ecdsa-sha2-')]
        if curve != algorithm.removeprefix('ecdsa-sha2-').encode() or len(point) != expected or point[0] != 4:
            raise ProtocolError('Invalid ECDSA public key.')
    else:
        raise ProtocolError('Use an Ed25519, ECDSA, or RSA public key.')
    if offset != len(wire):
        raise ProtocolError('The public key contains unexpected data.')
    return algorithm + ' ' + base64.b64encode(wire).decode('ascii')


def decode_request(frame):
    if not frame or len(frame) > MAX_FRAME_BYTES:
        raise ProtocolError('Invalid SSH request size.')
    try:
        request = json.loads(frame.decode('utf-8'), object_pairs_hook=unique_object, parse_constant=reject_constant)
    except (UnicodeError, ValueError, RecursionError) as error:
        raise ProtocolError('Invalid SSH request.') from error
    if not isinstance(request, dict) or type(request.get('version')) is not int or request['version'] != 1:
        raise ProtocolError('Unsupported SSH protocol version.')
    if request.get('type') == 'sshStatus' and set(request) == {'type', 'version'}:
        return request
    if request.get('type') != 'configureSSH' or type(request.get('enabled')) is not bool:
        raise ProtocolError('Invalid SSH configuration request.')
    expected = {'type', 'version', 'enabled'} | ({'publicKey'} if request['enabled'] else set())
    if set(request) != expected:
        raise ProtocolError('Unexpected SSH configuration fields.')
    if request['enabled']:
        request['publicKey'] = validate_public_key(request['publicKey'])
    return request


def owner_account(directory=Path('/var/lib/omabox'), pending=PENDING_OWNER):
    if os.path.lexists(pending) or os.path.lexists(pending.with_name('wipe-pending')):
        return None
    marker = directory / 'owner.json'
    if not marker.exists():
        return None
    details = directory.lstat()
    if not stat.S_ISDIR(details.st_mode) or details.st_uid != 0 or details.st_mode & 0o022:
        raise RuntimeError('The Linux owner marker directory has unsafe permissions.')
    contents = trusted_file(marker).read_bytes()
    if len(contents) > 1024:
        raise RuntimeError('The Linux owner marker is invalid.')
    owner = json.loads(contents, object_pairs_hook=unique_object, parse_constant=reject_constant)
    if (not isinstance(owner, dict) or set(owner) != {'user', 'uid'}
            or not isinstance(owner['user'], str) or len(owner['user']) > 32
            or not re.fullmatch(r'[a-z_][a-z0-9_-]*[$]?', owner['user'])
            or type(owner['uid']) is not int or not 1000 <= owner['uid'] < 4_294_967_295 or owner['uid'] == 65534):
        raise RuntimeError('The Linux owner marker is invalid.')
    try:
        account = pwd.getpwnam(owner['user'])
    except KeyError:
        return None
    if (account.pw_uid != owner['uid'] or account.pw_gid == 0 or account.pw_dir != '/home/' + owner['user']
            or account.pw_shell not in ('/bin/bash', '/usr/bin/bash', '/bin/zsh', '/usr/bin/zsh', '/bin/fish', '/usr/bin/fish')):
        return None
    return account


def guest_address():
    output = subprocess.run(['/usr/bin/ip', '-j', '-4', 'address', 'show', 'scope', 'global'], check=True,
                            capture_output=True, timeout=5).stdout
    if len(output) > 65_536:
        raise RuntimeError('The Linux network response exceeded its size limit.')
    candidates = []
    for interface in json.loads(output):
        name = interface.get('ifname', '')
        if (interface.get('operstate') != 'UP' or not re.fullmatch(r'[a-zA-Z0-9_.-]{1,15}', name)
                or (Path('/sys/class/net') / name / 'device/driver').resolve().name != 'virtio_net'):
            continue
        for entry in interface.get('addr_info', []):
            address = ipaddress.IPv4Address(entry['local'])
            if entry.get('scope') == 'global' and not entry.get('secondary', False) and address.is_private and not address.is_loopback and not address.is_link_local:
                candidates.append(str(address))
    return candidates[0] if len(candidates) == 1 else None


def atomic_write(path, content, mode):
    descriptor, temporary = tempfile.mkstemp(prefix='.' + path.name + '-', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'wb') as handle:
            os.fchmod(handle.fileno(), mode)
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def trusted_file(path):
    details = path.lstat()
    if not stat.S_ISREG(details.st_mode) or details.st_uid != 0 or details.st_mode & 0o022:
        raise RuntimeError('An SSH service file has unsafe permissions.')
    return path


class SSHConfiguration:
    def __init__(self, directory=STATE_DIRECTORY):
        self.directory = directory
        self.applied = None
        self.authorized_this_boot = False
        directory.mkdir(mode=0o755, parents=True, exist_ok=True)
        details = directory.lstat()
        if not stat.S_ISDIR(details.st_mode) or details.st_uid != 0 or details.st_mode & 0o022:
            raise RuntimeError('The SSH service directory has unsafe permissions.')
        self.configuration = {'type': 'configureSSH', 'version': 1, 'enabled': False}
        state = directory / 'configuration.json'
        if state.exists():
            self.configuration = decode_request(trusted_file(state).read_bytes())
            if self.configuration['type'] != 'configureSSH':
                raise ProtocolError('The saved SSH configuration is invalid.')

    def systemctl(self, action):
        subprocess.run(['/usr/bin/systemctl', action, 'omabox-sshd.service'], check=True,
                       capture_output=True, timeout=10)

    def configure(self, request):
        if request != self.configuration:
            self.stop()
        atomic_write(self.directory / 'configuration.json', json.dumps(request).encode() + b'\n', 0o600)
        self.configuration = request
        self.authorized_this_boot = request['enabled']
        return self.reconcile()

    def stop(self):
        self.systemctl('stop')
        self.applied = None
        for name in ('authorized_keys', 'sshd_config'):
            (self.directory / name).unlink(missing_ok=True)

    def reconcile(self):
        result = {'type': 'sshConfigured', 'version': 1, 'enabled': self.configuration['enabled'],
                  'state': 'disabled', 'user': None, 'address': None, 'port': SSH_PORT, 'hostPublicKey': None}
        if not self.configuration['enabled'] or not self.authorized_this_boot:
            result['enabled'] = False
            if self.applied != 'disabled':
                self.stop()
                self.applied = 'disabled'
            return result
        owner = owner_account()
        address = guest_address() if owner else None
        result.update(state='pendingOwner' if owner is None else 'pendingNetwork', user=owner.pw_name if owner else None)
        if owner is None or address is None:
            if self.applied != result['state']:
                self.stop()
                self.applied = result['state']
            return result
        host_key = self.directory / 'ssh_host_ed25519_key'
        if not host_key.exists():
            subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', 'Omabox guest', '-f', str(host_key)],
                           check=True, capture_output=True, timeout=15)
        trusted_file(host_key)
        public = validate_public_key(trusted_file(host_key.with_suffix('.pub')).read_text())
        applied = (owner.pw_name, address, self.configuration['publicKey'])
        if self.applied != applied:
            config = '\n'.join([
                f'Port {SSH_PORT}', 'AddressFamily inet', f'ListenAddress {address}',
                f'HostKey {host_key}', f'PidFile /run/omabox-sshd/sshd.pid',
                f'AuthorizedKeysFile {self.directory / "authorized_keys"}', f'AllowUsers {owner.pw_name}',
                'PermitRootLogin no', 'PubkeyAuthentication yes', 'AuthenticationMethods publickey',
                'PasswordAuthentication no', 'KbdInteractiveAuthentication no', 'PermitEmptyPasswords no',
                'HostbasedAuthentication no', 'UsePAM no', 'StrictModes yes',
                'PermitUserEnvironment no', 'PermitUserRC no', 'X11Forwarding no',
                'AllowAgentForwarding no', 'AllowTcpForwarding yes', 'GatewayPorts no',
                'PermitTunnel no', 'MaxAuthTries 3', 'LoginGraceTime 30',
                'Subsystem sftp internal-sftp', '',
            ])
            atomic_write(self.directory / 'authorized_keys', (self.configuration['publicKey'] + '\n').encode(), 0o644)
            atomic_write(self.directory / 'sshd_config', config.encode(), 0o600)
            subprocess.run(['/usr/bin/sshd', '-t', '-f', str(self.directory / 'sshd_config')], check=True,
                           capture_output=True, timeout=10)
            self.systemctl('restart')
            self.applied = applied
        self.systemctl('is-active')
        result.update(state='ready', address=address, hostPublicKey=public)
        return result


def serve_connection(peer, configuration):
    deadline = time.monotonic() + 5
    frame = bytearray()
    while b'\n' not in frame:
        peer.settimeout(max(0.001, deadline - time.monotonic()))
        data = peer.recv(min(4096, MAX_FRAME_BYTES + 1 - len(frame)))
        if not data:
            raise ProtocolError('The SSH request ended before its newline.')
        frame.extend(data)
        if len(frame) > MAX_FRAME_BYTES or time.monotonic() >= deadline:
            raise ProtocolError('The SSH request exceeded its size or time limit.')
    if frame.count(b'\n') != 1 or not frame.endswith(b'\n'):
        raise ProtocolError('Send exactly one SSH request per connection.')
    request = decode_request(frame[:-1])
    response = configuration.configure(request) if request['type'] == 'configureSSH' else configuration.reconcile()
    peer.sendall(json.dumps(response, separators=(',', ':')).encode() + b'\n')


def run_server():
    if os.geteuid() != 0 or not hasattr(socket, 'AF_VSOCK'):
        raise RuntimeError('The SSH setup service requires Linux root and Virtio sockets.')
    configuration = SSHConfiguration()
    configuration.stop()
    with socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM) as listener:
        listener.bind((socket.VMADDR_CID_ANY, CONTROL_PORT))
        listener.listen(4)
        listener.settimeout(2)
        while True:
            try:
                peer, address = listener.accept()
            except TimeoutError:
                try:
                    configuration.reconcile()
                except (OSError, ValueError, subprocess.SubprocessError):
                    print('SSH configuration is waiting for Linux services.', file=sys.stderr, flush=True)
                continue
            with peer:
                if address[0] != socket.VMADDR_CID_HOST:
                    continue
                try:
                    serve_connection(peer, configuration)
                except (OSError, ValueError, subprocess.SubprocessError) as error:
                    message = str(error) if isinstance(error, ProtocolError) else 'Linux could not apply SSH settings. Check the guest SSH service log.'
                    response = {'type': 'sshError', 'version': 1, 'message': message}
                    try:
                        peer.sendall(json.dumps(response).encode() + b'\n')
                    except OSError:
                        pass
                    print('SSH request could not be applied.', file=sys.stderr, flush=True)


if __name__ == '__main__':
    run_server()
