
`timescale 1ns / 1ps

//MAC UNIT

//Defining the 
module MAC (
    input  wire [15:0] weight_in,
    input  wire [15:0] data_in,
    input  wire        valid_in,
    input  wire        clear,
    input  wire        clk,
    input  wire        rst,
    output reg  [15:0] result,
    output reg         valid_out
);
    reg signed [31:0] accumulator; 
    wire signed [31:0] product;

    // Combinational fixed-point multiplier
    assign product = ($signed(weight_in) * $signed(data_in)) >>> 8;
      
    always @(posedge clk) begin
        if (rst == 1'b1) begin
            accumulator <= 32'h0;
            result      <= 16'h0;
            valid_out   <= 1'b0;   
        end 
        else begin
            if (clear == 1'b1) begin
                // 1. DUMP the completed previous row's sum out to the bias adder
                result    <= accumulator[15:0]; 
                valid_out <= 1'b1;
                
                // 2. THE SEED: Capture Row 1 Element 0 instantly as the new starting base!
                if (valid_in)
                    accumulator <= product;
                else
                    accumulator <= 32'h0;
            end 
            else begin
                valid_out <= 1'b0;
                if (valid_in == 1'b1) begin
                    accumulator <= accumulator + product;
                end
            end
        end
    end
endmodule


//BIAS ADDER
module bias_adder (
    input  wire        clk,
    input  wire [15:0] mac_result,
    input  wire [15:0] bias_in,
    input  wire        valid_in,
    output reg  [15:0] result_out,
    output reg         valid_out,
    input  wire        rst
);
    always @(posedge clk) begin
        if (rst) begin
            result_out <= 16'h0000;
            valid_out  <= 1'b0;
        end 
        else if (valid_in == 1'b1) begin
            result_out <= mac_result + bias_in;
            valid_out  <= 1'b1;
        end 
        else begin
            valid_out  <= 1'b0;
        end
    end
endmodule


//SIGMOID
//2-cycle latency
module sigmoid_approx (
    input  wire        clk,
    input  wire [15:0] x_in,
    input  wire        rst,
    input  wire        valid_in,
    output reg  [15:0] y_out,
    output reg         valid_out
);
    localparam [15:0] POS_2_0 = 16'h0200; 
    localparam [15:0] VAL_0_5 = 16'h0080; 
    localparam [15:0] VAL_1_0 = 16'h0100; 
    
    reg signed [15:0] x_stage1;
    reg        [15:0] abs_x;
    reg        [15:0] raw_y; 
    reg               valid_stage1;
    
    always @(posedge clk) begin
        if (rst == 1'b1) begin
            x_stage1     <= 16'h0;
            abs_x        <= 16'h0;
            valid_stage1 <= 1'b0;
            y_out        <= 16'h0;
            valid_out    <= 1'b0;
        end 
        else begin
            if (valid_in) begin
                valid_stage1 <= 1'b1;
                x_stage1     <= $signed(x_in);
                if ($signed(x_in) < 0)
                    abs_x    <= -$signed(x_in);
                else
                    abs_x    <= $signed(x_in);
            end 
            else begin
                valid_stage1 <= 1'b0;
            end
         
            if (valid_stage1 == 1'b1) begin
                valid_out <= 1'b1; 
                
                // THE STANDARD HARD-SIGMOID CONTINUOUS EQUATION
                if (abs_x >= POS_2_0) begin
                    raw_y = VAL_1_0; // Safely saturated at exactly 1.0
                end 
                else begin
                    raw_y = VAL_0_5 + (abs_x >> 2); // 0.5 + 0.25x
                end

                // Apply sign mapping
                if (x_stage1 < 0) 
                    y_out <= VAL_1_0 - raw_y; // 1.0 - y
                else 
                    y_out <= raw_y;
            end 
            else begin
                valid_out <= 1'b0;
            end
        end
    end      
endmodule
// =================================================================
// 4. TANH APPROXIMATION (FIXED: Blocking assignments for raw_y)
// =================================================================
//2-cycle latency
module tanh_approx (
    input  wire        clk,
    input  wire [15:0] x_in,
    input  wire        rst,
    input  wire        valid_in,
    output reg signed [15:0] y_out,
    output reg         valid_out
);
    // Boundaries for Hard Tanh
    localparam signed [15:0] POS_1_0 = 16'h0100;
    localparam signed [15:0] NEG_1_0 = 16'hFF00; // -1.0 in Two's Complement

    reg signed [15:0] x_stage1;
    reg               valid_stage1;

    always @(posedge clk) begin
        if (rst) begin
            x_stage1     <= 16'h0;
            valid_stage1 <= 1'b0;
            y_out        <= 16'h0;
            valid_out    <= 1'b0;
        end
        else begin
            // ─── STAGE 1: Register the input (Maintains FSM timing!) ───
            if (valid_in) begin
                valid_stage1 <= 1'b1;
                x_stage1     <= $signed(x_in);
            end
            else begin
                valid_stage1 <= 1'b0;
            end

            // ─── STAGE 2: The Hard Tanh Clamp ───
            if (valid_stage1) begin
                valid_out <= 1'b1;
                
                if (x_stage1 >= POS_1_0)
                    y_out <= POS_1_0;           // Ceiling clamp at +1.0
                else if (x_stage1 <= NEG_1_0)
                    y_out <= NEG_1_0;           // Floor clamp at -1.0
                else
                    y_out <= x_stage1;          // Linear pass-through (y = x)
            end
            else begin
                valid_out <= 1'b0;
            end
        end
    end
endmodule
// =================================================================
// 5. ELEMENT-WISE MULTIPLIER (Renamed from ele to element_mult)
// =================================================================
//1-cycle latency
module element_mult (
    input  wire        clk,
    input  wire [15:0] a_in,
    input  wire [15:0] b_in,
    input  wire        valid_in,
    output reg  [15:0] result_out,
    output reg         valid_out,
    input  wire        rst
);
    wire signed [31:0] product;
    assign product = $signed(a_in) * $signed(b_in);
    
    always @(posedge clk) begin 
        if (rst) begin
            result_out <= 16'h0000;
            valid_out  <= 1'b0;
        end 
        else if (valid_in) begin
            result_out <= product[23:8];
            valid_out  <= 1'b1;
        end 
        else begin
            valid_out  <= 1'b0;
        end
    end
endmodule

// =================================================================
// 6. VECTOR ADDER
// =================================================================

//1-cycle latency
module vector_adder (
    input  wire        clk,
    input  wire        valid_in,
    input  wire        rst,
    input  wire [15:0] a_in,
    input  wire [15:0] b_in,
    output reg  [15:0] result_out,
    output reg         valid_out
);
    wire [16:0] adder;
    assign adder = $signed(a_in) + $signed(b_in);
    
    always @(posedge clk) begin
        if (rst) begin
            result_out <= 16'h0000;
            valid_out  <= 1'b0;
        end 
        else if (valid_in) begin
            result_out <= adder[15:0]; 
            valid_out  <= 1'b1;
        end 
        else begin
            valid_out  <= 1'b0;
        end
    end
endmodule


// =================================================================
// 7. INPUT MEMORY
// =================================================================


module Input_memory #(
    parameter M = 3,
    parameter N = 3,
    parameter Total_words = M + N,
    parameter Addr_width = $clog2(Total_words)
)(
    input  wire                  clk,
    input  wire                  write_en,
    input  wire [Addr_width-1:0] write_addr, 
    input  wire [15:0]           write_data,
    input  wire [Addr_width-1:0] read_addr,
    output reg  [15:0]           data_out
);
    reg [15:0] memory [0:Total_words-1];
    
    // FIXED 9: Behavioral simulator block wipes X values to prevent false testbench propagation
    integer i;
    initial begin
        for (i = 0; i < Total_words; i = i + 1) begin
            memory[i] = 16'h0000;
        end
        $readmemh("input_data.txt", memory);
    end
    
    always @(posedge clk) begin
        if (write_en)
            memory[write_addr] <= write_data;
        data_out <= memory[read_addr];        
    end   
endmodule

// =================================================================
// 8. WEIGHT MEMORY (ANSI parameterized, added $readmemh simulation initialization)
// =================================================================


module weight_memory #(
    parameter M = 3,
    parameter N = 3,
    parameter Total_words = 4 * N * (M + N),
    parameter Addr_width = $clog2(Total_words)
)(
    input  wire                  clk,
    // Port A Interface (Dedicated to MAC1 Execution Path)
    input  wire [Addr_width-1:0] read_addr_a,
    output reg  [15:0]           weight_out_a,
    
    // Port B Interface (Dedicated to MAC2 Execution Path)
    input  wire [Addr_width-1:0] read_addr_b,
    output reg  [15:0]           weight_out_b
);
    reg [15:0] weight_mem [0:Total_words-1];
     
    initial begin
        $readmemh("weight_data.txt", weight_mem);
    end

    always @(posedge clk) begin
        weight_out_a <= weight_mem[read_addr_a];
        weight_out_b <= weight_mem[read_addr_b];
    end
endmodule
// ======================================================================
// 9. BIAS MEMORY (ANSI parameterized, explicit sizing logic calculation)
// ======================================================================

module bias_memory #(
    parameter N = 3,
    parameter ADDR_WIDTH = $clog2(N),
    parameter total_word = 4 * N
)(
    input  wire                    clk,
    input  wire                    rst, 
    input  wire [1:0]              gate_select,
    input  wire [ADDR_WIDTH-1:0]   read_addr,
    output reg  [15:0]             bias_out
);
    reg [15:0] bias_mem [0:total_word-1];
    
    initial begin
        $readmemh("bias_data.txt", bias_mem);
    end

    wire [ADDR_WIDTH+1:0] bias_addr = ({2'b00, gate_select} * N) + read_addr;

    always @(posedge clk) begin
        if (rst) begin
            bias_out <= 16'h0000;
        end 
        else begin
            // HARDWARE ARMOR: If requested address is out of bounds, return 0!
            if (bias_addr < total_word)
                bias_out <= bias_mem[bias_addr];
            else
                bias_out <= 16'h0000; // Traps undefined memory space leaks
        end
    end     
endmodule

// =================================================================
// 10. CT CELL STATE REGISTER
// =================================================================
module ct_reg #(
    parameter N = 3,
    parameter ADDR_WIDTH = $clog2(N)
)(
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  seq_rst,
    input  wire                  write_en,
    input  wire [ADDR_WIDTH-1:0] write_addr,
    input  wire [15:0]           data_in,
    input  wire [ADDR_WIDTH-1:0] read_addr,
    output wire [15:0]           data_out 
);
    reg [15:0] ct_mem [0:N-1];
    integer i;
    
    always @(posedge clk) begin
        if (rst || seq_rst) begin
            for (i = 0; i < N; i = i + 1) begin
                ct_mem[i] <= 16'h0000;
            end
        end 
        else if (write_en && (write_addr < N)) begin
            ct_mem[write_addr] <= data_in;
        end
    end
    
    // HARDWARE ARMOR: Clamp out-of-bounds reads
    assign data_out = (read_addr < N) ? ct_mem[read_addr] : 16'h0000;
    
endmodule    

// ==================================================================
// 11. HT HIDDEN STATE REGISTER (ANSI style, Guarded Handshake Logic)
// ==================================================================


module ht_register #(
    parameter N = 3,
    parameter ADDR_WIDTH = $clog2(N)
)(
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  ht_valid_clear,
    input  wire                  write_en,
    input  wire [ADDR_WIDTH-1:0] write_addr,
    input  wire [15:0]           data_in,
    input  wire [ADDR_WIDTH-1:0] read_addr,
    output wire [15:0]           data_out,
    output reg                   ht_to_mem_valid
);
    reg [15:0] ht [0:N-1];
    integer i;
    
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < N; i = i + 1) begin
                ht[i] <= 16'h0000;
            end
            ht_to_mem_valid <= 1'b0;
        end 
        else begin 
            if (write_en && (write_addr < N)) begin
                ht[write_addr] <= data_in;
            end
            
            if (ht_valid_clear) begin
                ht_to_mem_valid <= 1'b0;
            end 
            else if (write_en && (write_addr == (N - 1))) begin
                ht_to_mem_valid <= 1'b1; 
            end
        end
    end
    
    // HARDWARE ARMOR: Clamp out-of-bounds reads
    assign data_out = (read_addr < N) ? ht[read_addr] : 16'h0000;
    
endmodule



module input_address #(
    parameter N = 3,
    parameter M = 3,
    parameter TOTAL_WORDS = N + M,                 // 6
    parameter TOTAL_MATRIX_BEATS = N * TOTAL_WORDS, // 18
    parameter ADDR_WIDTH = $clog2(TOTAL_WORDS)
)(
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  start,    
    output reg  [ADDR_WIDTH-1:0] read_adr, 
    output reg                   valid_out,
    output reg                   done       
);
    reg [$clog2(TOTAL_MATRIX_BEATS):0] beat_counter;
    reg running;

    always @(posedge clk) begin
        if (rst) begin
            read_adr     <= 0;
            valid_out    <= 1'b0;
            done         <= 1'b0;
            running      <= 1'b0;
            beat_counter <= 0;
        end 
        else begin
            if (start) begin
                running      <= 1'b1;
                read_adr     <= 0;       // Present Addr 0 instantly
                valid_out    <= 1'b0;    // Beat 0: Hold valid LOW while BRAM fetches D0!
                done         <= 1'b0;
                beat_counter <= 1;
            end 
            else if (running) begin
                // Increment our global matrix beat tracker
                beat_counter <= beat_counter + 1;

                // Unstoppable modulo rollover (0 to 5)
                if (read_adr == TOTAL_WORDS - 1) 
                    read_adr <= 0;
                else 
                    read_adr <= read_adr + 1;

                // ─── VALID & KILL SWITCH LOGIC ───
                // We need valid_out = 1 for Beats 1 through 18. 
                // On Beat 18, we issue our final valid tick, but kill 'running' 
                // so that on Beat 19, the code falls into the 'else' and drops valid to 0!
                if (beat_counter == TOTAL_MATRIX_BEATS) begin
                    running   <= 1'b0;
                    valid_out <= 1'b1; // The 18th and final valid accumulation tick!
                    done      <= 1'b1; // Tell FSM we are done
                end 
                else begin
                    valid_out <= 1'b1; 
                    done      <= 1'b0;
                end
            end 
            else begin
                valid_out <= 1'b0; // Parked car: Engine is OFF. MAC ignores the bus.
                done      <= 1'b0;
            end
        end
    end
endmodule
module weight_address #(
    parameter N = 3,
    parameter M = 3,
    parameter WEIGHTS_PER_GATE = N * (N + M),      // 18
    parameter TOTAL_WEIGHTS    = 4 * WEIGHTS_PER_GATE,
    parameter ADDR_WIDTH       = $clog2(TOTAL_WEIGHTS)
)(
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  start,
    input  wire [1:0]            gate_sel, 
    output reg                   row_done,    // Triggers delayed MAC clears
    output reg                   all_done,    // Handshake to Master FSM
    output reg  [ADDR_WIDTH-1:0] weight_addr
);
    reg [$clog2(WEIGHTS_PER_GATE):0] flat_counter;
    reg [$clog2(N+M):0]              col_blinker; 
    reg                              running;
    reg [ADDR_WIDTH-1:0]             base_reg;

    always @(posedge clk) begin
        if (rst) begin
            running      <= 1'b0;
            flat_counter <= 0;
            col_blinker  <= 0;
            weight_addr  <= 0;
            row_done     <= 1'b0;
            all_done     <= 1'b0;
            base_reg     <= 0;
        end 
        else begin
            if (start) begin
                running      <= 1'b1;
                flat_counter <= 1;
                col_blinker  <= 1;
                row_done     <= 1'b0;
                all_done     <= 1'b0;
                base_reg     <= gate_sel * WEIGHTS_PER_GATE;
                weight_addr  <= gate_sel * WEIGHTS_PER_GATE; // Present Addr 0 instantly
            end 
            else if (running) begin
                // 1. Pulse row_done high on the 6th, 12th, and 18th beats
                if (col_blinker == (N + M)) begin
                    col_blinker <= 1;
                    row_done    <= 1'b1; 
                end else begin
                    col_blinker <= col_blinker + 1;
                    row_done    <= 1'b0;
                end

                // 2. Strict 18-Beat Kill Switch
                if (flat_counter == WEIGHTS_PER_GATE) begin
                    running  <= 1'b0;
                    all_done <= 1'b1; // Gate complete!
                end else begin
                    flat_counter <= flat_counter + 1;
                    weight_addr  <= base_reg + flat_counter;
                end
            end 
            else begin
                row_done <= 1'b0;
                all_done <= 1'b0;
            end
        end
    end
endmodule

// =============================================================================
// 14. GATE OUTPUT BUFFER (FIXED: Clear port, array renamed, memory wiped on rst)
// ==============================================================================

module gate_buffer #(
    parameter N = 3,
    parameter addr_width = $clog2(N)
)(
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  clear, 
    input  wire                  write_en,
    input  wire [addr_width-1:0] write_addr,
    input  wire [15:0]           data_in,
    input  wire [addr_width-1:0] read_addr,
    output wire [15:0]           data_out,
    output reg                   full
);
    reg [15:0] mem_array [0:N-1];
    integer idx;
    
    always @(posedge clk) begin
        if (rst || clear) begin
            full <= 1'b0;
            for (idx = 0; idx < N; idx = idx + 1) begin
                mem_array[idx] <= 16'h0000;
            end
        end 
        else begin
            // Guard writes
            if (write_en && (write_addr < N)) begin
                mem_array[write_addr] <= data_in;
                
                if (write_addr == (N - 1)) begin
                    full <= 1'b1;  
                end 
            end
        end
    end
    
    // HARDWARE ARMOR: Clamp out-of-bounds reads to 0 to prevent XXXX in simulation
    assign data_out = (read_addr < N) ? mem_array[read_addr] : 16'h0000;
    
endmodule


module fsm_controller (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    output reg         timestep_done,
    
    // Handshake Inputs (Kept for compatibility)
    input  wire        mac1_done, mac2_done, emult_done, adder_done,
    input  wire        ft_reg_full, it_reg_full, ct_tilde_full, ot_reg_full,
    input  wire        ct_state_full, tanh_done, ht_reg_full, partial_ct_done, 
    
    // Outputs
    output reg         stream_start, mac1_start, mac2_start,
    output reg  [1:0]  mac1_gate_sel, mac2_gate_sel,
    output reg         mac1_act_sel, mac2_act_sel,
    output reg         emult_start,
    output reg  [1:0]  emult_a_sel, emult_b_sel,
    output reg         adder_start,
    output reg         ft_write_en, it_write_en, ct_write_en, ot_write_en,
    output reg         new_ct_write, new_ht_write,
    output reg         sequence_rst, buffer_clear, ht_valid_clear, stage_rst, tanh_ct_start,
    output wire [3:0]  current_state_out
);
    reg [3:0] current_state, next_state;
    reg [4:0] state_timer; // THE STOPWATCH
    
    assign current_state_out = current_state;

    localparam STATE_0_IDLE          = 4'd0,
               STATE_1_STREAM_INPUT  = 4'd1,
               STATE_2_STORE_STAGE1  = 4'd2,
               STATE_3_STAGE2_PARAL  = 4'd3,
               STATE_4_STORE_STAGE2  = 4'd4,
               STATE_5_COMBINE_CT    = 4'd5,
               STATE_6_STORE_CT      = 4'd6,
               STATE_7_TANH_CT       = 4'd7,
               STATE_8_COMPUTE_HT    = 4'd8,
               STATE_9_STORE_HT      = 4'd9,
               STATE_10_DONE         = 4'd10;

    // 1. State Register
    always @(posedge clk) begin
        if (rst) current_state <= STATE_0_IDLE;
        else     current_state <= next_state;
    end

    // 2. The Deterministic Stopwatch
    always @(posedge clk) begin
        if (rst || (current_state != next_state))
            state_timer <= 0; // Reset timer instantly on every state change
        else
            state_timer <= state_timer + 1;
    end

   // =========================================================
    // 3. MATHEMATICAL CYCLE BUDGETS (Updated for Bubble Flushes)
    // =========================================================
    always @(*) begin
        next_state = current_state;
        case (current_state)
            STATE_0_IDLE: begin
                if (start) next_state = STATE_1_STREAM_INPUT;
            end
            STATE_1_STREAM_INPUT: begin
                if (ft_reg_full && ct_tilde_full) next_state = STATE_3_STAGE2_PARAL;
            end
            STATE_2_STORE_STAGE1: begin
                if (ft_reg_full && ct_tilde_full) next_state = STATE_3_STAGE2_PARAL;
            end
            STATE_3_STAGE2_PARAL: begin
                if (it_reg_full && ot_reg_full) next_state = STATE_4_STORE_STAGE2;
            end
            
            STATE_4_STORE_STAGE2: begin
                // ADDED 1 CYCLE FLUSH: 1 Bubble + 3 Data Beats + 1 Delay = 5 Cycles
                if (state_timer == 4'd5) next_state = STATE_5_COMBINE_CT;
            end
            STATE_5_COMBINE_CT: begin
                if (state_timer == 4'd3) next_state = STATE_6_STORE_CT;
            end
            STATE_6_STORE_CT: begin
                if (state_timer == 4'd1) next_state = STATE_7_TANH_CT;
            end
            STATE_7_TANH_CT: begin
                if (state_timer == 4'd5) next_state = STATE_8_COMPUTE_HT;
            end
            STATE_8_COMPUTE_HT: begin
                // ADDED 1 CYCLE FLUSH: 1 Bubble + 3 Data Beats + 1 Delay = 5 Cycles
                if (state_timer == 4'd5) next_state = STATE_9_STORE_HT;
            end
            
            STATE_9_STORE_HT: begin
                if (state_timer == 4'd1) next_state = STATE_10_DONE;
            end
            STATE_10_DONE: begin
                next_state = STATE_0_IDLE;
            end
            default: next_state = STATE_0_IDLE;
        endcase
    end

    // =========================================================
    // 4. SYNCHRONOUS OUTPUT ENGINE (With Bubble Guards)
    // =========================================================
    always @(posedge clk) begin
        if (rst) begin
            stream_start   <= 0; mac1_start     <= 0; mac2_start     <= 0;
            mac1_gate_sel  <= 0; mac2_gate_sel  <= 0; mac1_act_sel   <= 0; mac2_act_sel   <= 0;
            emult_start    <= 0; emult_a_sel    <= 0; emult_b_sel    <= 0; adder_start    <= 0; 
            ft_write_en    <= 0; it_write_en    <= 0; ct_write_en    <= 0; ot_write_en    <= 0; 
            new_ct_write   <= 0; new_ht_write   <= 0; sequence_rst   <= 0; timestep_done  <= 0;
            buffer_clear   <= 1; ht_valid_clear <= 1; stage_rst      <= 0; tanh_ct_start  <= 0;
        end 
        else begin
            stream_start   <= 0; mac1_start     <= 0; mac2_start     <= 0; emult_start    <= 0; 
            adder_start    <= 0; ft_write_en    <= 0; it_write_en    <= 0; ct_write_en    <= 0; 
            ot_write_en    <= 0; new_ct_write   <= 0; new_ht_write   <= 0; sequence_rst   <= 0; 
            timestep_done  <= 0; buffer_clear   <= 0; ht_valid_clear <= 0; stage_rst      <= 0; 
            tanh_ct_start  <= 0;

            if (current_state != next_state) begin
                stage_rst <= 1'b1;
                if (next_state == STATE_0_IDLE) buffer_clear <= 1'b1;
            end

            case (next_state)
                STATE_0_IDLE: begin
                    // Resting
                end
                STATE_1_STREAM_INPUT: begin
                    if (current_state != STATE_1_STREAM_INPUT) begin
                        stream_start <= 1'b1; mac1_start <= 1'b1; mac2_start <= 1'b1;
                    end
                    mac1_gate_sel <= 2'b00; mac2_gate_sel <= 2'b10;
                    mac1_act_sel  <= 1'b0;  mac2_act_sel  <= 1'b1;
                    ft_write_en   <= 1'b1;  ct_write_en   <= 1'b1;  
                end
                STATE_2_STORE_STAGE1: begin
                    ft_write_en <= 1'b1; ct_write_en <= 1'b1;
                end
                STATE_3_STAGE2_PARAL: begin
                    if (current_state != STATE_3_STAGE2_PARAL) begin
                        stream_start <= 1'b1; mac1_start <= 1'b1; mac2_start <= 1'b1;
                    end
                    mac1_gate_sel <= 2'b01; mac2_gate_sel <= 2'b11;
                    mac1_act_sel  <= 1'b0;  mac2_act_sel  <= 1'b0;
                    
                    emult_start   <= 1'b1;  emult_a_sel   <= 2'b00; emult_b_sel <= 2'b00;
                    it_write_en   <= 1'b1;  ot_write_en   <= 1'b1;  
                end
                STATE_4_STORE_STAGE2: begin
                    // THE BUBBLE GUARD: Forces a 1-cycle reset flush on entry
                    if (current_state == STATE_4_STORE_STAGE2) begin
                        emult_start <= 1'b1; 
                        emult_a_sel <= 2'b01; 
                        emult_b_sel <= 2'b01;  
                    end
                end
                STATE_5_COMBINE_CT: begin
                    adder_start  <= 1'b1;
                    new_ct_write <= 1'b1; 
                end
                STATE_6_STORE_CT: begin
                    new_ct_write <= 1'b1;
                end
                STATE_7_TANH_CT: begin
                    tanh_ct_start <= 1'b1;
                end
                STATE_8_COMPUTE_HT: begin
                    // THE BUBBLE GUARD: Forces a 1-cycle reset flush on entry
                    if (current_state == STATE_8_COMPUTE_HT) begin
                        emult_start  <= 1'b1;
                        emult_a_sel  <= 2'b10; 
                        emult_b_sel  <= 2'b10;
                        new_ht_write <= 1'b1;
                    end
                end
                STATE_9_STORE_HT: begin
                    new_ht_write <= 1'b1;
                end
                STATE_10_DONE: begin
                    timestep_done <= 1'b1; ht_valid_clear <= 1'b1;
                end
            endcase
        end
    end
 endmodule

module lstm_top #(
    parameter M = 3,
    parameter N = 3,
    parameter INPUT_WORDS = M + N,
    parameter WEIGHT_WORDS = 4 * N * (M + N),
    parameter IN_ADDR_W = $clog2(INPUT_WORDS),
    parameter WT_ADDR_W = $clog2(WEIGHT_WORDS),
    parameter STATE_ADDR_W = $clog2(N)
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    
    // External Sensor Write Bus Interface
    input  wire                    ext_write_en,
    input  wire [IN_ADDR_W-1:0]    ext_write_addr,
    input  wire [15:0]             ext_write_data,
    wire [3:0] fsm_current_state,
    // Output Interface
    output wire                    timestep_done,
    output wire [15:0]             ht_out_data,
    input  wire [STATE_ADDR_W-1:0] ext_read_addr
    
);

    // ==================================================================
    // STRUCTURAL BUS CONNECTIONS & INTERNAL INTERCONNECTS
    // ==================================================================
    wire         ctrl_stream_start, ctrl_mac1_start, ctrl_mac2_start;
    wire [1:0]   ctrl_mac1_gate_sel, ctrl_mac2_gate_sel;
    wire         ctrl_mac1_act_sel, ctrl_mac2_act_sel;
    wire         ctrl_emult_start, ctrl_adder_start;
    wire [1:0]   ctrl_emult_a_sel, ctrl_emult_b_sel;
    wire         ctrl_ft_write, ctrl_it_write, ctrl_ct_write, ctrl_ot_write;
    wire         ctrl_new_ct_write, ctrl_new_ht_write, ctrl_seq_rst;
    wire         ctrl_buffer_clear, ctrl_ht_clear;
    wire         ctrl_stage_rst;

    // Address Generator Routing Buses
    wire [IN_ADDR_W-1:0]    addr_input_read;
    wire                    addr_input_valid;
    wire                    addr_input_done;
    
    // DUAL WEIGHT GENERATION BUS ROUTING NETS
    wire [WT_ADDR_W-1:0]    addr_weight_bus_A;
    wire [WT_ADDR_W-1:0]    addr_weight_bus_B;
    wire                    addr_row_done_A;
    wire                    addr_row_done_B;
    wire                    addr_matrix_done_A;
    wire                    addr_matrix_done_B;
    
    // Shared Memory System Output Interconnects
    wire [IN_ADDR_W-1:0]    mux_input_memory_addr;
    wire [15:0]             data_from_input_mem;
    wire [15:0]             data_from_weight_mem_A; 
    wire [15:0]             data_from_weight_mem_B; 
    wire [15:0]             data_from_bias_mem1;
    wire [15:0]             data_from_bias_mem2;

    // Computational Block Processing Pipelines
    wire [15:0] mac1_to_adder, mac2_to_adder;
    wire        mac1_valid_out, mac2_valid_out;
    wire [15:0] adder1_out, adder2_out;
    wire        adder1_valid, adder2_valid;
    wire [15:0] sig1_out, tanh1_out, sig2_out;
    wire        sig1_valid, tanh1_valid, sig2_valid;
    
    // Dynamic Arithmetic Multiplexer Nodes
    reg  [15:0] selected_act1_data, selected_act2_data;
    reg         selected_act1_valid, selected_act2_valid;
    reg  [15:0] emult_mux_a, emult_mux_b;

    // Intermediate Vector Storage Handshakes
    wire [15:0] ft_vector, it_vector, cttil_vector, ot_vector;
    wire        ft_full, it_full, cttil_full, ot_full;
    wire [15:0] emult_out;
    wire        emult_valid;
    
    // Intermediate Processing Buffers
    wire [15:0] partial_ct_data, it_ct_tilde_data;
    wire        partial_ct_full, it_ct_tilde_full;
    wire [15:0] vector_adder_out;
    wire        vector_adder_valid;

    // Long-Term Cell State and Hidden State Recurrent Handshakes
    wire [15:0] current_ct_state;
    wire [15:0] current_ht_state;
    wire        ht_state_ready_flag;
    wire [15:0] passive_tanh_ct_out;
    wire        passive_tanh_ct_valid;
    wire        passive_tanh_ct_full;
    wire [15:0] buffered_tanh_ct_out; 

    // =================================================================
    // FIX 1 & 4 & 5: DEDICATED INDEPENDENT TIMING COUNTERS
    // =================================================================
    reg [STATE_ADDR_W-1:0] write_counter_reg;  // Primary Collector Pointer
    reg [STATE_ADDR_W-1:0] adder_read_counter; // FIX 4: Separate counter for vector adding read execution
    reg [STATE_ADDR_W-1:0] ct_write_counter;   // FIX 5: Isolated write index tracker for ct memory entries
    reg                    ct_write_complete;  // FIX 2: Stable, registered lookahead loop feedback flag
    reg [STATE_ADDR_W-1:0] tanh_read_counter;
    // Input memory multiplexing routing pass
    reg [STATE_ADDR_W-1:0] cttilde_write_counter;
    reg [1:0] emult_a_sel_r;
    reg [STATE_ADDR_W-1:0] tanh_write_addr;
    // After existing wire declarations, add:
reg addr_row_done_A_d1, addr_row_done_A_d2;
reg addr_row_done_B_d1, addr_row_done_B_d2;

always @(posedge clk) begin
    if (rst) begin
        addr_row_done_A_d1 <= 0; addr_row_done_A_d2 <= 0;
        addr_row_done_B_d1 <= 0; addr_row_done_B_d2 <= 0;
    end else begin
        addr_row_done_A_d1 <= addr_row_done_A;
        addr_row_done_A_d2 <= addr_row_done_A_d1;
        addr_row_done_B_d1 <= addr_row_done_B;
        addr_row_done_B_d2 <= addr_row_done_B_d1;
    end
end

    assign mux_input_memory_addr = (ext_write_en) ? ext_write_addr : addr_input_read;
    

    // Execution Block Activation Mux Blocks
    always @(*) begin
        if (ctrl_mac1_act_sel == 1'b0) begin
            selected_act1_data  = sig1_out;
            selected_act1_valid = sig1_valid;
        end else begin
            selected_act1_data  = tanh1_out;
            selected_act1_valid = tanh1_valid;
        end
    end

    always @(*) begin
        if (ctrl_mac2_act_sel == 1'b0) begin
            selected_act2_data  = sig2_out;
            selected_act2_valid = sig2_valid;
        end else begin
            selected_act2_data  = 16'h0000; 
            selected_act2_valid = 1'b0;
        end
    end

    always @(*) begin
        case (ctrl_emult_a_sel)
            2'b00:   emult_mux_a = ft_vector;
            2'b01:   emult_mux_a = it_vector;
            2'b10:   emult_mux_a = ot_vector;
            default: emult_mux_a = 16'h0000;
        endcase
    end

    always @(*) begin
        case (ctrl_emult_b_sel)
            2'b00:   emult_mux_b = current_ct_state; 
            2'b01:   emult_mux_b = cttil_vector;
            2'b10:   emult_mux_b = buffered_tanh_ct_out; 
            default: emult_mux_b = 16'h0000;
        endcase
    end


    // Counter Loop 1: Fixed write address assignment with high threshold constraint guards
    always @(posedge clk) begin
    if (rst || ctrl_buffer_clear || ctrl_stage_rst) begin
        write_counter_reg <= 0;
    end 
    else if (write_counter_reg < N) begin
        if (sig1_valid && (ctrl_ft_write || ctrl_it_write))
            write_counter_reg <= write_counter_reg + 1;
        else if (tanh1_valid && ctrl_ct_write)           // NEW: ct_tilde gets its own path
            write_counter_reg <= write_counter_reg + 1;
        else if (sig2_valid && ctrl_ot_write)
            write_counter_reg <= write_counter_reg + 1;
        else if (emult_valid)
            write_counter_reg <= write_counter_reg + 1;
        else if (passive_tanh_ct_valid)
            write_counter_reg <= write_counter_reg + 1;
    end
end

// =================================================================
    // SATURATING WRITE COUNTER (Prevents 2-Bit Wrap Around!)
    // =============================================================
    // Counter Loop 2: Isolated sequential tracker for parsing the cell-adder inputs
    always @(posedge clk) begin
        if (rst || ctrl_stage_rst) begin
            adder_read_counter <= 0;
        end
        else if (ctrl_adder_start && (adder_read_counter < N)) begin
            adder_read_counter <= adder_read_counter + 1;
        end
    end

    // Counter Loop 3: Dedicated counter tracking safe writing states inside ct registers
    always @(posedge clk) begin
        if (rst || ctrl_stage_rst) begin
            ct_write_counter <= 0;
        end
        else if (vector_adder_valid && (ct_write_counter < N)) begin
            ct_write_counter <= ct_write_counter + 1;
        end
    end


    // Flag Interlock System: Generates registered handshake flag to prevent race drops
    always @(posedge clk) begin
        if (rst || ctrl_stage_rst) begin
            ct_write_complete <= 1'b0;
        end
        else if (vector_adder_valid && (ct_write_counter == N - 1)) begin
            ct_write_complete <= 1'b1; // FIX 2: Locks high stably for the FSM combinational read state
        end
    end
    
   always @(posedge clk) begin
    if (rst || ctrl_stage_rst) begin
        tanh_read_counter <= 0;
    end
    else if ((fsm_current_state == 4'd7) && (tanh_read_counter < N)) begin
        tanh_read_counter <= tanh_read_counter + 1;
    end
end

always @(posedge clk) begin
    if (rst || ctrl_buffer_clear || ctrl_stage_rst) begin
        cttilde_write_counter <= 0;
    end
    else if (tanh1_valid && ctrl_ct_write && (cttilde_write_counter < N)) begin
        cttilde_write_counter <= cttilde_write_counter + 1;
    end
end
always @(posedge clk) begin
    if (rst || ctrl_stage_rst) begin
        tanh_write_addr <= 0;
    end
    else if (passive_tanh_ct_valid && (tanh_write_addr < N)) begin
        tanh_write_addr <= tanh_write_addr + 1;
    end
end
always @(posedge clk) emult_a_sel_r <= ctrl_emult_a_sel;


// Separate counter for it buffer
reg [STATE_ADDR_W-1:0] it_write_counter;
always @(posedge clk) begin
    if (rst || ctrl_buffer_clear || ctrl_stage_rst)
        it_write_counter <= 0;
    else if (sig1_valid && ctrl_it_write && it_write_counter < N)
        it_write_counter <= it_write_counter + 1;
end

// Separate counter for ot buffer
reg [STATE_ADDR_W-1:0] ot_write_counter;
always @(posedge clk) begin
    if (rst || ctrl_buffer_clear || ctrl_stage_rst)
        ot_write_counter <= 0;
    else if (sig2_valid && ctrl_ot_write && ot_write_counter < N)
        ot_write_counter <= ot_write_counter + 1;
end

//separate counter for bias
// Explicit saturating rollover counter
reg [STATE_ADDR_W-1:0] bias_read_counter;

always @(posedge clk) begin
    if (rst || ctrl_buffer_clear || ctrl_stage_rst) begin
        bias_read_counter <= 0;
    end
    else if (mac1_valid_out) begin
        if (bias_read_counter == N - 1)
            bias_read_counter <= 0; // Finished Row 2! Snap instantly back to 0.
        else
            bias_read_counter <= bias_read_counter + 1;
    end
end

wire         ctrl_tanh_ct_start;
// =================================================================
// UNIVERSAL VECTOR READ COUNTER (Feeds Emult, Adder, and Tanh)
// =================================================================
reg [STATE_ADDR_W-1:0] vector_read_counter;

always @(posedge clk) begin
    if (rst || ctrl_stage_rst) begin
        vector_read_counter <= 0;
    end
    // Use ctrl_tanh_ct_start here!
    else if ((ctrl_emult_start || ctrl_adder_start || ctrl_tanh_ct_start) && (vector_read_counter < N)) begin
        vector_read_counter <= vector_read_counter + 1; 
    end
end


// =================================================================
// PIPELINE SYNCHRONIZER FOR VECTOR ADDER (1-Cycle RAM Delay)
// =================================================================
reg [STATE_ADDR_W-1:0] adder_sync_addr;
reg                    adder_sync_en;

always @(posedge clk) begin
    if (rst || ctrl_stage_rst) begin
        adder_sync_en   <= 1'b0;
        adder_sync_addr <= 0;
    end else begin
        // Capture the read address and enable, delaying them by exactly 1 clock cycle!
        // This perfectly matches the 1-cycle latency of the RAM buffers.
        adder_sync_en   <= (ctrl_adder_start && (vector_read_counter < N));
        adder_sync_addr <= vector_read_counter;
    end
end

// =================================================================
// PIPELINE SYNCHRONIZER FOR TANH BUFFER (2-Cycle Latency)
// =================================================================
reg [1:0] tanh_sync_en_shift;
reg [STATE_ADDR_W-1:0] tanh_sync_addr_shift [0:1];

always @(posedge clk) begin
    if (rst || ctrl_stage_rst) begin
        tanh_sync_en_shift <= 2'b00;
        tanh_sync_addr_shift[0] <= 0;
        tanh_sync_addr_shift[1] <= 0;
    end else begin
        // Stage 1: Capture the valid sweep (Only true for indices 0, 1, 2)
        tanh_sync_en_shift[0]   <= (ctrl_tanh_ct_start && (vector_read_counter < N));
        tanh_sync_addr_shift[0] <= vector_read_counter;
        
        // Stage 2: Shift it one more time to catch the data at the output!
        tanh_sync_en_shift[1]   <= tanh_sync_en_shift[0];
        tanh_sync_addr_shift[1] <= tanh_sync_addr_shift[0];
    end
end
// =================================================================
// PIPELINE SYNCHRONIZER FOR HT BUFFER (1-Cycle True Latency + FSM Lock)
// =================================================================
reg ht_sync_en;
reg [STATE_ADDR_W-1:0] ht_sync_addr;

always @(posedge clk) begin
    if (rst || ctrl_stage_rst) begin
        ht_sync_en   <= 1'b0;
        ht_sync_addr <= 0;
    end else begin
        // THE PADLOCK: Must have FSM permission (ctrl_new_ht_write) AND be within bounds!
        ht_sync_en   <= (ctrl_new_ht_write && (vector_read_counter < N));
        ht_sync_addr <= vector_read_counter;
    end
end


    fsm_controller u_fsm (
        .clk(clk), .rst(rst), .start(start), .timestep_done(timestep_done),
        .mac1_done(addr_matrix_done_A), .mac2_done(addr_matrix_done_B),
        .emult_done(it_ct_tilde_full), // FIX 3: Emult completed signal tied uniquely to stage 2 vector buffer 
        //.adder_done(vector_adder_valid && (adder_read_counter == N-1)),
         .adder_done( vector_adder_valid && (ct_write_counter == N - 1) ),
        .ft_reg_full(ft_full), .it_reg_full(it_full), .ct_tilde_full(cttil_full), .ot_reg_full(ot_full),
        .ct_state_full(ct_write_complete), // FIX 2: Linked straight to structural registered validation wire
        .tanh_done(passive_tanh_ct_full), .ht_reg_full(ht_state_ready_flag), 
        .partial_ct_done(partial_ct_full), // FIX 3: Connected straight to separated first stage element multiply loopback flag
        .stream_start(ctrl_stream_start), .mac1_start(ctrl_mac1_start), .mac2_start(ctrl_mac2_start),
        .mac1_gate_sel(ctrl_mac1_gate_sel), .mac2_gate_sel(ctrl_mac2_gate_sel),
        .mac1_act_sel(ctrl_mac1_act_sel), .mac2_act_sel(ctrl_mac2_act_sel),
        .emult_start(ctrl_emult_start), .emult_a_sel(ctrl_emult_a_sel), .emult_b_sel(ctrl_emult_b_sel),
        .adder_start(ctrl_adder_start), .ft_write_en(ctrl_ft_write), .it_write_en(ctrl_it_write),
        .ct_write_en(ctrl_ct_write), .ot_write_en(ctrl_ot_write), .new_ct_write(ctrl_new_ct_write),
        .new_ht_write(ctrl_new_ht_write), .sequence_rst(ctrl_seq_rst), .buffer_clear(ctrl_buffer_clear),
        .ht_valid_clear(ctrl_ht_clear), .stage_rst(ctrl_stage_rst),.current_state_out(fsm_current_state),
        .tanh_ct_start(ctrl_tanh_ct_start)
    );

    input_address #(.N(N), .M(M)) u_in_addr_gen (
        .clk(clk), .rst(rst), .start(ctrl_stream_start),
        .read_adr(addr_input_read), .valid_out(addr_input_valid), .done(addr_input_done)
    );


    weight_address #(.N(N), .M(M)) u_wt_addr_gen_A (
    .clk(clk), 
    .rst(rst), 
    .start(ctrl_mac1_start),        // <-- Master FSM trigger
    .gate_sel(ctrl_mac1_gate_sel),
    .row_done(addr_row_done_A),     // <-- Safely drives MAC1 clear
    .all_done(addr_matrix_done_A),  // <-- Safely tells FSM "Gate 0 is done"
    .weight_addr(addr_weight_bus_A)
);


weight_address #(.N(N), .M(M)) u_wt_addr_gen_B (
    .clk(clk), 
    .rst(rst), 
    .start(ctrl_mac2_start),        // <-- Master FSM trigger
    .gate_sel(ctrl_mac2_gate_sel),
    .row_done(addr_row_done_B),     // <-- Safely drives MAC2 clear
    .all_done(addr_matrix_done_B),  // <-- Safely tells FSM "Gate 2 is done"
    .weight_addr(addr_weight_bus_B)
);


    Input_memory #(.M(M), .N(N)) u_input_ram (
        .clk(clk), .write_en(ext_write_en), .write_addr(ext_write_addr),
        .write_data(ext_write_data), .read_addr(addr_input_read), .data_out(data_from_input_mem)
    );

    weight_memory #(.M(M), .N(N)) u_weight_ram (
        .clk(clk), 
        .read_addr_a(addr_weight_bus_A), .weight_out_a(data_from_weight_mem_A),
        .read_addr_b(addr_weight_bus_B), .weight_out_b(data_from_weight_mem_B)
    );

    bias_memory #(.N(N)) u_bias_ram1 (
        .clk(clk), .rst(rst), .gate_select(ctrl_mac1_gate_sel),
        .read_addr(bias_read_counter), .bias_out(data_from_bias_mem1)
    );

    bias_memory #(.N(N)) u_bias_ram2 (
        .clk(clk), .rst(rst), .gate_select(ctrl_mac2_gate_sel),
        .read_addr(bias_read_counter), .bias_out(data_from_bias_mem2)
    );

    MAC u_mac1 (
    .weight_in(data_from_weight_mem_A), .data_in(data_from_input_mem),
    .valid_in(addr_input_valid), 
    .clear(addr_row_done_A_d1),   // was addr_row_done_A
    .clk(clk), .rst(rst),
    .result(mac1_to_adder), .valid_out(mac1_valid_out)
);

// MAC2 — change clear port:
MAC u_mac2 (
    .weight_in(data_from_weight_mem_B), .data_in(data_from_input_mem),
    .valid_in(addr_input_valid), 
    .clear(addr_row_done_B_d1),   // was addr_row_done_B
    .clk(clk), .rst(rst),
    .result(mac2_to_adder), .valid_out(mac2_valid_out)
);

    bias_adder u_bias_add1 (
        .clk(clk), .mac_result(mac1_to_adder), .bias_in(data_from_bias_mem1),
        .valid_in(mac1_valid_out), .result_out(adder1_out), .valid_out(adder1_valid), .rst(rst)
    );

    bias_adder u_bias_add2 (
        .clk(clk), .mac_result(mac2_to_adder), .bias_in(data_from_bias_mem2),
        .valid_in(mac2_valid_out), .result_out(adder2_out), .valid_out(adder2_valid), .rst(rst)
    );

    sigmoid_approx u_sig1 (
        .clk(clk), .x_in(adder1_out), .rst(rst), .valid_in(adder1_valid),
        .y_out(sig1_out), .valid_out(sig1_valid)
    );

    tanh_approx u_tanh1 (
        .clk(clk), .x_in(adder2_out), .rst(rst), .valid_in(adder2_valid),
        .y_out(tanh1_out), .valid_out(tanh1_valid)
    );

    sigmoid_approx u_sig2 (
        .clk(clk), .x_in(adder2_out), .rst(rst), .valid_in(adder2_valid),
        .y_out(sig2_out), .valid_out(sig2_valid)
    );

    gate_buffer #(.N(N)) u_buf_ft (
        .clk(clk), .rst(rst), .clear(ctrl_buffer_clear), .write_en(ctrl_ft_write && selected_act1_valid),
        .write_addr(write_counter_reg), .data_in(selected_act1_data), .read_addr(vector_read_counter), // FIX 4: Guided via isolated read index
        .data_out(ft_vector), .full(ft_full)
    );

    gate_buffer #(.N(N)) u_buf_it (
        .clk(clk), .rst(rst), .clear(ctrl_buffer_clear), .write_en(ctrl_it_write && sig1_valid),
        .write_addr(it_write_counter), .data_in(sig1_out), .read_addr(vector_read_counter),
        .data_out(it_vector), .full(it_full)
    );

    gate_buffer #(.N(N)) u_buf_ct_tilde (
        .clk(clk), .rst(rst), .clear(ctrl_buffer_clear), .write_en(ctrl_ct_write && tanh1_valid),
        .write_addr(cttilde_write_counter), .data_in(tanh1_out), .read_addr(vector_read_counter),
        .data_out(cttil_vector), .full(cttil_full)
    );


    gate_buffer #(.N(N)) u_buf_ot (
        .clk(clk), .rst(rst), .clear(ctrl_buffer_clear), .write_en(ctrl_ot_write && sig2_valid),
        .write_addr(ot_write_counter), .data_in(sig2_out), .read_addr(vector_read_counter),
        .data_out(ot_vector), .full(ot_full)
    );

    element_mult u_vector_emult (
        .clk(clk), .a_in(emult_mux_a), .b_in(emult_mux_b), .valid_in(ctrl_emult_start),
        .result_out(emult_out), .valid_out(emult_valid), .rst(rst)
    );

    gate_buffer #(.N(N)) u_buf_partial_ct (
        .clk(clk), .rst(rst), .clear(ctrl_buffer_clear), .write_en(emult_valid && (emult_a_sel_r == 2'b00)),
        .write_addr(write_counter_reg), .data_in(emult_out), .read_addr(vector_read_counter), // FIX 4: Controlled via dedicated adder address wire
        .data_out(partial_ct_data), .full(partial_ct_full)
    );

    gate_buffer #(.N(N)) u_buf_it_ct_tilde (
        .clk(clk), .rst(rst), .clear(ctrl_buffer_clear), .write_en(emult_valid && (emult_a_sel_r == 2'b01)),
        .write_addr(write_counter_reg), .data_in(emult_out), .read_addr(vector_read_counter), // FIX 4: Isolated from pointer loop conflicts
        .data_out(it_ct_tilde_data), .full(it_ct_tilde_full)
    );

    vector_adder u_cell_state_adder (
        .clk(clk), .valid_in(ctrl_adder_start), .rst(rst),
        .a_in(partial_ct_data), .b_in(it_ct_tilde_data),
        .result_out(vector_adder_out), .valid_out(vector_adder_valid)
    );
    
    ct_reg #(.N(N)) u_state_register_ct (
        .clk(clk), .rst(rst), .seq_rst(ctrl_seq_rst), 
        .write_en(adder_sync_en), 
        .write_addr(adder_sync_addr), // FIX 5: Driven through dedicated cell write counter path
        .data_in(vector_adder_out), .read_addr(vector_read_counter),
        .data_out(current_ct_state)
    );

    tanh_approx u_passive_cell_squasher (
        .clk(clk), .x_in(current_ct_state), .rst(rst), .valid_in(fsm_current_state == 4'd7),
        .y_out(passive_tanh_ct_out), .valid_out(passive_tanh_ct_valid)
    );

    gate_buffer #(.N(N)) u_buf_tanh_ct (
        .clk(clk), .rst(rst), .clear(ctrl_buffer_clear), //.write_en(passive_tanh_ct_valid),
        //.write_addr(tanh_write_addr),
        .write_en(tanh_sync_en_shift[1]),
        .write_addr(tanh_sync_addr_shift[1]),
       
        .data_in(passive_tanh_ct_out), .read_addr(vector_read_counter),
        .data_out(buffered_tanh_ct_out), 
        .full(passive_tanh_ct_full)
    );

    ht_register #(.N(N)) u_state_register_ht (
        .clk(clk), .rst(rst), .ht_valid_clear(ctrl_ht_clear), 
        //.write_en(emult_valid), 
        //.write_addr(write_counter_reg),
        .write_en(ht_sync_en),
        .write_addr(ht_sync_addr),
        
         .data_in(emult_out), .read_addr(ext_read_addr),
        .data_out(current_ht_state), .ht_to_mem_valid(ht_state_ready_flag)
    ); 
    assign ht_out_data = current_ht_state;

endmodule

    
