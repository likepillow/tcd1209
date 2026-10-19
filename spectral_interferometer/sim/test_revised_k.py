from pathlib import Path
import sys
import tempfile
import unittest
import numpy as np
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'host'))
from position_ab_experiment import read_revised_k


class RevisedKTests(unittest.TestCase):
    def test_preserves_values_and_exact_bytes(self):
        values=np.linspace(7,8,1024)
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'K.txt'
            np.savetxt(path,values,fmt='%.17g')
            result,raw=read_revised_k(path)
            np.testing.assert_array_equal(result,values)
            self.assertEqual(raw,path.read_bytes())

    def test_bad_k_is_rejected_not_repaired(self):
        valid=np.linspace(7,8,1024)
        duplicate=valid.copy();duplicate[1]=duplicate[0]
        nonfinite=valid.copy();nonfinite[10]=float('nan')
        negative=valid-10
        for values in (valid[:512],valid[::-1],duplicate,nonfinite,negative):
            with self.subTest(size=len(values)),tempfile.TemporaryDirectory() as folder:
                path=Path(folder)/'K.txt';np.savetxt(path,values)
                before=path.read_bytes()
                with self.assertRaises(ValueError):
                    read_revised_k(path)
                self.assertEqual(path.read_bytes(),before)
