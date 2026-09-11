# Guest reliability checks

[Prepare the bundled guest](../../Docs/Build.md), then run from the repository root on an Apple silicon Mac:

```sh
python3 Scripts/QA/check_reliability.py
```

The runner compiles a native Virtualization helper and tests a disposable APFS clone under `Artifacts/guest-reliability-*`. Factory and installed user machines stay untouched. Audio is discarded; no microphone is attached.

Checks cover cold boots, networking, read-only sharing, writable-file persistence, PCM playback, pause/resume, and live display resizing.

Inspect `host-report.json`, `exports/reliability-first.json`, `exports/reliability-second.json`, and serial logs in the artifact directory. The runner shuts down its VM on completion or failure and keeps these reports.

CPU samples include the helper and its Virtualization service; 100% means one logical core. Avoid starting another VM during measurement. RSS is not exclusive memory allocation. Workload timings measure CPU throughput, not compositor frame rate or GPU acceleration.

See [testing](../../Docs/Testing.md) and [validation](../../Docs/Validation.md) for other checks and recorded results.
