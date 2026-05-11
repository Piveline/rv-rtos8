`timescale 1ns/1ps

module CSRFile_tb;
    reg         clk;
    reg         reset;
    reg         trapped;
    reg         mret_executed;
    reg         csr_write_enable;
    reg  [11:0] csr_read_address;
    reg  [11:0] csr_write_address;
    reg  [31:0] csr_write_data;
    reg instruction_retired;
    reg timer_interrupt_pending;

    // PTH sideband test signals
    reg         pre_trap_handler;
    reg  [31:0] enter_pc;
    reg  [31:0] trap_cause;
    wire [31:0] vector_address;
    wire [31:0] return_address;

    wire [31:0] csr_read_out;
    wire        csr_ready;

    wire        mstatus_mie;
    wire        mie_mtie;

    CSRFile csr_file (
        .clk(clk),
        .clk_enable(1'b1), // Always enabled for testing
        .reset(reset),
        .trapped(trapped),
        .mret_executed(mret_executed),
        .csr_write_enable(csr_write_enable),
        .csr_read_address(csr_read_address),
        .csr_write_address(csr_write_address),
        .csr_write_data(csr_write_data),
        .instruction_retired(instruction_retired),
        .valid_csr_address(1'b1), // Assume all addresses are valid for testing
        .timer_interrupt_pending(timer_interrupt_pending),

        .pre_trap_handler(pre_trap_handler),
        .enter_pc(enter_pc),
        .trap_cause(trap_cause),
        .vector_address(vector_address),
        .return_address(return_address),

        .csr_read_out(csr_read_out),
        .csr_ready(csr_ready), 

        .mstatus_mie(mstatus_mie),
        .mie_mtie(mie_mtie)
    );

    // Generate clock signal, 10ns.
    initial clk = 0;
    always #5 clk = ~clk;

    initial begin
        $dumpfile("./testbenches/results/waveforms/CSR_File.vcd");
        $dumpvars(0, CSRFile_tb);
    end

    initial begin
        $display("==================== CSR File Test START ====================");
        
        // Reset to DEFAULT value, Initialize signals.
        reset = 1;
        trapped = 0;
        mret_executed = 0;
        timer_interrupt_pending = 0;
        csr_write_enable = 0;
        csr_read_address = 12'h000;
        csr_write_address = 12'h000;
        csr_write_data = 32'h0;
        instruction_retired = 0;
        pre_trap_handler = 0;
        enter_pc = 32'h0;
        trap_cause = 32'h0;
        #10;
        reset = 0;
        #10;
        
        // Test 1: Read-only CSRs read.
        csr_read_address = 12'hF11; #10; 
        $display("mvendorid = %h (expected 52564B43)", csr_read_out);
        
        csr_read_address = 12'hF12; #10; 
        instruction_retired = 1'b1; #10;
        instruction_retired = 1'b0;
        $display("marchid = %h (expected 34365335)", csr_read_out);
        
        csr_read_address = 12'hF13; #10;
        $display("mimpid = %h (expected 34364931)", csr_read_out);

        csr_read_address = 12'hF14; #10; 
        $display("mhartid = %h (expected 524B4330)", csr_read_out);

        csr_read_address = 12'h300; #10; 
        $display("mstatus = %h (expected 00001800)", csr_read_out);

        csr_read_address = 12'h301; #10; 
        $display("misa = %h (expected 40000100)", csr_read_out);
        
        // Test 2: MRW CSRs' reset value check
        csr_read_address = 12'h305; #10; 
        $display("mtvec (reset) = %h (expected 00001000)", csr_read_out);
        csr_read_address = 12'h341; #10; 
        $display("mepc  (reset) = %h (expected 00000000)", csr_read_out);
        csr_read_address = 12'h342; #10; 
        $display("mcause(reset) = %h (expected 00000000)", csr_read_out);

        // Test 3: csrrw; mtvec
        csr_read_address = 12'h305; #10; 
        $display("mtvec = %h (expected 00001000)", csr_read_out);

        csr_write_address = 12'h305;
        csr_write_data = 32'h00003000;
        csr_write_enable = 1;
        #10;

        csr_write_enable = 0;
        #10;

        csr_read_address = 12'h305; #10; 
        $display("mtvec = %h (expected 00003000)", csr_read_out);
        
        // Test 4: csrrw; mepc
        csr_read_address = 12'h341; #10;
        $display("mepc = %h (expected 00000000)", csr_read_out);

        csr_write_address = 12'h341;
        csr_write_data = 32'h00004000;
        csr_write_enable = 1;
        #10;

        csr_write_enable = 0;
        #10;

        csr_read_address = 12'h341; #10; 
        $display("mepc = %h (expected 00004000)", csr_read_out);
        
        // Test 5: csrrw; mcause
        csr_read_address = 12'h342; #10; 
        $display("mcause = %h (expected 00000000)", csr_read_out);

        csr_write_address = 12'h342;
        csr_write_data = 32'h00000004;
        csr_write_enable = 1;
        #10;

        csr_write_enable = 0;
        #10;

        csr_read_address = 12'h342;
        #10;

        $display("mcause = %h (expected 00000004)", csr_read_out);
        
        // Test 6: csrrw; Read-only's write ignore test.
        csr_read_address = 12'hF11; #10; 
        $display("Read-only test : mvendorid = %h (expected 52564B43)", csr_read_out);

        csr_write_address = 12'hF11;
        csr_write_data = 32'h00003000;
        csr_write_enable = 1;
        #10;

        csr_write_enable = 0;
        #10;

        csr_read_address = 12'hF11;
        #10;

        $display("Write ignored : mvendorid = %h (expected 52564B43)", csr_read_out);
        
        // Test 7: mcycle/minstret auto-increment check (read-only counters)
        csr_read_address = 12'hB00; #10;
        $display("mcycle (lower 32-bit) = %h (auto-incremented, not 0)", csr_read_out);
        
        csr_read_address = 12'hB80; #10;
        $display("mcycleh (upper 32-bit) = %h (should be 0, no overflow yet)", csr_read_out);
        
        csr_read_address = 12'hB02; #10;
        $display("minstret (lower 32-bit) = %h (should be 1, one instruction retired in Test 1)", csr_read_out);
        
        csr_read_address = 12'hB82; #10;
        $display("minstreth (upper 32-bit) = %h (should be 0, no overflow yet)", csr_read_out);

        // Test 8: Read-only test for mcycle - write should be ignored
        csr_read_address = 12'hB00; #10;
        $display("mcycle (before write attempt) = %h", csr_read_out);

        csr_write_address = 12'hB00;
        csr_write_data = 32'h12345678;
        csr_write_enable = 1;
        #10;

        csr_write_enable = 0;
        #10;

        csr_read_address = 12'hB00; #10;
        $display("mcycle (after write attempt) = %h (write should be ignored, auto-incremented)", csr_read_out);
        
        // Test 9: Read-only test for mcycleh - write should be ignored
        csr_read_address = 12'hB80; #10;
        $display("mcycleh (before write attempt) = %h", csr_read_out);

        csr_write_address = 12'hB80;
        csr_write_data = 32'hABCDEF00;
        csr_write_enable = 1;
        #10;

        csr_write_enable = 0;
        #10;

        csr_read_address = 12'hB80; #10;
        $display("mcycleh (after write attempt) = %h (write should be ignored, should remain 0)", csr_read_out);
        
        // Test 10: Read-only test for minstret - write should be ignored
        csr_read_address = 12'hB02; #10;
        $display("minstret (before write attempt) = %h", csr_read_out);

        csr_write_address = 12'hB02;
        csr_write_data = 32'hDEADBEEF;
        csr_write_enable = 1;
        #10;

        csr_write_enable = 0;
        #10;

        csr_read_address = 12'hB02; #10;
        $display("minstret (after write attempt) = %h (write should be ignored, should remain 1)", csr_read_out);
        
        // Test 11: Read-only test for minstreth - write should be ignored
        csr_read_address = 12'hB82; #10;
        $display("minstreth (before write attempt) = %h", csr_read_out);

        csr_write_address = 12'hB82;
        csr_write_data = 32'hCAFEBABE;
        csr_write_enable = 1;
        #10;

        csr_write_enable = 0;
        #10;

        csr_read_address = 12'hB82; #10;
        $display("minstreth (after write attempt) = %h (write should be ignored, should remain 0)", csr_read_out);
        
        // Test 12: mcycle auto-increment verification
        $display("\n=== Auto-increment verification ===");
        csr_read_address = 12'hB00; 
        #10;
        $display("mcycle at T0 = %h", csr_read_out);
        #20; // Wait 2 cycles
        csr_read_address = 12'hB00; 
        #10;
        $display("mcycle at T0+2 = %h (should be +2 from previous)", csr_read_out);
        
        // Test 13: minstret increment with instruction_retired
        $display("\n=== instruction_retired test ===");
        csr_read_address = 12'hB02;
        #10;
        $display("minstret before retired = %h", csr_read_out);
        
        instruction_retired = 1;
        #10;
        instruction_retired = 0;
        csr_read_address = 12'hB02;
        #10;
        $display("minstret after 1 retired = %h (should be +1)", csr_read_out);
        
        instruction_retired = 1;
        #10;
        instruction_retired = 1;
        #10;
        instruction_retired = 0;
        csr_read_address = 12'hB02;
        #10;
        $display("minstret after 2 more retired = %h (should be +2)", csr_read_out);

        csr_read_address = 12'h344; #10;
        $display("mip = %b (MTIP should be 0)", csr_read_out);
        timer_interrupt_pending = 1;
        #20;
        csr_read_address = 12'h344; #10;
        $display("mip = %b (MTIP should be 1)", csr_read_out);

        // Test 14: Trap & mret Verification
        $display("\n=== Test 14: Trap & mret Verification ===");

        csr_write_address = 12'h300; 
        csr_write_data = 32'h00000008;
        csr_write_enable = 1; #10;
        csr_write_enable = 0; #10;
        
        csr_read_address = 12'h300; #10;
        $display("Before Trap: mstatus = %h (Expected MIE=1, MPIE=0 -> 00001808)", csr_read_out);

        trapped = 1; #10;
        trapped = 0; #10;
        
        csr_read_address = 12'h300; #10;
        $display("After Trap:  mstatus = %h (Expected MIE=0, MPIE=1 -> 00001880)", csr_read_out);

        mret_executed = 1; #10;
        mret_executed = 0; #10;
        
        csr_read_address = 12'h300; #10;
        $display("After mret:  mstatus = %h (Expected MIE=1, MPIE=1 -> 00001888)", csr_read_out);

        //-----------------------
        $display("\n=== Test 15: mscratch R/W Test ===");
        csr_read_address = 12'h340; #10; 
        $display("mscratch (reset) = %h (expected 00000000)", csr_read_out);
        
        csr_write_address = 12'h340;
        csr_write_data = 32'hDEADBEEF; 
        csr_write_enable = 1; #10;
        csr_write_enable = 0; #10;
        
        csr_read_address = 12'h340; #10;
        $display("mscratch (after write) = %h (expected DEADBEEF)", csr_read_out);

        $display("\n=== Test 16: mie (12'h304) and Output Wires Test ===");
        csr_write_address = 12'h304; 
        csr_write_data = 32'h00000080; 
        csr_write_enable = 1; #10;
        csr_write_enable = 0; #10;

        csr_read_address = 12'h304; #10;
        $display("mie = %h (expected 00000080)", csr_read_out);
        $display("mie_mtie wire output = %b (expected 1)", mie_mtie);
        $display("mstatus_mie wire output = %b (current MIE state)", mstatus_mie);

        //---------------



        //-----------------------
        $display("\n=== Test 17: PTH Sideband Path Test ===");

        // 17-1. Set mtvec through the normal CSR write path.
        csr_write_address = 12'h305;
        csr_write_data    = 32'h00007000;
        csr_write_enable  = 1'b1;
        #10;
        csr_write_enable  = 1'b0;
        #10;

        csr_read_address = 12'h305;
        #10;
        $display("PTH mtvec setup: mtvec = %h (expected 00007000)", csr_read_out);

        // 17-2. Enable MIE so trap entry should save MIE into MPIE and clear MIE.
        csr_write_address = 12'h300;
        csr_write_data    = 32'h00000008; // MIE=1, MPIE=0, MPP is hardwired to 11 in DUT
        csr_write_enable  = 1'b1;
        #10;
        csr_write_enable  = 1'b0;
        #10;

        csr_read_address = 12'h300;
        #10;
        $display("Before PTH: mstatus = %h (expected 00001808)", csr_read_out);

        // 17-3. Assert pre_trap_handler and trapped in the same trap-entry cycle.
        // vector_address is combinational, so it should expose mtvec immediately
        // while pre_trap_handler is high, before the next clock edge commits mepc/mcause.
        enter_pc         = 32'h0000028C;
        trap_cause       = 32'h80000007; // Machine timer interrupt
        pre_trap_handler = 1'b1;
        trapped          = 1'b1;
        #1;
        $display("During PTH before posedge: vector_address = %h (expected 00007000)", vector_address);
        $display("During PTH before posedge: return_address = %h (expected 00004000)", return_address);
        #9;
        $display("During PTH after posedge: vector_address = %h (expected 00007000)", vector_address);
        $display("During PTH after posedge: return_address = %h (expected 0000028C)", return_address);

        pre_trap_handler = 1'b0;
        trapped          = 1'b0;
        #1;
        $display("After PTH deassert: vector_address = %h (expected 00000000)", vector_address);
        $display("After PTH deassert: return_address = %h (expected 00000000)", return_address);
        #9;

        // 17-4. Check that PTH sideband wrote mepc/mcause and trap entry updated mstatus.
        csr_read_address = 12'h341;
        #10;
        $display("After PTH: mepc = %h (expected 0000028C)", csr_read_out);

        csr_read_address = 12'h342;
        #10;
        $display("After PTH: mcause = %h (expected 80000007)", csr_read_out);

        csr_read_address = 12'h300;
        #10;
        $display("After PTH: mstatus = %h (expected 00001880)", csr_read_out);

        // 17-5. Normal CSR write must be blocked while pre_trap_handler is active.
        // Try to write mepc through normal CSR path while PTH writes another PC.
        csr_write_address = 12'h341;
        csr_write_data    = 32'hDEADBEEF;
        enter_pc          = 32'h00000ABC;
        trap_cause        = 32'h80000007;
        pre_trap_handler  = 1'b1;
        csr_write_enable  = 1'b1;
        #10;
        pre_trap_handler  = 1'b0;
        csr_write_enable  = 1'b0;
        #10;

        csr_read_address = 12'h341;
        #10;
        $display("PTH priority over CSR write: mepc = %h (expected 00000ABC, not DEADBEEF)", csr_read_out);

        // Final values
        $display("\n=== Final Counter Values ===");
        csr_read_address = 12'hB00; #10;
        $display("Final mcycle[31:0] = %h", csr_read_out);
        
        csr_read_address = 12'hB80; #10;
        $display("Final mcycle[63:32] = %h", csr_read_out);
        $display("Final Full mcycle = 0x%h_%h", csr_file.mcycle[63:32], csr_file.mcycle[31:0]);
        
        csr_read_address = 12'hB02; #10;
        $display("Final minstret[31:0] = %h", csr_read_out);
        
        csr_read_address = 12'hB82; #10;
        $display("Final minstret[63:32] = %h", csr_read_out);
        $display("Final Full minstret = 0x%h_%h", csr_file.minstret[63:32], csr_file.minstret[31:0]);
        
        $display("\n====================  CSR File Test END  ====================");

        $stop;
    end
    
endmodule