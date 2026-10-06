from pathlib import Path

p = Path('client/src/plugin/mod.rs')
s = p.read_text(encoding='utf-8')
old = '''            Err(err) => {
                log::warn!(
                    "Failed to migrate legacy plugin directory {:?} to {:?}: {}; using legacy directory for this run",
                    legacy,
                    current,
                    err
                );
                return Ok(legacy);
            }
'''
new = '''            Err(err) => {
                log::warn!(
                    "Failed to migrate legacy plugin directory {:?} to {:?}: {}; continuing with FuntiDesk plugin namespace",
                    legacy,
                    current,
                    err
                );
            }
'''
count = s.count(old)
if count != 1:
    raise SystemExit(f'plugin fallback precondition failed: expected 1 match, found {count}')
s = s.replace(old, new, 1)
p.write_text(s, encoding='utf-8')
print('FUNTIDESK_PHASE26_STRICT_OK=true')
