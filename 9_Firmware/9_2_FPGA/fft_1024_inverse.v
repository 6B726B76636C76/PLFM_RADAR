`timescale 1ns / 1ps

module fft_1024_inverse_enhanced (
    input wire clk,
    input wire reset_n,
    input wire [15:0] data_i,
    input wire [15:0] data_q,
    input wire data_valid,
    output wire [15:0] ifft_i,
    output wire [15:0] ifft_q,
    output wire ifft_valid
);

// ========== MATCH YOUR FFT IP CONFIGURATION ==========
wire [15:0] s_axis_config_tdata;      // 16-bit
wire s_axis_config_tvalid;
wire s_axis_config_tready;
wire [31:0] s_axis_data_tdata;        // 32-bit for your IP  {Q[15:0],I[15:0]}
wire s_axis_data_tvalid;
wire s_axis_data_tready;
wire s_axis_data_tlast;
wire [31:0] m_axis_data_tdata;        // 32-bit
wire m_axis_data_tvalid;
wire m_axis_data_tready;
wire m_axis_data_tlast;

// Configuration: bit 0 = 0 for inverse FFT
assign s_axis_config_tdata = 16'h0000;
assign s_axis_config_tvalid = 1'b1;


assign s_axis_data_tdata = {data_q, data_i};
assign s_axis_data_tvalid = data_valid;

// Frame counter
reg [9:0] sample_count;
reg frame_active;
always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        sample_count <= 0;
        frame_active <= 0;
    end else begin
        if (data_valid && !frame_active) begin
            frame_active <= 1'b1;
            sample_count <= 0;
        end
        
        if (frame_active && data_valid) begin
            if (sample_count == 1023) begin
                sample_count <= 0;
                frame_active <= 0;
            end else begin
                sample_count <= sample_count + 1;
            end
        end
    end
end
assign s_axis_data_tlast = (sample_count == 1023) && data_valid;
// Output
assign ifft_i = m_axis_data_tdata[15:0];   // I = lower 16 bits
assign ifft_q = m_axis_data_tdata[31:16];  // Q = upper 16 bits
assign ifft_valid = m_axis_data_tvalid;
assign m_axis_data_tready = 1'b1;

// Debug
`ifdef SIMULATION
reg [31:0] debug_counter;
always @(posedge clk) begin
    debug_counter <= debug_counter + 1;
    
    if (debug_counter < 1000) begin
        if (s_axis_config_tvalid && s_axis_config_tready) begin
            $display("[IFFT_CORRECTED @%d] CONFIG ACCEPTED!", debug_counter);
        end
    end
end
`endif

// IFFT IP instance
FFT_enhanced ifft_inverse_inst (  // Same IP core, different configuration
    .aclk(clk),
    .aresetn(reset_n),
    
    .s_axis_config_tdata(s_axis_config_tdata),
    .s_axis_config_tvalid(s_axis_config_tvalid),
    .s_axis_config_tready(s_axis_config_tready),
    
    .s_axis_data_tdata(s_axis_data_tdata),
    .s_axis_data_tvalid(s_axis_data_tvalid),
    .s_axis_data_tready(s_axis_data_tready),
    .s_axis_data_tlast(s_axis_data_tlast),
    
    .m_axis_data_tdata(m_axis_data_tdata),
    .m_axis_data_tvalid(m_axis_data_tvalid),
    .m_axis_data_tlast(m_axis_data_tlast)
    
);

endmodule