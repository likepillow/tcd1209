"""Inspect a staged real CCD capture without silently repairing K or lost data."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path

import numpy as np

from protocol import Decoder, Kind, INVALID, DISCONTINUITY, TIME_VALID, SequenceTracker


RANGES = [(0,1129999), (1140000,1149999), (1155000,1164999),
          (1173000,1179999), (1190000,1197999), (1202000,1209999),
          (1215000,1224999), (1230000,1237999), (1241000,1244999),
          (1250000,1252999), (1255000,0xfffffffe)]


def inspect(directory, output, sample_count=1000):
    directory, output = Path(directory), Path(output)
    output.mkdir(parents=True, exist_ok=False)
    source = np.loadtxt(directory/'S.txt')
    k = np.loadtxt(directory/'K.txt')
    manifest = json.loads((directory/'manifest.json').read_text(encoding='utf-8-sig'))
    if source.shape != (1024,) or k.shape != (1024,):
        raise ValueError('Expected 1024-point S/K')
    delta = np.diff(k)
    x = np.linspace(-1, 1, 1024)
    fits = []
    for degree in (1,2,3,4,5):
        fit = np.polynomial.polynomial.polyval(x, np.polynomial.polynomial.polyfit(x, k, degree))
        fits.append({'degree':degree, 'rms_residual':float(np.sqrt(np.mean((k-fit)**2))),
                     'max_residual':float(np.max(np.abs(k-fit))),
                     'monotonic':bool(np.all(np.diff(fit)>0) or np.all(np.diff(fit)<0))})
    rng = np.random.default_rng(1209)
    stages = [dict(count=0, invalid=0, discontinuity=0, min_frame=None,max_frame=None,
                   sum=np.zeros(1024), sumsq=np.zeros(1024), samples=[],ids=[], flags=[],epochs=Counter(),
                   period_ticks=Counter(), previous=None) for _ in RANGES]
    decoder, sequence, counts, flags = Decoder(), SequenceTracker(), Counter(), Counter()
    event_counts = [int(e['after_packet']) for e in manifest.get('metadata',{}).get('acquisition_events',[])]
    epoch, event_index, previous_frame, nonincreasing = 0,0,None,0
    event_boundaries, discont_ranges = [], []
    path = directory/'11处位置信号.spif'
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        while chunk := stream.read(1048576):
            digest.update(chunk)
            for packet in decoder.feed(chunk):
                counts[packet.kind.name] += 1
                sequence.observe(packet.sequence)
                flags[packet.flags] += 1
                if packet.kind == Kind.RAW:
                    if previous_frame is not None and packet.frame_id <= previous_frame:
                        nonincreasing += 1
                    previous_frame = packet.frame_id
                    if packet.flags & DISCONTINUITY:
                        if discont_ranges and discont_ranges[-1][1]+1 == packet.frame_id:
                            discont_ranges[-1][1] = packet.frame_id
                        else:
                            discont_ranges.append([packet.frame_id, packet.frame_id])
                    for index,(lo,hi) in enumerate(RANGES):
                        if lo <= packet.frame_id <= hi:
                            stage=stages[index]
                            raw=np.frombuffer(packet.payload,'<u2').astype(float)
                            stage['count']+=1
                            stage['invalid']+=int(bool(packet.flags & INVALID))
                            stage['discontinuity']+=int(bool(packet.flags & DISCONTINUITY))
                            stage['min_frame']=packet.frame_id if stage['min_frame'] is None else stage['min_frame']
                            stage['max_frame']=packet.frame_id
                            stage['sum']+=raw;stage['sumsq']+=raw*raw
                            stage['epochs'][epoch]+=1
                            if packet.flags & TIME_VALID:
                                if stage['previous'] is not None:
                                    oldframe,oldticks=stage['previous']
                                    if packet.frame_id>oldframe:
                                        ticks=(packet.timestamp-oldticks)/(packet.frame_id-oldframe)
                                        stage['period_ticks'][round(ticks,3)]+=1
                                stage['previous']=(packet.frame_id,packet.timestamp)
                            j = stage['count']-1 if stage['count']<=sample_count else int(rng.integers(stage['count']))
                            if j < sample_count:
                                entry=(raw.astype(np.uint16),packet.frame_id,packet.flags)
                                if j == len(stage['samples']):
                                    stage['samples'].append(entry[0]);stage['ids'].append(entry[1]);stage['flags'].append(entry[2])
                                else:
                                    stage['samples'][j],stage['ids'][j],stage['flags'][j]=entry
                            break
                while event_index<len(event_counts) and decoder.packets >= event_counts[event_index]:
                    event_boundaries.append({'after_packet':decoder.packets,'last_raw_frame':previous_frame,
                                             'settings':manifest['metadata']['acquisition_events'][event_index]})
                    epoch+=1;event_index+=1
    decoder.finish()
    stage_summary, means, stds, samples, ids, sample_flags, truth = [], [], [], [], [], [], []
    for index,stage in enumerate(stages):
        n=stage['count']
        mean=stage['sum']/max(n,1)
        std=np.sqrt(np.maximum(stage['sumsq']/max(n,1)-mean*mean,0))
        means.append(mean);stds.append(std)
        stage_summary.append({'step_um':index*5,'frames':n,'sampled_frames':len(stage['samples']),
            'first_frame':stage['min_frame'],'last_frame':stage['max_frame'],
            'invalid':stage['invalid'],'discontinuity':stage['discontinuity'],
            'epochs':dict(stage['epochs']),'period_ticks_modes':stage['period_ticks'].most_common(5),
            'mean_adc':float(mean.mean()),'temporal_std_rms_adc':float(np.sqrt(np.mean(std**2)))})
        samples.extend(stage['samples']);ids.extend(stage['ids']);sample_flags.extend(stage['flags'])
        truth.extend([index*5]*len(stage['samples']))
    result={'source_directory':str(directory.resolve()),'spif_sha256':digest.hexdigest(),
        'packets':dict(counts),'flags':dict(flags),'bad_crc':decoder.bad_crc,'bad_headers':decoder.bad_headers,
        'bad_payloads':decoder.bad_payloads,'discarded_bytes':decoder.discarded_bytes,
        'missing_packets':sequence.missing,'out_of_order_packets':sequence.out_of_order,
        'nonincreasing_raw_frames':nonincreasing,'acquisition_boundaries':event_boundaries,
        'discontinuity_ranges':discont_ranges,
        'K':{'min':float(k.min()),'max':float(k.max()),'first':float(k[0]),'last':float(k[-1]),
             'increases':int(np.count_nonzero(delta>0)),'decreases':int(np.count_nonzero(delta<0)),
             'equal_neighbors':int(np.count_nonzero(delta==0)),'polynomial_diagnostics':fits},
        'S':{'min':float(source.min()),'max':float(source.max()),'mean':float(source.mean())},
        'stages':stage_summary}
    np.savez_compressed(output/'samples.npz',frames=samples,frame_ids=ids,flags=sample_flags,
                        truth=truth,source=source,k=k,means=means,stds=stds)
    (output/'quality.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({key:value for key,value in result.items() if key!='discontinuity_ranges'},ensure_ascii=False,indent=2))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    inspect(args.directory,args.output)
