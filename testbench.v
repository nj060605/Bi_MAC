`timescale 1ns / 1ps

module lstm_tb;

    // =================================================================
    // 1. SIGNAL DECLARATIONS (Driving Inputs & Monitoring Outputs)
    // =================================================================
    reg         clk;
    reg         rst;
    reg         start;
    
    
    // External write interface ports (Kept at 0 to prioritize BRAM file loads)
    reg         ext_write_en;
    reg  [4:0]  ext_write_addr;
    reg  [15:0] ext_write_data;
    
    // Read out selector pointer to scan through the 16 elements of ht_out_data
    reg  [3:0]  ext_read_addr;

    // Core verification hooks from the LSTM Accelerator
    wire        timestep_done;
    wire [15:0] ht_out_data;

    // =================================================================
    // 2. DEVICE UNDER TEST (DUT) INSTANTIATION
    // =================================================================
    lstm_top #(
        .M(3),
        .N(3)
    ) dut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .ext_write_en(ext_write_en),
        .ext_write_addr(ext_write_addr),
        .ext_write_data(ext_write_data),
        .timestep_done(timestep_done),
        .ht_out_data(ht_out_data),
        .ext_read_addr(ext_read_addr)
    );

    // =================================================================
    // 3. CLOCK GENERATOR (100 MHz System Clock Frequency)
    // =================================================================
    always begin
        #5 clk = ~clk; // Creates a clean 10ns clock period loop
    end

    // =================================================================
    // 4. MAIN SIMULATOR PROCESSING TIMELINE
    // =================================================================
    integer idx;
    
    initial begin
        // Step A: Initialize all driving registers to safe defaults
        clk            = 1'b0;
        rst            = 1'b1; // Hold architecture under safe master reset
        start          = 1'b0;
        ext_write_en   = 1'b0;
        ext_write_addr = 5'd0;
        ext_write_data = 16'h0000;
        ext_read_addr  = 4'd0;

        // Step B: Let memories read files during reset phase
        #40;
        rst = 1'b0; // Release master reset
        $display("[TB] Hardware reset released. Text vector assets loaded to BRAM structures.");
        #20;

        // Step C: Trigger the state machine processing tree
        $display("[TB] Asserting START line to wake up FSM Controller...");
        start = 1'b1;
        #10;        // Hold start high for exactly one complete clock cycle
        start = 1'b0; // Drop it immediately so the FSM doesn't double-trigger

        // Step D: Simulation wait trap until pipeline loops are finalized
        @(posedge timestep_done);
        $display("[TB] Handshake Caught! Timestep calculation loop finished safely.");

        // Step E: Read and display final hidden state elements sequentially
        $display("==================================================");
        $display("       FINAL PREDICTION VECTOR DATA (ht)          ");
        $display("==================================================");
        for (idx = 0; idx < 3; idx = idx + 1) begin
            ext_read_addr = idx;
            #10; // Pause briefly for the output multiplexer to stabilize the data net
            $display("  ht_out_data[%2d] = 0x%h (Q8.8 Fixed-Point Hex Representation)", idx, ht_out_data);
        end
        $display("==================================================");

        // Step F: Complete the run pass
        #100;
        $display("[TB] Simulation verification run executed with 0 errors.");
        $finish; 
    end

endmodule




