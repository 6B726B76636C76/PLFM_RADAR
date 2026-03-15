module usb_data_interface (
    input wire clk,              // Main clock (100MHz recommended)
    input wire reset_n,
    
    // Radar data inputs
    input wire [31:0] range_profile,
    input wire range_valid,
    input wire [15:0] doppler_real,
    input wire [15:0] doppler_imag,
    input wire doppler_valid,
    input wire cfar_detection,
    input wire cfar_valid,
    
    // FT601 Interface (Slave FIFO mode)
    // Data bus
    inout wire [31:0] ft601_data,    // 32-bit bidirectional data bus
    output reg [1:0] ft601_be,       // Byte enable (for 32-bit mode)
    
    // Control signals
    output reg ft601_txe_n,          // Transmit enable (active low)
    output reg ft601_rxf_n,          // Receive enable (active low)
    input wire ft601_txe,             // Transmit FIFO empty
    input wire ft601_rxf,             // Receive FIFO full
    output reg ft601_wr_n,            // Write strobe (active low)
    output reg ft601_rd_n,            // Read strobe (active low)
    output reg ft601_oe_n,            // Output enable (active low)
    output reg ft601_siwu_n,          // Send immediate / Wakeup
    
    // FIFO flags
    input wire [1:0] ft601_srb,       // Selected read buffer
    input wire [1:0] ft601_swb,       // Selected write buffer
    
    // Clock
    output reg ft601_clk_out,         // Output clock to FT601 (optional)
    input wire ft601_clk_in           // Clock from FT601 (60/100MHz)
);

// USB packet structure (same as before)
localparam HEADER = 8'hAA;
localparam FOOTER = 8'h55;

// FT601 configuration
localparam FT601_DATA_WIDTH = 32;
localparam FT601_BURST_SIZE = 512;    // Max burst size in bytes

// State definitions (Verilog-2001 compatible)
localparam [2:0] IDLE                = 3'd0,
                 SEND_HEADER         = 3'd1,
                 SEND_RANGE_DATA     = 3'd2,
                 SEND_DOPPLER_DATA   = 3'd3,
                 SEND_DETECTION_DATA = 3'd4,
                 SEND_FOOTER         = 3'd5,
                 WAIT_ACK            = 3'd6;

reg [2:0] current_state;
reg [7:0] byte_counter;
reg [31:0] data_buffer;
reg [31:0] ft601_data_out;
reg ft601_data_oe;  // Output enable for bidirectional data bus

// FT601 data bus direction control
assign ft601_data = ft601_data_oe ? ft601_data_out : 32'hzzzz_zzzz;

always @(posedge ft601_clk_in or negedge reset_n) begin
    if (!reset_n) begin
        current_state <= IDLE;
        byte_counter <= 0;
        ft601_data_out <= 0;
        ft601_data_oe <= 0;
        ft601_be <= 2'b11;  // Both bytes enabled for 32-bit mode
        ft601_txe_n <= 1;
        ft601_rxf_n <= 1;
        ft601_wr_n <= 1;
        ft601_rd_n <= 1;
        ft601_oe_n <= 1;
        ft601_siwu_n <= 1;
        ft601_clk_out <= 0;
    end else begin
        case (current_state)
            IDLE: begin
                ft601_wr_n <= 1;
                ft601_data_oe <= 0;  // Release data bus
                if (range_valid || doppler_valid || cfar_valid) begin
                    current_state <= SEND_HEADER;
                    byte_counter <= 0;
                end
            end
            
            SEND_HEADER: begin
                if (!ft601_txe) begin  // FT601 TX FIFO not empty
                    ft601_data_oe <= 1;
                    ft601_data_out <= {24'b0, HEADER};
                    ft601_be <= 2'b01;  // Only lower byte valid
                    ft601_wr_n <= 0;     // Assert write strobe
                    current_state <= SEND_RANGE_DATA;
                end
            end
            
            SEND_RANGE_DATA: begin
                if (!ft601_txe) begin
                    ft601_data_oe <= 1;
                    ft601_be <= 2'b11;  // All bytes valid for 32-bit word
                    
                    case (byte_counter)
                        0: ft601_data_out <= range_profile;
                        1: ft601_data_out <= {range_profile[23:0], 8'h00};
                        2: ft601_data_out <= {range_profile[15:0], 16'h0000};
                        3: ft601_data_out <= {range_profile[7:0], 24'h000000};
                    endcase
                    
                    ft601_wr_n <= 0;
                    
                    if (byte_counter == 3) begin
                        byte_counter <= 0;
                        current_state <= SEND_DOPPLER_DATA;
                    end else begin
                        byte_counter <= byte_counter + 1;
                    end
                end
            end
            
            SEND_DOPPLER_DATA: begin
                if (!ft601_txe && doppler_valid) begin
                    ft601_data_oe <= 1;
                    ft601_be <= 2'b11;
                    
                    case (byte_counter)
                        0: ft601_data_out <= {doppler_real, doppler_imag};
                        1: ft601_data_out <= {doppler_imag, doppler_real[15:8], 8'h00};
                        2: ft601_data_out <= {doppler_real[7:0], doppler_imag[15:8], 16'h0000};
                        3: ft601_data_out <= {doppler_imag[7:0], 24'h000000};
                    endcase
                    
                    ft601_wr_n <= 0;
                    
                    if (byte_counter == 3) begin
                        byte_counter <= 0;
                        current_state <= SEND_DETECTION_DATA;
                    end else begin
                        byte_counter <= byte_counter + 1;
                    end
                end
            end
            
            SEND_DETECTION_DATA: begin
                if (!ft601_txe && cfar_valid) begin
                    ft601_data_oe <= 1;
                    ft601_be <= 2'b01;
                    ft601_data_out <= {24'b0, 7'b0, cfar_detection};
                    ft601_wr_n <= 0;
                    current_state <= SEND_FOOTER;
                end
            end
            
            SEND_FOOTER: begin
                if (!ft601_txe) begin
                    ft601_data_oe <= 1;
                    ft601_be <= 2'b01;
                    ft601_data_out <= {24'b0, FOOTER};
                    ft601_wr_n <= 0;
                    current_state <= WAIT_ACK;
                end
            end
            
            WAIT_ACK: begin
                ft601_wr_n <= 1;
                ft601_data_oe <= 0;  // Release data bus
                current_state <= IDLE;
            end
        endcase
    end
end

// Generate clock for FT601 if needed (optional)
always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        ft601_clk_out <= 0;
    end else begin
        ft601_clk_out <= ~ft601_clk_out;  // Divide by 2 from main clock
    end
end

endmodule