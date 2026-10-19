import unittest
from check_hardware_capture import analyze


def fixture():
    rows = []
    for n in range(8192):
        frame, index = divmod(n, 2048)
        values = {"index[10:0]": index, "frame_id[31:0]": frame,
                  "timestamp[63:0]": 1000 + frame * 42280,
                  "first_1": int(index == 0), "last_1": int(index == 2047),
                  "valid_1": 1, "fault_1": 0, "busy_1": 1, "configured_1": 1,
                  "locked_1": 1, "board_reset_n_1": 1, "release_pipe_1[3:3]": 1,
                  "run_1": 1, "hold_reset_1": 0, "data[11:0]": 0,
                  "ad_data_IBUF[11:0]": 0}
        row = {key: format(value, "x") for key, value in values.items()}
        row["Sample in Buffer"] = str(n)
        rows.append(row)
    return rows


class HardwareCaptureTests(unittest.TestCase):
    def test_zero_is_framed_but_not_optically_valid(self):
        result = analyze(fixture())
        self.assertTrue(result["all_adc_zero"])
        self.assertTrue(result["framing_valid"])
        self.assertIn("unverified", result["optical_validity"])

    def test_index_corruption(self):
        rows = fixture()
        rows[1024]["index[10:0]"] = "401"
        with self.assertRaisesRegex(ValueError, "index"):
            analyze(rows)

    def test_fault_rejected(self):
        rows = fixture()
        rows[5]["fault_1"] = "1"
        with self.assertRaisesRegex(ValueError, "fault"):
            analyze(rows)

    def test_wrong_frame_period(self):
        rows = fixture()
        for row in rows[2048:4096]:
            row["timestamp[63:0]"] = format(1000 + 42281, "x")
        with self.assertRaisesRegex(ValueError, "period"):
            analyze(rows)


if __name__ == "__main__":
    unittest.main()
