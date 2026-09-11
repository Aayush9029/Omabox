import base64
import importlib.util
import json
from pathlib import Path
import socket
import struct
import stat
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

SPEC = importlib.util.spec_from_file_location('ssh_agent', Path(__file__).parent / 'overlay/usr/local/libexec/omabox-ssh-agent.py')
agent = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(agent)


def wire_string(value):
    return struct.pack('!I', len(value)) + value


def key(algorithm='ssh-ed25519', fields=None):
    fields = [bytes(range(32))] if fields is None else fields
    wire = wire_string(algorithm.encode()) + b''.join(wire_string(field) for field in fields)
    return algorithm + ' ' + base64.b64encode(wire).decode()


class SSHProtocolTests(unittest.TestCase):
    def test_accepts_one_public_key_and_drops_comment(self):
        self.assertEqual(agent.validate_public_key(key() + ' workstation\n'), key())

    def test_rejects_multiple_keys_options_private_keys_and_control_characters(self):
        for value in [key() + '\n' + key(), 'command="id" ' + key(), '-----BEGIN OPENSSH PRIVATE KEY-----',
                      key() + '\r' + key(), key() + '\x00anything', key() + '\x1b[31m', 'ssh-dss AAAA']:
            with self.subTest(value=value), self.assertRaises(agent.ProtocolError):
                agent.validate_public_key(value)

    def test_rejects_mismatched_truncated_or_oversized_key(self):
        for value in [key().replace('ssh-ed25519 ', 'ssh-rsa '), key(fields=[b'short']), 'ssh-ed25519 AAAA',
                      key() + ' ' + 'a' * agent.MAX_KEY_BYTES, 'ssh-ed25519 !!!']:
            with self.subTest(value=value), self.assertRaises(agent.ProtocolError):
                agent.validate_public_key(value)

    def test_rsa_rejects_small_modulus_and_invalid_exponent(self):
        for exponent, modulus in [(b'\x01', b'\0' + b'\xff' * 256), (b'\x03', b'\x7f' * 64), (b'\xff', b'\0' + b'\xff' * 256)]:
            with self.assertRaises(agent.ProtocolError):
                agent.validate_public_key(key('ssh-rsa', [exponent, modulus]))
        rsa = key('ssh-rsa', [b'\x01\x00\x01', b'\0' + b'\xff' * 256])
        self.assertEqual(agent.validate_public_key(rsa), rsa)

    def test_rejects_duplicate_fields_nonboolean_unknown_fields_and_version(self):
        frames = [b'{"type":"sshStatus","type":"sshStatus","version":1}',
                  b'{"type":"sshStatus","version":true}', b'{"type":"sshStatus","version":2}',
                  b'{"type":"configureSSH","version":1,"enabled":0}',
                  b'{"type":"configureSSH","version":1,"enabled":false,"publicKey":"x"}',
                  b'{"type":"sshStatus","version":1,"command":"id"}', b'[]', b'{"x":NaN}']
        for frame in frames:
            with self.subTest(frame=frame), self.assertRaises(agent.ProtocolError):
                agent.decode_request(frame)

    def test_one_frame_returns_status_and_rejects_pipelining(self):
        configuration = Mock()
        configuration.reconcile.return_value = {'state': 'disabled'}
        for data, success in [(b'{"type":"sshStatus","version":1}\n', True),
                              (b'{"type":"sshStatus","version":1}\n{}\n', False),
                              (b'a' * (agent.MAX_FRAME_BYTES + 1), False)]:
            host, guest = socket.socketpair()
            host.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 65536)
            try:
                host.sendall(data)
                if success:
                    agent.serve_connection(guest, configuration)
                    self.assertEqual(json.loads(host.recv(4096)), {'state': 'disabled'})
                else:
                    with self.assertRaises(agent.ProtocolError):
                        agent.serve_connection(guest, configuration)
            finally:
                host.close()
                guest.close()
        configuration.configure.assert_not_called()


