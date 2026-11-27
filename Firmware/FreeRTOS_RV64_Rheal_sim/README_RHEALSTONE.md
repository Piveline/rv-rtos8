# RV64 FreeRTOS Shell + Rhealstone commands

Added shell command:

```text
rheal <switch|preempt|msg|sem|deadlock|intr>
```

Examples:

```text
RV64> rheal switch
RV64> rheal preempt
RV64> rheal msg
RV64> rheal sem
RV64> rheal deadlock
RV64> rheal intr
```

Benchmark source files are in `rhealstone/` and are built by the included `Makefile`.
The benchmark output format is:

```text
Rhealstone: <name> - <avg> cycles
```

Notes:

- `FreeRTOSConfig.h` was changed to enable `INCLUDE_vTaskDelete` because the benchmark tasks self-delete after printing results.
- `configUSE_TICK_HOOK` was enabled for `rheal intr`.
- `rheal intr` uses `vApplicationTickHook()` as the timer ISR-side hook. It measures the path up to the FreeRTOS tick hook, so it is not a pure raw trap-vector-only latency number. If you want the original raw interrupt-latency definition, call `vBenchmarkTimerISR()` or an equivalent timestamp hook directly at the first point of your machine timer trap handler.
