import assert from 'node:assert/strict';
import test from 'node:test';
import {t,setLanguage} from '../src/i18n.js';
import {errorText} from '../src/session.js';
import {displaySize} from '../src/files-ui.js';
test('English UI translates security errors and keeps interpolated computer data intact',()=>{
  setLanguage('en');
  assert.equal(errorText('invalid_identity'),'Could not verify the computer’s key. Connection stopped.');
  assert.equal(t('Получен {name}. Сохраните на устройство.',{name:'Файлы'}),'Received Файлы. Save it to your device.');
  assert.equal(displaySize(1024),'1 KB');
  setLanguage('ru');assert.equal(t('Session ended.'),'Сеанс завершён.');assert.equal(displaySize(1024),'1 КБ');
});
