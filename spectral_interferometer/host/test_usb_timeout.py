import unittest
from dataclasses import replace
from usb_transport import Transfer


class TimeoutClassification(unittest.TestCase):
    def test_observed_idle_and_rejected_variants(self):
        idle = Transfer(False, 0, 997, b'', 0xC0000120, 0xC0010000, 205)
        self.assertTrue(idle.idle_timeout)
        for changes in ({'count': 1, 'data': b'x'}, {'elapsed_ms': 199},
                        {'nt_status': 0}, {'usbd_status': 0}, {'error': 1167},
                        {'success': True}, {'data': b'x'}):
            with self.subTest(changes=changes):
                self.assertFalse(replace(idle, **changes).idle_timeout)
        self.assertTrue(Transfer(False, 0, 121).idle_timeout)


if __name__ == '__main__':
    unittest.main()
