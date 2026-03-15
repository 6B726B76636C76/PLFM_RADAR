`timescale 1ns / 1ps

module nco_400m_enhanced (
    input wire clk_400m,
    input wire reset_n,
    input wire [31:0] frequency_tuning_word,
    input wire phase_valid,
    input wire [15:0] phase_offset,
    output reg signed [15:0] sin_out,
    output reg signed [15:0] cos_out,
    output reg dds_ready
);

// Phase accumulator with registered outputs for better timing
reg [31:0] phase_accumulator;
reg [31:0] phase_accumulator_reg;
reg [31:0] phase_with_offset;
reg phase_valid_delayed;

// Use only the top 8 bits for LUT addressing (256-entry LUT equivalent)
wire [7:0] lut_address = phase_with_offset[31:24];

// Quarter-wave sine LUT (0-90 degrees only)
reg [15:0] sin_lut [0:63]; // 64 entries for 0-90 degrees

// Initialize sine LUT
integer lut_init_i;
initial begin
    for (lut_init_i = 0; lut_init_i < 64; lut_init_i = lut_init_i + 1) begin
        sin_lut[lut_init_i] = 16'h0000;
    end
    
    // Initialize quarter-wave sine LUT (0-90 degrees)
    // LUT[k] = round(32767 * sin(pi/2 * k / 64)), monotonically increasing
    // FIX: Original LUT peaked at index 42 then decreased — broke cos=sin[63-k] quadrature
    sin_lut[0] = 16'h0000; sin_lut[1] = 16'h0324; sin_lut[2] = 16'h0648; sin_lut[3] = 16'h096A;
    sin_lut[4] = 16'h0C8C; sin_lut[5] = 16'h0FAB; sin_lut[6] = 16'h12C8; sin_lut[7] = 16'h15E2;
    sin_lut[8] = 16'h18F9; sin_lut[9] = 16'h1C0B; sin_lut[10] = 16'h1F1A; sin_lut[11] = 16'h2223;
    sin_lut[12] = 16'h2528; sin_lut[13] = 16'h2826; sin_lut[14] = 16'h2B1F; sin_lut[15] = 16'h2E11;
    sin_lut[16] = 16'h30FB; sin_lut[17] = 16'h33DF; sin_lut[18] = 16'h36BA; sin_lut[19] = 16'h398C;
    sin_lut[20] = 16'h3C56; sin_lut[21] = 16'h3F17; sin_lut[22] = 16'h41CE; sin_lut[23] = 16'h447A;
    sin_lut[24] = 16'h471C; sin_lut[25] = 16'h49B4; sin_lut[26] = 16'h4C3F; sin_lut[27] = 16'h4EBF;
    sin_lut[28] = 16'h5133; sin_lut[29] = 16'h539B; sin_lut[30] = 16'h55F5; sin_lut[31] = 16'h5842;
    sin_lut[32] = 16'h5A82; sin_lut[33] = 16'h5CB3; sin_lut[34] = 16'h5ED7; sin_lut[35] = 16'h60EB;
    sin_lut[36] = 16'h62F1; sin_lut[37] = 16'h64E8; sin_lut[38] = 16'h66CF; sin_lut[39] = 16'h68A6;
    sin_lut[40] = 16'h6A6D; sin_lut[41] = 16'h6C23; sin_lut[42] = 16'h6DC9; sin_lut[43] = 16'h6F5E;
    sin_lut[44] = 16'h70E2; sin_lut[45] = 16'h7254; sin_lut[46] = 16'h73B5; sin_lut[47] = 16'h7504;
    sin_lut[48] = 16'h7641; sin_lut[49] = 16'h776B; sin_lut[50] = 16'h7884; sin_lut[51] = 16'h7989;
    sin_lut[52] = 16'h7A7C; sin_lut[53] = 16'h7B5C; sin_lut[54] = 16'h7C29; sin_lut[55] = 16'h7CE3;
    sin_lut[56] = 16'h7D89; sin_lut[57] = 16'h7E1D; sin_lut[58] = 16'h7E9C; sin_lut[59] = 16'h7F09;
    sin_lut[60] = 16'h7F61; sin_lut[61] = 16'h7FA6; sin_lut[62] = 16'h7FD8; sin_lut[63] = 16'h7FF5;
end

// Quadrant determination
wire [1:0] quadrant = lut_address[7:6]; // 00: Q1, 01: Q2, 10: Q3, 11: Q4
wire [5:0] lut_index = (quadrant[1] ? ~lut_address[5:0] : lut_address[5:0]); // Mirror for Q2/Q3

// Sine and cosine calculation with quadrant mapping
wire [15:0] sin_abs = sin_lut[lut_index];
wire [15:0] cos_abs = sin_lut[63 - lut_index]; // Cosine is phase-shifted sine

// Pipeline stage for better timing
always @(posedge clk_400m or negedge reset_n) begin
    if (!reset_n) begin
        phase_accumulator <= 32'h00000000;
        phase_accumulator_reg <= 32'h00000000;
        phase_with_offset <= 32'h00000000;
        phase_valid_delayed <= 1'b0;
        dds_ready <= 1'b0;
        sin_out <= 16'h0000;
        cos_out <= 16'h7FFF;
    end else begin
        phase_valid_delayed <= phase_valid;
        
        if (phase_valid) begin
            // Update phase accumulator with dithered frequency tuning word
            phase_accumulator <= phase_accumulator + frequency_tuning_word;
            phase_accumulator_reg <= phase_accumulator;
            
            // Apply phase offset
            phase_with_offset <= phase_accumulator + {phase_offset, 16'b0};
            dds_ready <= 1'b1;
        end else begin
            dds_ready <= 1'b0;
        end
        
        // Generate outputs with one cycle delay for pipelining
        if (phase_valid_delayed) begin
            // Calculate sine and cosine with proper quadrant signs
            case (quadrant)
                2'b00: begin // Quadrant I: sin+, cos+
                    sin_out <= sin_abs;
                    cos_out <= cos_abs;
                end
                2'b01: begin // Quadrant II: sin+, cos-
                    sin_out <= sin_abs;
                    cos_out <= -cos_abs;
                end
                2'b10: begin // Quadrant III: sin-, cos-
                    sin_out <= -sin_abs;
                    cos_out <= -cos_abs;
                end
                2'b11: begin // Quadrant IV: sin-, cos+
                    sin_out <= -sin_abs;
                    cos_out <= cos_abs;
                end
            endcase
        end
    end
end

// Debug verification of LUT initialization (simulation only)
`ifdef SIMULATION
initial begin
    #10;
    $display("NCO: Sine LUT initialized with %0d entries", 64);
end
`endif

endmodule
