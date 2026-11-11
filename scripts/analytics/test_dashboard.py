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

    def test_week_comparison_excludes_today_and_old_records(self):
        rows = [(NOW.date().isoformat(), 900)]
        rows += [((NOW-timedelta(days=i)).date().isoformat(), 2 if i<=7 else 1)
                 for i in range(1, 15)]
        rows += [((NOW-timedelta(days=15)).date().isoformat(), 900)]
        self.assertEqual(dashboard.weekly(rows, NOW), '14 за 7 полных дней · +7 к предыдущим 7 дням')
        self.assertEqual(dashboard.weekly([], NOW), '0 за 7 полных дней · +0 к предыдущим 7 дням')

    def test_zero_series_and_escaping_under_current_csp(self):
        p = dashboard.render({'observed_at_utc': NOW.isoformat(), 'account': {
            'account_versions': {'<img src=x onerror=alert(1)>': 1},
            'accounts_created_daily': [], 'retained_connections_daily': []}, 'hbbs': None})
        doc = Document(p)
        self.assertEqual(sum(tag=='svg' for tag, _ in doc.tags), 2)
        self.assertEqual(sum(tag=='rect' for tag, _ in doc.tags), 60)
        self.assertIn('&lt;img', p)
        self.assertFalse(any(tag in ('script', 'img', 'iframe', 'link') for tag, _ in doc.tags))
        self.assertFalse(any(any(k.startswith('on') for k in attrs) for _, attrs in doc.tags))
        self.assertNotIn('nan', p.lower())
        self.assertTrue(all(attrs.get('href', '#').startswith('#') and 'src' not in attrs
                            for _, attrs in doc.tags))


if __name__ == '__main__':
    unittest.main()