class SSHConfigurationTests(unittest.TestCase):
    def configuration(self, directory, enabled=True):
        configuration = object.__new__(agent.SSHConfiguration)
        configuration.directory = Path(directory)
        configuration.configuration = {'type': 'configureSSH', 'version': 1, 'enabled': enabled}
        if enabled:
            configuration.configuration['publicKey'] = key()
        configuration.applied = None
        configuration.authorized_this_boot = enabled
        configuration.systemctl = Mock()
        return configuration

    def test_pending_owner_does_not_create_host_keys_or_start_sshd(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(agent, 'owner_account', return_value=None), patch.object(agent.subprocess, 'run') as run:
            configuration = self.configuration(directory)
            response = configuration.reconcile()
            self.assertEqual(response['state'], 'pendingOwner')
            self.assertIsNone(response['user'])
            configuration.systemctl.assert_called_once_with('stop')
            run.assert_not_called()
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_disable_revokes_only_managed_files_and_stops_sessions(self):
        with tempfile.TemporaryDirectory() as directory:
            configuration = self.configuration(directory)
            for name in ('authorized_keys', 'sshd_config', 'ssh_host_ed25519_key', 'unrelated'):
                (Path(directory) / name).write_text('fixture')
            response = configuration.configure({'type': 'configureSSH', 'version': 1, 'enabled': False})
            self.assertEqual(response['state'], 'disabled')
            self.assertFalse((Path(directory) / 'authorized_keys').exists())
            self.assertFalse((Path(directory) / 'sshd_config').exists())
            self.assertEqual((Path(directory) / 'unrelated').read_text(), 'fixture')
            self.assertEqual((Path(directory) / 'ssh_host_ed25519_key').read_text(), 'fixture')
            self.assertIn(unittest.mock.call('stop'), configuration.systemctl.call_args_list)

    def test_key_replacement_stops_previous_access_before_applying(self):
        with tempfile.TemporaryDirectory() as directory:
            configuration = self.configuration(directory)
            configuration.reconcile = Mock(side_effect=RuntimeError('sshd failed'))
            request = {'type': 'configureSSH', 'version': 1, 'enabled': True, 'publicKey': key(fields=[b'b' * 32])}
            with self.assertRaises(RuntimeError):
                configuration.configure(request)
            configuration.systemctl.assert_called_once_with('stop')
            self.assertEqual(json.loads((Path(directory) / 'configuration.json').read_text()), request)

    def test_ready_access_is_limited_to_recorded_owner_and_managed_public_key(self):
        with tempfile.TemporaryDirectory() as directory:
            configuration = self.configuration(directory)
            (Path(directory) / 'ssh_host_ed25519_key').write_text('private fixture never returned')
            (Path(directory) / 'ssh_host_ed25519_key.pub').write_text(key())
            with patch.object(agent, 'owner_account', return_value=SimpleNamespace(pw_name='alice')), patch.object(agent, 'guest_address', return_value='192.168.64.3'), patch.object(agent, 'trusted_file', side_effect=lambda path: path), patch.object(agent.subprocess, 'run'):
                response = configuration.reconcile()
            self.assertEqual(response['state'], 'ready')
            self.assertEqual(response['user'], 'alice')
            self.assertEqual(response['hostPublicKey'], key())
            self.assertNotIn('private fixture', json.dumps(response))
            config = (Path(directory) / 'sshd_config').read_text()
            for setting in ['AllowUsers alice', 'ListenAddress 192.168.64.3', 'PermitRootLogin no', 'PasswordAuthentication no', 'KbdInteractiveAuthentication no', 'AuthenticationMethods publickey', 'UsePAM no']:
                self.assertIn(setting + '\n', config)
            self.assertNotIn('/home/', config)
            self.assertEqual(stat.S_IMODE((Path(directory) / 'authorized_keys').stat().st_mode), 0o644)
            self.assertEqual(stat.S_IMODE((Path(directory) / 'sshd_config').stat().st_mode), 0o600)

    def test_recorded_owner_must_still_match_exact_passwd_uid(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'owner.json').write_text(json.dumps({'user': 'alice', 'uid': 1000}))
            account = SimpleNamespace(pw_name='alice', pw_uid=1001, pw_gid=1001, pw_dir='/home/alice', pw_shell='/bin/bash')
            with patch.object(Path, 'lstat', return_value=SimpleNamespace(st_mode=stat.S_IFDIR | 0o755, st_uid=0)), patch.object(agent, 'trusted_file', side_effect=lambda path: path), patch.object(agent.pwd, 'getpwnam', return_value=account):
                self.assertIsNone(agent.owner_account(root, root / 'pending'))
                account.pw_uid = 1000
                self.assertEqual(agent.owner_account(root, root / 'pending'), account)

    def test_reboot_does_not_restore_access_without_host_authorization(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(agent, 'owner_account') as owner:
            configuration = self.configuration(directory)
            configuration.authorized_this_boot = False
            response = configuration.reconcile()
            self.assertEqual(response['state'], 'disabled')
            self.assertFalse(response['enabled'])
            configuration.systemctl.assert_called_once_with('stop')
            owner.assert_not_called()

    def test_guest_address_ignores_bridge_and_vpn_interfaces(self):
        interfaces = [
            {'ifname': name, 'operstate': 'UP', 'addr_info': [{'local': address, 'scope': 'global'}]}
            for name, address in [('enp0s1', '192.168.64.3'), ('docker0', '172.17.0.1'), ('tun0', '10.0.0.2')]
        ]
        def driver(path):
            return Path('/sys/bus/virtio/drivers/virtio_net' if 'enp0s1' in str(path) else '/sys/devices/virtual/net')
        with patch.object(agent.subprocess, 'run', return_value=Mock(stdout=json.dumps(interfaces).encode())), patch.object(Path, 'resolve', driver):
            self.assertEqual(agent.guest_address(), '192.168.64.3')

    def test_pending_marker_overrides_any_recorded_owner(self):
        with tempfile.TemporaryDirectory() as directory:
            pending = Path(directory) / 'pending'
            pending.touch()
            self.assertIsNone(agent.owner_account(Path(directory), pending))
            pending.unlink()
            pending.with_name('wipe-pending').touch()
            self.assertIsNone(agent.owner_account(Path(directory), pending))


if __name__ == '__main__':
    unittest.main()
