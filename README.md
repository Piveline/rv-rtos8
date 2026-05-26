# RV-RTOS8
<img width="1983" height="793" alt="Piveline: RV-RTOS8 logo image" src="https://github.com/user-attachments/assets/b221cfee-6fd2-4438-9d2a-6c867678a8f6" />  
FreeRTOS porting on 8-stage pipelined RISC-V CPU with HDMI and keyboards

## Repository Structure
- `/FPGA` : Synthesizable Vivado project files on RV32 / RV64 implementations
- `/Firmware` : FreeRTOS Kernel + Shell firmware source codes
- `/RTL` : VerilogHDL RTL source codes for iverilog simulation

## Current Progress
- ✅ Rhealstone switch, preempt benchmark
- 📝 Full function support for FreeRTOS and verification with other 4 Rhealstone benchmarks.

## Overview
- This repository is about implementing **FreeRTOS** Kernel on 8-stage pipelined bare-metal RISC-V processor from **RV-IM100**.  
  - [FreeRTOS](https://github.com/FreeRTOS/FreeRTOS-Kernel):   
  **An open-source real-time operating system kernel** providing preemptive scheduling, software timers, and inter-task communication for resource-constrained embedded systems.
  - [RV-IM100](https://github.com/T410N/RV-IM100):   
  Design guidelines and performance analysis for 10 RISC-V 5- to 8-stage pipeline variants based on basic_RV32S and IMA_make_RV64, covering ISA extension scaling, pipeline-depth sweep, and 100 MHz(125) timing closure on Artix-7 FPGA.
- To make the fully working computing system, we've also implemented **HDMI display output** interface with **PS/2 keyboard input** interface.
- To verify the FreeRTOS implementation, we've benchmarked with **Rhealstone** within our **original shell program**.
  - [Rhealstone](https://github.com/javamonn/rtems-rhealstone):   
  A benchmark suite for evaluating real-time operating system performance, measuring key metrics such as task switching time, preemption time, interrupt latency, semaphore shuffling, message passing, and deadlock breaking.
  - We couldn't fine the original source code of Rhealstone, so we've ported RTEMS Rhealstone to FreeRTOS.

## Architecture
### Core Architecture
<img width="1340" height="621" alt="72F8SP_core_architecture" src="https://github.com/user-attachments/assets/41cd90d2-c21b-46dc-aede-a449d16c0d44" />  
<sup> RV64IM72F_8SP Core Architecture block diagram </sup>

- IF-IO-ID-EXR-EX-BR-MEM-WB : 8-Stage Pipeline
- We've revised several modules for FreeRTOS support.
  - trap-exception logic modules for ECALL & timer tick interaction from FreeRTOS.
  - CSR for CLINT support
- For more information, visit [RV-IM100 repository](https://github.com/T410N/RV-IM100)

### SoC Architecture
<img width="1166" height="648" alt="72F8SP_SoC_architecture" src="https://github.com/user-attachments/assets/6c720b52-c61e-404f-a128-95d0b37ce9ad" />  
<sup> 72F8SP_SoC Architecture block diagram </sup>

- Designed CLINT module for timer tick interactions
- Several modules added for UART TX, PS/2 keyboard input, HDMI display output

## Environment
- FPGA board
  - Digilent Nexys Video (AMD Xilinx Artix-7 XC7A200T-1SBG484C)
- AMD Vivado 2025.2

## Benchmarks
- Rhealstone   
**Table: Rhealstone-Derived Benchmark Results (FreeRTOS, 100 MHz)**

| Sub-benchmark | RV32 (cycles/iter) | RV64 (cycles/iter) | RV64 Overhead |
| ------------- | ------------------ | ------------------ | ------------- |
| Task Switch   | 320                | 439                | +37.2%        |
| Task Preempt  | 1,074              | 1,264              | +17.7%        |

<img width="1080" height="2408" alt="1779759036476" src="https://github.com/user-attachments/assets/41f6638d-bdcb-4633-a1fe-91d195974607" />

## Acknowledgment
### Contributors
- @T410N (Hyunwoo Kang) - Project Lead & Architecture design & Main debugging
- WIP
