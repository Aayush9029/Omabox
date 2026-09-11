Run `python3 Scripts/QA/check_reliability.py` from the repository after preparing the bundled guest. It compiles a native Apple Virtualization helper and creates a disposable APFS clone under `Artifacts/guest-reliability-*`.

The helper attaches a discarded audio sink. PCM checks cannot play through the Mac speakers, and no microphone is attached. The guest receives one read-only source folder, a separate read-only fixture, and a writable test export folder. The factory and installed user machines remain untouched.

The run provisions a test owner, then verifies two cold desktop boots, NAT DNS and certificate-verified HTTPS, host-enforced read-only VirtioFS access, durable writable-share content across Linux boot IDs, and two seconds of stereo PCM playback. It checks three pause/resume cycles and confirms live display changes inside Hyprland at 1024 × 768 and 1440 × 900.

`host-report.json` records boot and lifecycle timings plus a 20-second idle CPU sample. CPU percentages use one fully occupied logical core as 100%, and include both the QA helper and its newly created Virtualization service. The sample rejects ambiguous concurrent VM service creation. Resident memory is the operating system's reported RSS, rather than a measure of exclusive physical allocation.

`exports/reliability-first.json` and `exports/reliability-second.json` record Linux checks and a deterministic SHA-256 workload. That workload measures guest CPU throughput; it does not measure compositor frame rate or GPU acceleration. Host load, caching, and software-renderer settings affect timing, so these are observations from the test machine rather than performance guarantees.

On completion or failure the runner shuts down its disposable VM. Serial logs and JSON reports remain in its artifact directory for inspection.
