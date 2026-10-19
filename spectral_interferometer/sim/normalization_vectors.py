"""Generate integer-vector fixtures and compare to direct floating division."""
import sys
from pathlib import Path
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/"host"))
from fixed import reciprocal_q30, normalize_q12


def generate(output):
    output=Path(output)
    output.mkdir(parents=True, exist_ok=True)
    rng=np.random.default_rng(9945)
    frame=rng.integers(0,4096,1024,dtype=np.int64)
    frame[:4]=[0,4095,4095,1]
    source=rng.integers(1,4096,1024,dtype=np.int64)
    source[:4]=[1,1,4095,4095]
    gains=reciprocal_q30(source)
    # The second calibration is markedly different, making a mixed bank visible.
    gains2=reciprocal_q30(np.full(1024,2048))
    arrays={"raw":frame,"gain":gains,"gain2":gains2}
    shifts=[]
    for suffix,g in (("",gains),("2",gains2)):
        s1,s2=normalize_q12(frame,g)
        arrays["s1"+suffix]=s1
        arrays["s2"+suffix]=s2 & ((1<<25)-1)
        magnitude=int(np.abs(s2).max())
        shifts.append(30-magnitude.bit_length() if magnitude else 0)
    arrays["shifts"]=shifts
    for name,a in arrays.items():
        (output/(name+".mem")).write_text("".join(f"{int(x):08x}\n" for x in a),encoding="ascii")
    exact=frame/source
    quantized=arrays["s1"]/4096
    bound=.5/4096+4095*.5/2**30
    error=float(np.max(np.abs(quantized-exact)))
    assert error<=bound
    print(f"1024 vectors; max S1 error={error:.9g}; analytical bound={bound:.9g}")


if __name__=="__main__": generate(sys.argv[1])
