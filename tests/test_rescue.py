"""Restricted-network bootstrap and offline asset validation."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / 'src' / 'rescue.py'
SPEC = importlib.util.spec_from_file_location('skybyte_rescue', SOURCE)
rescue = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(rescue)


class RescueTest(unittest.TestCase):
    def test_architecture_names_match_official_asset_names(self):
        for machine, expected in [('x86_64', 'amd64'), ('aarch64', 'arm64'),
                                  ('arm64', 'arm64'), ('i686', '386'),
                                  ('armv7l', 'armv7')]:
            self.assertEqual(rescue.architecture(machine, 'sing-box'), expected)
        for machine, expected in [('x86_64', 'amd64'), ('aarch64', 'arm64'),
                                  ('i686', '386'), ('armv7l', 'arm')]:
            self.assertEqual(rescue.architecture(machine, 'cloudflared'), expected)
        for machine, component in [('mips', 'sing-box'), ('armv7l', 'unknown')]:
            with self.assertRaises(ValueError):
                rescue.architecture(machine, component)

    def test_public_node_address_rejects_local_and_url_values(self):
        self.assertEqual(rescue.public_address('8.8.8.8'), '8.8.8.8')
        self.assertEqual(rescue.public_address('2001:4860:4860::8888'), '2001:4860:4860::8888')
        self.assertEqual(rescue.public_address('Node.Example.com'), 'node.example.com')
        for value in ('127.0.0.1', '192.168.1.10', 'http://node.example',
                      'localhost', 'bad name.example', '[2001:4860::1]'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                rescue.public_address(value)

    def test_argo_options_are_validated_and_keep_other_state(self):
        original = {'mode': 'quick', 'domain': 'random.trycloudflare.com'}
        updated = rescue.argo_options(original, '6', 'http2')
        self.assertEqual(updated, {'mode': 'quick', 'domain': 'random.trycloudflare.com',
                                   'edge_ip_version': '6', 'transport': 'http2'})
        self.assertNotIn('transport', original)
        for edge, transport in [('5', 'auto'), ('auto', 'tcp'), ('4', 'http')]:
            with self.subTest(edge=edge, transport=transport), self.assertRaises(ValueError):
                rescue.argo_options(original, edge, transport)

    def test_verified_cloudflared_asset_requires_release_digest(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            payload = b'official cloudflared fixture\n'
            (root / 'cloudflared-linux-amd64').write_bytes(payload)
            release = {'tag_name': '2026.10.0', 'draft': False, 'prerelease': False,
                       'assets': [{'name': 'cloudflared-linux-amd64',
                                   'browser_download_url': 'https://github.com/cloudflare/cloudflared/releases/download/2026.10.0/cloudflared-linux-amd64',
                                   'digest': 'sha256:' + hashlib.sha256(payload).hexdigest()}]}
            (root / 'cloudflared-release.json').write_text(json.dumps(release))
            target = root / 'bin' / 'cloudflared'
            target.parent.mkdir()
            rescue.verified_asset(str(root), 'cloudflared', '', 'x86_64', str(target))
            self.assertEqual(target.read_bytes(), payload)
            self.assertEqual(target.stat().st_mode & 0o777, 0o755)
            target.write_bytes(b'keep on error')
            (root / 'cloudflared-linux-amd64').write_bytes(b'tampered')
            with self.assertRaises(ValueError):
                rescue.verified_asset(str(root), 'cloudflared', '', 'x86_64', str(target))
            self.assertEqual(target.read_bytes(), b'keep on error')

    def test_verified_sing_box_extracts_only_expected_regular_binary(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            name = 'sing-box-1.14.3-linux-amd64.tar.gz'
            payload = io.BytesIO()
            with tarfile.open(fileobj=payload, mode='w:gz') as archive:
                data = b'#!/bin/sh\nexit 0\n'
                info = tarfile.TarInfo('sing-box-1.14.3-linux-amd64/sing-box')
                info.mode = 0o755
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
            archive_bytes = payload.getvalue()
            (root / name).write_bytes(archive_bytes)
            release = {'tag_name': 'v1.14.3', 'draft': False, 'prerelease': False,
                       'assets': [{'name': name,
                                   'browser_download_url': 'https://github.com/SagerNet/sing-box/releases/download/v1.14.3/' + name,
                                   'digest': 'sha256:' + hashlib.sha256(archive_bytes).hexdigest()}]}
            (root / 'sing-box-1.14.3-release.json').write_text(json.dumps(release))
            target = root / 'stage' / 'sing-box'
            target.parent.mkdir()
            rescue.verified_asset(str(root), 'sing-box', '1.14.3', 'x86_64', str(target))
            self.assertEqual(target.read_bytes(), b'#!/bin/sh\nexit 0\n')
            self.assertEqual(target.stat().st_mode & 0o777, 0o755)

    def test_edge_probe_uses_only_requested_address_family_and_tcp_7844(self):
        calls = []

        def getaddrinfo(host, port, family, kind):
            calls.append((host, port, family, kind))
            return [(family if family != rescue.socket.AF_UNSPEC else rescue.socket.AF_INET,
                     rescue.socket.SOCK_STREAM, 0, '', (host, port))]

        class ProbeSocket:
            def __init__(self, *args):
                pass
            def __enter__(self):
                return self
            def __exit__(self, *args):
                return False
            def settimeout(self, timeout):
                self.timeout = timeout
            def connect(self, address):
                if address[0].startswith('region2'):
                    raise OSError('blocked')

        with patch.object(rescue.socket, 'getaddrinfo', side_effect=getaddrinfo), \
             patch.object(rescue.socket, 'socket', ProbeSocket):
            self.assertEqual(rescue.edge_probe('6'), 1)
        self.assertEqual(len(calls), 2)
        self.assertTrue(all(port == 7844 and family == rescue.socket.AF_INET6 and
                            kind == rescue.socket.SOCK_STREAM for _, port, family, kind in calls))


if __name__ == '__main__':
    unittest.main()
