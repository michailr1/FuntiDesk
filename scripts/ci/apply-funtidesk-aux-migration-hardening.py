from pathlib import Path

p = Path('client/libs/hbb_common/src/config.rs')
s = p.read_text(encoding='utf-8')
replacements = [
    ('fs::copy(&legacy_path, &path)', 'Config::copy_legacy_config_file(&legacy_path, &path)', 1, 'peer load migration'),
    ('fs::copy(&source, &target)', 'Config::copy_legacy_config_file(&source, &target)', 1, 'bulk peer migration'),
    ('fs::copy(&legacy, &path)', 'Config::copy_legacy_config_file(&legacy, &path)', 2, 'address-book/group migration'),
]
for old, new, expected, label in replacements:
    count = s.count(old)
    if count != expected:
        raise SystemExit(f'{label}: expected {expected} matches, found {count}')
    s = s.replace(old, new)
if s.count('fs::copy(') != 0:
    raise SystemExit(f'unexpected fs::copy remains in config.rs: {s.count("fs::copy(")}')
p.write_text(s, encoding='utf-8')
print('FUNTIDESK_AUX_MIGRATION_HARDENING_OK=true')
