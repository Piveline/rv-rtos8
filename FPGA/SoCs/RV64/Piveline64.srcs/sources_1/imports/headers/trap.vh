`ifndef TRAP_VH
`define TRAP_VH

`define TRAP_NONE		4'b0000
`define TRAP_EBREAK		4'b0001            // breakpoint 
`define TRAP_ECALL		4'b0010              // environment call from M-mode
`define TRAP_MISALIGNED_INSTRUCTION	4'b0011 // instruction address misaligned
`define TRAP_MRET       4'b0100
`define TRAP_FENCEI     4'b0101
`define TRAP_MISALIGNED_STORE 4'b0110    // store access fault
`define TRAP_MISALIGNED_LOAD 4'b0111    // load access fault
//`define TRAP_ILLEGAL_INSTRUCTION 4'b1000
`define TIMER_INTERRUPT_IRQ 4'b1000        // Signal indicating an external timer interrupt has occurred.

`endif // TRAP_VH