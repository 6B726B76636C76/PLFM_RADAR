`timescale 1ns / 1ps

module ddc_400m_enhanced (
    input wire clk_400m,           // 400MHz clock from ADC DCO
    input wire clk_100m,           // 100MHz system clock
    input wire reset_n,
    input wire mixers_enable,
    input wire [7:0] adc_data,     // ADC data at 400MHz
    input wire adc_data_valid_i,     // Valid at 400MHz
	 input wire adc_data_valid_q,
    output wire signed [17:0] baseband_i,
    output wire signed [17:0] baseband_q,  
    output wire baseband_valid_i,
	 output wire baseband_valid_q,

    output wire [1:0] ddc_status,
    // Enhanced interfaces
    output wire [7:0] ddc_diagnostics,
    output wire mixer_saturation,
    output wire filter_overflow,
    input wire bypass_mode,        // Test mode
	 
	 input wire [1:0] test_mode,
    input wire [15:0] test_phase_inc,
    input wire force_saturation,
    input wire reset_monitors,
    output wire [31:0] debug_sample_count,
    output wire [17:0] debug_internal_i,
    output wire [17:0] debug_internal_q
);

// Parameters for numerical precision
parameter ADC_WIDTH = 8;
parameter NCO_WIDTH = 16;
parameter MIXER_WIDTH = 18;
parameter OUTPUT_WIDTH = 18;

// IF frequency parameters
parameter IF_FREQ = 120000000;
parameter FS = 400000000;
parameter PHASE_WIDTH = 32;

// Internal signals
wire signed [15:0] sin_out, cos_out;
wire nco_ready;
wire cic_valid;
wire fir_valid;
wire [17:0] cic_i_out, cic_q_out;
wire signed [17:0] fir_i_out, fir_q_out;


// Diagnostic registers
reg [2:0] saturation_count;
reg overflow_detected;
reg [7:0] error_counter;

// CDC synchronization for control signals
reg mixers_enable_sync;
reg bypass_mode_sync;

// Debug monitoring signals
reg [31:0] sample_counter;
wire signed [17:0] debug_mixed_i_trunc;
wire signed [17:0] debug_mixed_q_trunc;

// Real-time status monitoring
reg [7:0] signal_power_i, signal_power_q;

// Enhanced saturation injection for testing
reg force_saturation_sync;

// Internal mixing signals
reg signed [MIXER_WIDTH-1:0] adc_signed;
reg signed [MIXER_WIDTH + NCO_WIDTH -1:0] mixed_i, mixed_q;
reg mixed_valid;
reg mixer_overflow_i, mixer_overflow_q;

// Output stage registers
reg signed [17:0] baseband_i_reg, baseband_q_reg;
reg baseband_valid_reg;

// ============================================================================
// Phase Dithering Signals
// ============================================================================
wire [7:0] phase_dither_bits;
wire [31:0] phase_inc_dithered;



// ============================================================================
// Debug Signal Assignments
// ============================================================================
assign debug_internal_i = mixed_i[25:8];
assign debug_internal_q = mixed_q[25:8];
assign debug_sample_count = sample_counter;
assign debug_mixed_i_trunc = mixed_i[25:8];
assign debug_mixed_q_trunc = mixed_q[25:8];

// ============================================================================
// Clock Domain Crossing for Control Signals
// ============================================================================
always @(posedge clk_400m or negedge reset_n) begin
    if (!reset_n) begin
        mixers_enable_sync <= 1'b0;
        bypass_mode_sync <= 1'b0;
        force_saturation_sync <= 1'b0;
    end else begin
        mixers_enable_sync <= mixers_enable;
        bypass_mode_sync <= bypass_mode;
        force_saturation_sync <= force_saturation;
    end
end

// ============================================================================
// Sample Counter and Debug Monitoring
// ============================================================================
always @(posedge clk_400m or negedge reset_n) begin
    if (!reset_n || reset_monitors) begin
        sample_counter <= 0;
        saturation_count <= 0;
        error_counter <= 0;
    end else if (adc_data_valid_i && adc_data_valid_q ) begin
        sample_counter <= sample_counter + 1;
    end
end


// ============================================================================
// Enhanced Phase Dithering Instance
// ============================================================================
lfsr_dither_enhanced #(
    .DITHER_WIDTH(8)
) phase_dither_gen (
    .clk(clk_400m),
    .reset_n(reset_n),
    .enable(nco_ready),
    .dither_out(phase_dither_bits)
);

// ============================================================================
// Phase Increment Calculation with Dithering
// ============================================================================
// Calculate phase increment for 120MHz IF at 400MHz sampling
localparam PHASE_INC_120MHZ = 32'h4CCCCCCD;

// Apply dithering to reduce spurious tones
assign phase_inc_dithered = PHASE_INC_120MHZ + {24'b0, phase_dither_bits};

// ============================================================================
// Enhanced NCO with Diagnostics
// ============================================================================
nco_400m_enhanced nco_core (
    .clk_400m(clk_400m),
    .reset_n(reset_n),
    .frequency_tuning_word(phase_inc_dithered),
    .phase_valid(mixers_enable),
    .phase_offset(16'h0000),
    .sin_out(sin_out),
    .cos_out(cos_out),
    .dds_ready(nco_ready)
);

// ============================================================================
// Enhanced Mixing Stage with AGC
// ============================================================================
always @(posedge clk_400m or negedge reset_n) begin
    if (!reset_n) begin
        adc_signed <= 0;
        mixed_i <= 0;
        mixed_q <= 0;
        mixed_valid <= 0;
        mixer_overflow_i <= 0;
        mixer_overflow_q <= 0;
        saturation_count <= 0;
        overflow_detected <= 0;
    end else if (nco_ready && adc_data_valid_i && adc_data_valid_q) begin
        // Convert ADC data to signed with extended precision
        adc_signed <= {1'b0, adc_data, {(MIXER_WIDTH-ADC_WIDTH-1){1'b0}}} - 
                     {1'b0, {ADC_WIDTH{1'b1}}, {(MIXER_WIDTH-ADC_WIDTH-1){1'b0}}} / 2;
        
        // Force saturation for testing
        if (force_saturation_sync) begin
            mixed_i <= 34'h1FFFFFFFF;  // Force positive saturation
            mixed_q <= 34'h200000000;  // Force negative saturation
            mixer_overflow_i <= 1'b1;
            mixer_overflow_q <= 1'b1;
        end else begin

                // Normal mixing
                mixed_i <= $signed(adc_signed) * $signed(cos_out);
                mixed_q <= $signed(adc_signed) * $signed(sin_out);
            
            
            // Enhanced overflow detection with counting
            mixer_overflow_i <= (mixed_i > (2**(MIXER_WIDTH+NCO_WIDTH-2)-1)) || 
                               (mixed_i < -(2**(MIXER_WIDTH+NCO_WIDTH-2)));
            mixer_overflow_q <= (mixed_q > (2**(MIXER_WIDTH+NCO_WIDTH-2)-1)) || 
                               (mixed_q < -(2**(MIXER_WIDTH+NCO_WIDTH-2)));
        end
        
        mixed_valid <= 1;
        
        if (mixer_overflow_i || mixer_overflow_q) begin
            saturation_count <= saturation_count + 1;
            overflow_detected <= 1'b1;
        end else begin
            overflow_detected <= 1'b0;
        end
        
    end else begin
        mixed_valid <= 0;
        mixer_overflow_i <= 0;
        mixer_overflow_q <= 0;
        overflow_detected <= 1'b0;
    end
end

// ============================================================================
// Enhanced CIC Decimators
// ============================================================================
wire cic_valid_i, cic_valid_q;

cic_decimator_4x_enhanced cic_i_inst (
    .clk(clk_400m),
    .reset_n(reset_n),
    .data_in(mixed_i[33:16]),
    .data_valid(mixed_valid),
    .data_out(cic_i_out),
    .data_out_valid(cic_valid_i)
);

cic_decimator_4x_enhanced cic_q_inst (
    .clk(clk_400m),
    .reset_n(reset_n),
    .data_in(mixed_q[33:16]),
    .data_valid(mixed_valid),
    .data_out(cic_q_out),
    .data_out_valid(cic_valid_q)
);

assign cic_valid = cic_valid_i & cic_valid_q;

// ============================================================================
// Enhanced FIR Filters with FIXED valid signal handling
// NOTE: Wire declarations moved BEFORE CDC instances to fix forward-reference
//       error in Icarus Verilog (was originally after CDC instantiation)
// ============================================================================
wire fir_in_valid_i, fir_in_valid_q;
wire fir_valid_i, fir_valid_q;
wire fir_i_ready, fir_q_ready;
wire [17:0] fir_d_in_i, fir_d_in_q; 

cdc_adc_to_processing #(
    .WIDTH(18),
    .STAGES(3)
)CDC_FIR_i(
    .src_clk(clk_400m),
    .dst_clk(clk_100m),
    .reset_n(reset_n),
    .src_data(cic_i_out),
    .src_valid(cic_valid_i),
    .dst_data(fir_d_in_i),
    .dst_valid(fir_in_valid_i)
);

cdc_adc_to_processing #(
    .WIDTH(18),
    .STAGES(3)
)CDC_FIR_q(
    .src_clk(clk_400m),
    .dst_clk(clk_100m),
    .reset_n(reset_n),
    .src_data(cic_q_out),
    .src_valid(cic_valid_q),
    .dst_data(fir_d_in_q),
    .dst_valid(fir_in_valid_q)
);

// ============================================================================
// FIR Filter Instances
// ============================================================================

// FIR I channel
fir_lowpass_parallel_enhanced fir_i_inst (
    .clk(clk_100m),
    .reset_n(reset_n),
    .data_in(fir_d_in_i),  // Use synchronized data
    .data_valid(fir_in_valid_i),  // Use synchronized valid
    .data_out(fir_i_out),
    .data_out_valid(fir_valid_i),
    .fir_ready(fir_i_ready),
    .filter_overflow()
);

// FIR Q channel  
fir_lowpass_parallel_enhanced fir_q_inst (
    .clk(clk_100m),
    .reset_n(reset_n),
    .data_in(fir_d_in_q),  // Use synchronized data
    .data_valid(fir_in_valid_q),  // Use synchronized valid
    .data_out(fir_q_out),
    .data_out_valid(fir_valid_q),
    .fir_ready(fir_q_ready),
    .filter_overflow()
);

assign fir_valid = fir_valid_i & fir_valid_q;

// ============================================================================
// Enhanced Output Stage
// ============================================================================
always @(negedge clk_100m or negedge reset_n) begin
    if (!reset_n) begin
        baseband_i_reg <= 0;
        baseband_q_reg <= 0;
        baseband_valid_reg <= 0;
    end else if (fir_valid) begin
        baseband_i_reg <= fir_i_out;
        baseband_q_reg <= fir_q_out;
        baseband_valid_reg <= 1;
    end else begin
        baseband_valid_reg <= 0;
    end
end


// ============================================================================
// Output Assignments
// ============================================================================
assign baseband_i = baseband_i_reg;
assign baseband_q = baseband_q_reg;
assign baseband_valid_i = baseband_valid_reg;
assign baseband_valid_q = baseband_valid_reg;
assign ddc_status = {mixer_overflow_i | mixer_overflow_q, nco_ready};
assign mixer_saturation = overflow_detected;
assign ddc_diagnostics = {saturation_count, error_counter[4:0]};

// ============================================================================
// Enhanced Debug and Monitoring
// ============================================================================
reg [31:0] debug_cic_count, debug_fir_count, debug_bb_count;

`ifdef SIMULATION
always @(posedge clk_100m) begin
    
    if (fir_valid_i && debug_fir_count < 20) begin
        debug_fir_count <= debug_fir_count + 1;
        $display("FIR_OUTPUT: fir_i=%6d, fir_q=%6d", fir_i_out, fir_q_out);
    end
    
    if (adc_data_valid_i && adc_data_valid_q && debug_bb_count < 20) begin
        debug_bb_count <= debug_bb_count + 1;
        $display("BASEBAND_OUT: i=%6d, q=%6d, count=%0d", 
                 baseband_i, baseband_q, debug_bb_count);
    end
