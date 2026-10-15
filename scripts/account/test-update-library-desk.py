#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('library_update', Path(__file__).with_name('update-library-desk.py'))
update = importlib.util.module_from_spec(spec)
spec.loader.exec_module(update)


class LibraryUpdate(unittest.TestCase):
    def test_only_exact_api_image_setting_changes(self):
        original = b'FUNTI_ACCOUNT_KEY_FILE=/private/account.key\r\nFUNTI_ACCOUNT_IMAGE=old\r\nOTHER_IMAGE=keep\r\n'
        image = 'sha256:' + 'a' * 64
        result = update.image_env(original, image)
        self.assertEqual(result, original.replace(b'FUNTI_ACCOUNT_IMAGE=old', ('FUNTI_ACCOUNT_IMAGE=' + image).encode()))
        for broken in [b'OTHER=none\n', original + b'FUNTI_ACCOUNT_IMAGE=duplicate\n']:
            with self.assertRaises(RuntimeError):
                update.image_env(broken, image)
        with self.assertRaises(RuntimeError):
            update.image_env(original, 'other\nSETTING=bad')


if __name__ == '__main__':
    unittest.main()
