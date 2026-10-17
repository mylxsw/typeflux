# GUL-405: one bounded sample during GGUF loading

The authorized one-shot capture succeeded. It identifies the sampled loader path, but does not demonstrate a product defect or complete media acceptance. PR648 remains a draft. GUL-405 and GUL-383 remain in progress; GUL-406 was not read or started. No further model observation was performed.

The existing diagnostic helper and MediaProbe were cloned from the previous stage-budget build and hash-verified in 0.223 s. Their SHA-256 values remain `2c6ee0c667df2cb2c68fcd1297710eb063bd233817ff747687262e41a618a54b` and `532b5b25a901b786042f581836f33a3f69388fe277dc0365887b3b2d146b42ab`. No application, probe, native archive, helper, or weights were rebuilt. The 2,448 production inputs match the preceding head. Existing inventories of 2,316 accepted objects, 465 modules/resources and 2,722 actual link objects remain retained in the parent directory; no new object verification or coverage build is claimed.

The driver watches native stages at 100 ms intervals. The first `model-begin` must belong to a recorded descendant with the exact helper executable and process start identity. It requires 12 s for the tool plus 2 s for cleanup before both the probe's 40 s cutoff and parent's 60 s limit. A failed gate or profiler invocation consumes the only attempt. It does not alter the production budget or SIGSTOP/SIGCONT behavior.

| Measurement | Result |
| --- | --- |
| Entire screenshot observation, including preparation/cleanup | 51.652 s, exit 1, zero vectors |
| Native PID | 46138, parent MediaProbe 45968 |
| Swift entry / model begin on probe clock | 24.132 s / 25.380 s |
| Stage-to-driver trigger | 0.063075 s |
| Remaining time at gate | 14.557 s |
| `/usr/bin/sample 46138 1 1 -file …` | Exit 0, 6.901 s including processing/symbolication |
| Captured samples | 786, all on the main thread |
| Observed native CPU progress | 0.04 s over 30.981 s of live process snapshots |
| Observed native states | 19 T, 5 U; these are samples, not duration measurements |

The complete call graph is in `current-stack.txt`; `call-graph.txt` is a verbatim extract. Every sample follows:

```text
Encoder.init
  llama_model_load_from_file
    llama_model_loader
      gguf_init_from_file / gguf_init_from_reader
        gguf_read_emplace_helper<std::basic_string<char>>
          gguf_reader::read(std::basic_string<char>&)
            gguf_file_reader_callback -> fread -> __read_nocancel
```

The string reader appears at two call sites (400 and 386 samples). This is evidence of a metadata-reading path during the sampled interval. It is not a measured read completion time or proof of one stuck read. No sampled frame identifies tensor mmap/page-in, lock contention, projector setup, context creation or inference. The last native marker remains `model-begin`. A one-second sample cannot exclude those operations elsewhere in the full request.

The request lasted 31.959 s. The same actual TaskLocal budget accounted for 309 yields and 28.326 s of yield time, with a 0.1545 s rounding bound. The remaining 3.633 s includes I/O, scheduling and uncounted in-flight yield time; it is not CPU time. The enabled budget can suspend the helper. Without per-PID signal pairs and syscall completion events, these stacks cannot distinguish storage latency, I/O scheduling/throttling and suspension. The 8,752 KiB sampled footprint does not establish or rule out a system memory cause. No parameter adjustment or speculative product fix follows from this evidence.

Cancellation occurred at probe time 40.852 s and ownership retirement at 40.968 s. All three recorded PIDs (45968, 46121, 46138) were absent during the final check, no external cleanup signal was needed, and the private runtime directory was removed. SQLite snapshots contain no chunks or media vectors. Raw coverage profiles were retained without exporting coverage. The diagnostic binary supplies no final product media pass.

Validation: Python syntax and the initial seven sampling-contract tests passed in 0.145 s. Self-review found that the PID identity query could consume part of the cleanup reserve; the final driver checks the deadline again after that query. Only the three affected/new methods were then checked, passing in 0.114 s. The exact executed driver is retained under `runtime-tools/run_probe.py`; `final-driver-diff.patch.gz` records the reserve guard added afterward. No inference was repeated for this tool-only correction. The final test set contains eight distinct methods, all exercised across those two passes. Product changed-line coverage is reused: native helper 4/4; application, file helper and media runtime each 0/0 N/A. The new diagnostic tooling does not create a product coverage claim.

Self-review covered first-stage selection, process ownership and start identity, both cutoffs, partial profiler output, cancellation without vector publication, private files, child retirement and evidence/source consistency. The final reserve correction was the only issue found and fixed. Hardware: Apple M4, Mac16,10, 16 GiB; macOS 26.6.2. The observer uses accepted Debug coverage objects and the optimized diagnostic helper; this is not a Release latency benchmark or UI responsiveness test.

Stop here. A concrete next diagnostic, if separately authorized, would correlate the exact owned helper's GGUF read entry/completion events with per-PID SIGSTOP/SIGCONT timestamps under the unchanged budgets and cutoffs. This would separate read progress from suspended residency before choosing a fix. Another identical screenshot run or longer timeout alone does not meet that condition. Screenshot visual/OCR persistent retrieval, real 30/25 audio-boundary retrieval and short-video scene/actual-time retrieval remain incomplete. No audio/video, successful CPU-text, accepted document test or old coverage run was repeated.
