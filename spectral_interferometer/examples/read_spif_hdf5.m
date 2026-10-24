function data = read_spif_hdf5(filename, firstRow, count, resultFirst, resultCount)
% Read scientific HDF5 export; not a MAT file. S0 is returned frame x pixel.
% firstRow/count select S0 rows only. RESULT has its own independent rows.
% Join by segment_id + frame_id (+ calibration versions), never row number.
if nargin < 2, firstRow = 1; end
if nargin < 4, resultFirst = 1; end
if nargin < 5, resultCount = 0; end % Do not silently load millions of RESULT rows.
info = h5info(filename, '/spectra/s0');
total = info.Dataspace.Size(2); % Python/HDF5 file axes [frame,pixel] are reversed by MATLAB.
if nargin < 3, count = total-firstRow+1; end
assert(firstRow >= 1 && count >= 0 && firstRow+count-1 <= total, 'Invalid S0 row range');
if count == 0
    data.S0 = zeros(0,1024,'uint16');
    data.spectrum_frame_id = zeros(0,1,'uint32');
    data.spectrum_timestamp_ticks = zeros(0,1,'uint64');
    data.spectrum_segment_id = zeros(0,1,'uint32');
else
    data.S0 = h5read(filename,'/spectra/s0',[1 firstRow],[1024 count]).';
    data.spectrum_frame_id = h5read(filename,'/spectra/frame_id',firstRow,count);
    data.spectrum_timestamp_ticks = h5read(filename,'/spectra/timestamp_ticks',firstRow,count);
    data.spectrum_segment_id = h5read(filename,'/spectra/segment_id',firstRow,count);
end
if resultCount > 0
    data.distance = h5read(filename,'/results/distance',resultFirst,resultCount);
    data.result_frame_id = h5read(filename,'/results/frame_id',resultFirst,resultCount);
    data.result_segment_id = h5read(filename,'/results/segment_id',resultFirst,resultCount);
    data.result_timestamp_ticks = h5read(filename,'/results/timestamp_ticks',resultFirst,resultCount);
    data.result_flags = h5read(filename,'/results/flags',resultFirst,resultCount);
    data.result_invalid = logical(h5read(filename,'/results/invalid',resultFirst,resultCount));
end
data.integrity_ok = logical(h5readatt(filename,'/','integrity_ok'));
% Keep ticks as uint64. For local time differences, subtract integers BEFORE double conversion.
% TIME_VALID is bit 3 (mask 4). Do not fabricate time for old records without it.
end