end
`endif

// In ddc_400m.v, add these debug signals:

// Debug monitoring (simulation only)
`ifdef SIMULATION
reg [31:0] debug_adc_count = 0;
reg [31:0] debug_baseband_count = 0;

always @(posedge clk_400m) begin
    if (adc_data_valid_i && adc_data_valid_q && debug_adc_count < 10) begin
        debug_adc_count <= debug_adc_count + 1;
        $display("DDC_ADC: data=%0d, count=%0d, time=%t", 
                 adc_data, debug_adc_count, $time);
    end
end

always @(posedge clk_100m) begin
    if (baseband_valid_i && baseband_valid_q && debug_baseband_count < 10) begin
        debug_baseband_count <= debug_baseband_count + 1;
        $display("DDC_BASEBAND: i=%0d, q=%0d, count=%0d, time=%t", 
                 baseband_i, baseband_q, debug_baseband_count, $time);
    end
end
`endif


endmodule

// ============================================================================
// Enhanced Phase Dithering Module
// ============================================================================
`timescale 1ns / 1ps

module lfsr_dither_enhanced #(
    parameter DITHER_WIDTH = 8  // Increased for better dithering
)(
    input wire clk,
    input wire reset_n,
    input wire enable,
    output wire [DITHER_WIDTH-1:0] dither_out
);

