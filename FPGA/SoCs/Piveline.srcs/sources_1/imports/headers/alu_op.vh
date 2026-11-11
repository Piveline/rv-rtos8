`ifndef ALU_OP_VH
`define ALU_OP_VH

`define ALU_OP_ADD	    5'b00000
`define ALU_OP_SUB	    5'b00001
`define ALU_OP_AND	    5'b00010
`define ALU_OP_OR	    5'b00011
`define ALU_OP_XOR	    5'b00100
`define ALU_OP_SLT	    5'b00101
`define ALU_OP_SLTU	    5'b00110
`define ALU_OP_SLL	    5'b00111
`define ALU_OP_SRL	    5'b01000
`define ALU_OP_SRA	    5'b01001
`define ALU_OP_MUL      5'b01010
`define ALU_OP_MULH     5'b01011
`define ALU_OP_MULHSU   5'b01100
`define ALU_OP_MULHU    5'b01101
`define ALU_OP_DIV      5'b01110
`define ALU_OP_DIVU     5'b01111
`define ALU_OP_REM	    5'b10000
`define ALU_OP_REMU     5'b10001
`define ALU_OP_ABJ	    5'b11110
`define ALU_OP_NOP      5'b11111

`endif // ALU_OP_VH