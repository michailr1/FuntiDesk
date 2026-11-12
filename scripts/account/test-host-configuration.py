#!/usr/bin/env python3
"""Host configuration must be explicit before deployment can change anything."""
import importlib.util
import os
from pathlib import Path
import unittest
from unittest.mock import patch


HERE = Path(__file__).parent
ENTRIES = {'stage': 'stage', 'activate': 'activate',
           'update-web': 'update', 'update-browser': 'update'}


def load(name, environment):
    spec = importlib.util.spec_from_file_location(name, HERE / (name + '-desk.py'))
    module = importlib.util.module_from_spec(spec)
    with patch.dict(os.environ, environment, clear=True):
        spec.loader.exec_module(module)
    return module


class HostConfiguration(unittest.TestCase):
    def test_missing_or_relative_root_stops_before_external_commands(self):
        for name, entry in ENTRIES.items():
            for environment in [{}, {'FUNTI_CADDY_ROOT': 'relative/proxy'}]:
                with self.subTest(name=name, environment=environment):
                    module = load(name, environment)
                    with patch.object(module, 'load' if name == 'update-web' else 'run') as run:
                        with self.assertRaisesRegex(RuntimeError, 'FUNTI_CADDY_ROOT'):
                            getattr(module, entry)()
                        run.assert_not_called()

    def test_private_absolute_root_controls_both_paths(self):
        for name in ENTRIES:
            module = load(name, {'FUNTI_CADDY_ROOT': '/srv/custom-proxy'})
            self.assertEqual(module.CADDY, Path('/srv/custom-proxy/Caddyfile'))
            if hasattr(module, 'BASE'):
                self.assertEqual(module.BASE, Path('/srv/custom-proxy/docker-compose.yml'))

    def test_missing_or_multiline_spf_stops_before_docker_or_file_creation(self):
        module = load('prepare', {})
        for value in ['', 'v=spf1 mx\nother-record', 'v=spf1 mx\rother-record']:
            with patch.dict(os.environ, {'FUNTI_ACCOUNT_SPF_RECORD': value}, clear=True), patch.object(module, 'run') as run:
                with self.assertRaisesRegex(RuntimeError, 'FUNTI_ACCOUNT_SPF_RECORD'):
                    module.prepare(Path('/unused-artifact'))
                run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