reg [DITHER_WIDTH-1:0] lfsr_reg;
reg [15:0] cycle_counter;
reg lock_detected;

// Polynomial for better randomness: x^8 + x^6 + x^5 + x^4 + 1
wire feedback;

generate
    if (DITHER_WIDTH == 4) begin
        assign feedback = lfsr_reg[3] ^ lfsr_reg[2];
    end else if (DITHER_WIDTH == 8) begin
        assign feedback = lfsr_reg[7] ^ lfsr_reg[5] ^ lfsr_reg[4] ^ lfsr_reg[3];
    end else begin
        assign feedback = lfsr_reg[DITHER_WIDTH-1] ^ lfsr_reg[DITHER_WIDTH-2];
    end
endgenerate

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        lfsr_reg <= {DITHER_WIDTH{1'b1}};  // Non-zero initial state
        cycle_counter <= 0;
        lock_detected <= 0;
    end else if (enable) begin
        lfsr_reg <= {lfsr_reg[DITHER_WIDTH-2:0], feedback};
        cycle_counter <= cycle_counter + 1;
        
        // Detect LFSR lock after sufficient cycles
        if (cycle_counter > (2**DITHER_WIDTH * 8)) begin
            lock_detected <= 1'b1;
        end
    end
end

assign dither_out = lfsr_reg;

endmodule
