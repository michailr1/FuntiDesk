from datetime import datetime, timezone, timedelta
from html.parser import HTMLParser
import unittest
import dashboard

NOW = datetime(2026, 11, 11, 12, tzinfo=timezone.utc)


class Document(HTMLParser):
    def __init__(self, page):
        super().__init__()
        self.tags = []
        self.feed(page)

    def handle_starttag(self, tag, attrs):
        self.tags.append((tag, dict(attrs)))


class DashboardTests(unittest.TestCase):
    def test_no_source_is_not_zero_activity(self):
        p = dashboard.render({'observed_at_utc': NOW.isoformat(), 'account': None, 'hbbs': None})
        self.assertIn('Нет данных', p)
        self.assertNotIn('<svg', p)
        self.assertIn('15:00 МСК', p)

    def test_selected_period_bounds_and_all_available(self):
        rows = [('2026-11-12',900),('2026-11-11',2),('2026-11-04',3),
                ('2026-11-03',4),('2026-08-01',5)]
        self.assertEqual(dashboard.daily(rows,NOW,7), [('2026-11-04',3),('2026-11-11',2)])
        self.assertIn(('2026-08-01',5),dashboard.daily(rows,NOW,None))
        self.assertNotIn(('2026-11-12',900),dashboard.daily(rows,NOW,None))

    def test_connections_hide_zero_dates_and_keep_calendar_comparison(self):
        rows = [('2026-11-11', 0), ('2026-11-10', 3), ('2026-11-08', 0), ('2026-11-05', 2)]
        page = dashboard.chart('Сеансы', 'История', rows, NOW, '#128c77', positive_only=True)
        self.assertNotIn('2026-11-08', page)
        self.assertNotIn('2026-11-11', page)
        self.assertIn('2026-11-10', page)
        self.assertIn('2026-11-05', page)
        self.assertEqual(sum(tag=='rect' for tag, _ in Document(page).tags), 2)
        self.assertIn('5 за выбранный период', page)
        empty = dashboard.chart('Сеансы', 'История', [], NOW, '#128c77', positive_only=True)
        self.assertNotIn('<svg', empty)
        self.assertIn('записей нет', empty)

    def test_id_registration_series_is_visible(self):
        page = dashboard.render({'observed_at_utc': NOW.isoformat(), 'account': None,
                                 'hbbs': {'registered_ids_daily': [('2026-11-10', 4)]}})
        self.assertIn('Новые регистрации ID', page)
        self.assertIn('2026-11-10: 4', page)
        self.assertIn('created_at', page)

    def test_all_three_daily_charts_hide_zero_days(self):
        rows = [('2026-11-10', 2), ('2026-11-09', 0)]
        page = dashboard.render({'observed_at_utc': NOW.isoformat(), 'account': {
            'accounts_created_daily': rows, 'retained_connections_daily': rows},
            'hbbs': {'registered_ids_daily': rows}})
        doc = Document(page)
        self.assertEqual(sum(tag=='svg' for tag, _ in doc.tags), 3)
        self.assertEqual(sum(tag=='rect' for tag, _ in doc.tags), 3)
        self.assertNotIn('<td>0</td>', page)
        self.assertEqual(page.count('2026-11-10: 2'), 3)
        self.assertEqual(page.count('11-10</text>'), 3)
        self.assertNotIn('2026-11-09', page)

    def test_native_period_controls_and_default(self):
        page = dashboard.render({'observed_at_utc': NOW.isoformat(), 'account':None, 'hbbs':None})
        doc = Document(page)
        radios = [a for t,a in doc.tags if t=='input' and a.get('type')=='radio']
        self.assertEqual(len(radios),4)
        self.assertEqual([a['id'] for a in radios if 'checked' in a],['range-30'])
        self.assertEqual({a['id'] for a in radios},{'range-7','range-30','range-90','range-all'})
        self.assertNotIn('<script',page)
        self.assertIn('только сохранившиеся записи за последние 90 дней',page)

    def test_zero_series_and_escaping_under_current_csp(self):
        p = dashboard.render({'observed_at_utc': NOW.isoformat(), 'account': {
            'account_versions': {'<img src=x onerror=alert(1)>': 1},
            'accounts_created_daily': [], 'retained_connections_daily': []}, 'hbbs': None})
        doc = Document(p)
        self.assertEqual(sum(tag=='svg' for tag, _ in doc.tags), 0)
        self.assertEqual(sum(tag=='rect' for tag, _ in doc.tags), 0)
        self.assertIn('&lt;img', p)
        self.assertFalse(any(tag in ('script', 'img', 'iframe', 'link') for tag, _ in doc.tags))
        self.assertFalse(any(any(k.startswith('on') for k in attrs) for _, attrs in doc.tags))
        self.assertNotIn('nan', p.lower())
        self.assertTrue(all(attrs.get('href', '#').startswith('#') and 'src' not in attrs
                            for _, attrs in doc.tags))


if __name__ == '__main__':
    unittest.main()
