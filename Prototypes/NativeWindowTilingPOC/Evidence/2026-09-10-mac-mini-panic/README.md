# Mac mini Ethernet/PCIe kernel panic — 2026-09-10

## Conclusion

The Mac restarted because Apple's `AppleT8132PCIe` kernel driver panicked after
the built-in 1 Gb Ethernet controller failed to complete a PCIe transaction.
The panic identifies the affected path as `apcie[2:lan-1gb]`. On this Mac, that
path maps to the onboard Broadcom 57762-A0 controller (`en0`) driven by
`AppleBCM5701Ethernet`.

The ATE-14 prototype was running at the time, but the evidence does not support
it as the direct cause. The panicked task was `kernel_task`; the backtrace is
entirely in Apple's PCIe stack. Both surviving prototype processes were waiting
in their AppKit event loops, used little CPU and memory, and have no networking
code. An independent M4 Mac mini report contains the same panic signature and
register values, so this failure can occur without Atelier.

The exact defect below the PCIe timeout cannot be isolated from a single panic.
It could be in the SoC PCIe host path, Ethernet controller, Apple driver or
firmware, or a power/link-state interaction. A cable or switch can change link
behavior, but the recorded failure is a PCIe completion timeout inside the Mac,
not an ordinary network packet or service error.

| Finding | Confidence |
| --- | --- |
| Immediate restart cause was an Apple PCIe/Ethernet kernel panic | Very high |
| Affected endpoint was the built-in Broadcom Ethernet controller | Very high |
| ATE-14 was not the direct panic source | High |
| Exact hardware, firmware, or driver defect beneath the timeout | Undetermined |

## Timeline

- Before the incident, two timed ATE-14 smoke-test launches remained alive after
  the runner reported that they had timed out. This was an error in the test
  procedure.
- `2026-09-10 21:55:20 -0500`: the epoch embedded in the panic records the
  kernel panic.
- Approximately `21:55:37`: retained unified logs show the next boot starting.
- `21:55:42`: macOS processed/wrote the panic report. This is the report header
  time, not the instant of the panic.
- After reboot, the prototype received a per-user single-instance lock so a
  second manager cannot register observers or hotkeys.

## Evidence

### Panic signature

The report's panic string begins:

```text
apcie[2:lan-1gb]::handleCompletionTimeoutInterrupt: completion timeout
```

It reports the PCIe link still in `L0`, the active link state, and points to
`AppleT8132PCIePort.cpp:1404`. The panicked task is PID 0, `kernel_task`. Its
backtrace includes `AppleEmbeddedPCIE` and `AppleT8132PCIe`, with no Atelier,
SkyLight, Accessibility, AppKit, or WindowServer frame.

The report also shows normal memory pressure: 12% of pages and 10% of segments
compressed, with compressor status `OK`. This is not an out-of-memory signature.
No third-party kernel extension appears in the panic backtrace.

### Hardware mapping

`system_profiler SPEthernetDataType SPNetworkDataType -detailLevel mini` maps the
built-in Ethernet interface to:

- Broadcom 57762-A0, vendor `0x14e4`, device `0x1682`
- PCIe x1 at 2.5 GT/s
- `com.apple.iokit.AppleBCM5701Ethernet`
- BSD interface `en0`, maximum link speed 1 Gb/s

The I/O Registry places that controller below `apcie[2:lan-1gb]`. Post-reboot
kernel logs independently show that path attaching PCI device `14e4:1682` and
`AppleBCM5701Ethernet`.

### State of the prototype processes

The panic snapshot contains both accidentally orphaned prototype processes:

| PID | User CPU | System CPU | Resident memory | Thread state |
| --- | ---: | ---: | ---: | --- |
| 41918 | 1.261 s | 0.787 s | 7.46 MB | All waiting |
| 42472 | 0.795 s | 0.477 s | 7.60 MB | All waiting |

Their main threads had run roughly two seconds before the snapshot, consistent
with the prototype's one-second reconciliation timer. Their other threads were
waiting in normal AppKit/event-loop states. Neither process appears in the
panicked thread or kernel backtrace. The program reads window and Space state
and uses Accessibility/AppKit APIs; it does not open or manage network devices.

This does not mathematically exclude every indirect timing interaction, but
there is no positive evidence connecting the processes to the failed Ethernet
PCIe transaction.

### System logs and prior history

The retained logs immediately before the panic contain routine Ethernet/PTP
messages and no recorded SkyLight, WindowServer, Accessibility, or prototype
fault. The final 35-second query contains no retained kernel messages. A panic
can prevent buffered logs from being flushed, so absence from that interval is
supporting context, not proof.

No earlier panic report was present in `/Library/Logs/DiagnosticReports`, making
this an isolated event in the locally retained history as of this review.

An Apple Support Community post from another M4 Mac mini records the exact same
`apcie[2:lan-1gb]` completion-timeout message, register values, and source line.
That is useful independent evidence that the signature predates and is not
specific to Atelier, but it is a user report rather than an Apple root-cause
statement.

## Separate operational issue: orphaned test processes

The smoke-test runner's timeout did not reliably terminate the long-running
child process even though its later process listing said none remained. Leaving
two managers active was unsafe test hygiene and made the temporal correlation
look suspicious. It should be treated as a separate contributing operational
issue, not as the panic root cause.

For future long-running prototype tests:

1. Run the executable in an interactive terminal and stop it explicitly with
   Control-C. Do not use a timed package-run command as lifecycle management.
2. Keep the per-user single-instance lock enabled.
3. Confirm shutdown with the operating system's process list, rather than only
   the launching tool's bookkeeping.
4. Avoid automated live tests of private APIs when compilation or unit tests are
   sufficient. Make live window-management tests deliberate and supervised.

## If it happens again

1. Record the wall-clock time and preserve the new panic report before changing
   the setup. Compare its panic string and backtrace with this incident.
2. Install available macOS updates. Apple recommends updating software first for
   repeated unexpected restarts.
3. Isolate the Ethernet path: test temporarily on Wi-Fi with Ethernet
   disconnected; if needed, try a known-good cable and a different switch/router
   port one variable at a time.
4. Run Apple Diagnostics. On Apple silicon, shut down, hold the power button
   until startup options appear, then hold Command-D. Disconnect nonessential
   peripherals as Apple directs.
5. If the same panic recurs, especially with Ethernet disconnected or after
   updates, give Apple the reports and diagnostics results for hardware/service
   evaluation.

Do not weaken SIP, change kernel boot arguments, or install replacement kernel
drivers as an attempted workaround.

## Sources and reproducibility

Local source files (not committed because diagnostic reports contain device and
process metadata):

- `/Library/Logs/DiagnosticReports/panic-full-2026-09-10-215542.0002.panic`
  - SHA-256: `be28227535dc9e0208aae3f2997e539443ecc77ea981b1de4562d46872785985`
- `/Library/Logs/DiagnosticReports/ResetCounter-2026-09-10-215544.diag`
  - SHA-256: `2e8d27446a625ed926df5e34292a44242fddc6d38a351ecf1457e5c7ed32626f`

External references:

- [Apple: If your Mac restarted because of a problem](https://support.apple.com/en-us/102382)
- [Apple: Use Apple Diagnostics to test your Mac](https://support.apple.com/en-us/102550)
- [Independent matching M4 Mac mini panic report](https://discussions.apple.com/thread/256181113)

The hardware inventory was deliberately documented without the interface MAC
address or other unique device identifiers.
