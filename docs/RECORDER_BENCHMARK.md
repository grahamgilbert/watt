# Recorder benchmark, October 29, 2026

One 60-second run of the debug collector and SQLite writer on the development Mac, with five-second polling. Other applications, including Watt's UI, were running. This is a short recorder measurement, not a battery-life test or an estimate of causal build slowdown.

| Measurement | Observed |
| --- | --- |
| Elapsed | 60.24 seconds |
| Frames persisted | 12 |
| Processes in last sample | 690 |
| Unavailable process queries in last sample | 311 |
| CPU cost | 0.261% of one core, averaged over the run |
| Sample plus SQLite write, median | 15.33 ms |
| Sample plus SQLite write, maximum | 18.48 ms |
| Payload written | 1,179,201 bytes |
| Database plus WAL/SHM after checkpoint | 1,253,376 bytes |
| Extrapolated payload at this rate | 1.58 GiB/day |

The extrapolation does not promise a retention duration: process count, process names, recording cadence, OS activity, indexing overhead, and database page reuse affect growth. It excludes the GUI, helper, model inference, and long-duration behavior. Release and overnight measurements and controlled builds remain to do.

Run `swift run Watt --benchmark` to repeat. The command records to a separate temporary database and removes that database afterward.
