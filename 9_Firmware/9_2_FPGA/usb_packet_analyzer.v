`timescale 1ns / 1ps

/**
 * usb_packet_analyzer.v
 * 
 * Analyzes USB packet format from FT601 interface
 * Verifies header/footer and data integrity
 */

module usb_packet_analyzer (
    input wire clk,
    input wire reset_n,
    input wire [31:0] usb_data,
    input wire usb_wr_strobe,
    output reg packet_valid,
    output reg [7:0] packet_type,
    output reg [31:0] packet_data,
    output wire [31:0] error_count
);

// Packet structure
localparam HEADER = 8'hAA;
localparam FOOTER = 8'h55;
localparam HEADER_POS = 24;  // Header in bits [31:24]

// States (Verilog-2001 compatible)
localparam [2:0] ST_IDLE      = 3'd0,
                 ST_HEADER    = 3'd1,
                 ST_RANGE     = 3'd2,
                 ST_DOPPLER   = 3'd3,
                 ST_DETECTION = 3'd4,
                 ST_FOOTER    = 3'd5;

reg [2:0] current_state, next_state;
reg [7:0] byte_count;
reg [31:0] error_reg;
reg [31:0] packet_count;

always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        current_state <= ST_IDLE;
        byte_count <= 8'd0;
        error_reg <= 32'd0;
        packet_count <= 32'd0;
        packet_valid <= 1'b0;
        packet_type <= 8'd0;
        packet_data <= 32'd0;
    end else begin
        packet_valid <= 1'b0;
        
        case (current_state)
            ST_IDLE: begin
                if (usb_wr_strobe && usb_data[31:24] == HEADER) begin
                    current_state <= ST_HEADER;
                    packet_count <= packet_count + 1;
                    `ifdef SIMULATION
                    $display("[USB_ANALYZER] Packet %0d started at time %0t", 
                             packet_count + 1, $time);
                    `endif
                end
            end
            
            ST_HEADER: begin
                if (usb_wr_strobe) begin
                    current_state <= ST_RANGE;
                    byte_count <= 8'd0;
                end
            end
            
            ST_RANGE: begin
                if (usb_wr_strobe) begin
                    if (byte_count == 8'd0) begin
                        packet_data[31:24] <= usb_data[7:0];
                        byte_count <= 8'd1;
                    end else if (byte_count == 8'd1) begin
                        packet_data[23:16] <= usb_data[7:0];
                        byte_count <= 8'd2;
                    end else if (byte_count == 8'd2) begin
                        packet_data[15:8] <= usb_data[7:0];
                        byte_count <= 8'd3;
                    end else if (byte_count == 8'd3) begin
                        packet_data[7:0] <= usb_data[7:0];
                        current_state <= ST_DOPPLER;
                        byte_count <= 8'd0;
                        `ifdef SIMULATION
                        $display("[USB_ANALYZER] Range data: 0x%08h", packet_data);
                        `endif
                    end
                end
            end
            
            ST_DOPPLER: begin
                if (usb_wr_strobe) begin
                    if (byte_count == 8'd0) begin
                        packet_data[31:16] <= usb_data[31:16];  // Doppler real
                        byte_count <= 8'd1;
                    end else if (byte_count == 8'd1) begin
                        packet_data[15:0] <= usb_data[31:16];   // Doppler imag
                        current_state <= ST_DETECTION;
                        byte_count <= 8'd0;
                        `ifdef SIMULATION
                        $display("[USB_ANALYZER] Doppler data: real=0x%04h, imag=0x%04h",
                                 packet_data[31:16], packet_data[15:0]);
                        `endif
                    end
                end
            end
            
            ST_DETECTION: begin
                if (usb_wr_strobe) begin
                    packet_type <= usb_data[0];
                    current_state <= ST_FOOTER;
                    `ifdef SIMULATION
                    $display("[USB_ANALYZER] Detection: %b", usb_data[0]);
                    `endif
                end
            end
            
            ST_FOOTER: begin
                if (usb_wr_strobe) begin
                    if (usb_data[7:0] == FOOTER) begin
                        packet_valid <= 1'b1;
                        `ifdef SIMULATION
                        $display("[USB_ANALYZER] Packet %0d valid, footer OK", packet_count);
                        `endif
                    end else begin
                        error_reg <= error_reg + 1;
                        `ifdef SIMULATION
                        $error("[USB_ANALYZER] Invalid footer: expected 0x55, got 0x%02h",
                               usb_data[7:0]);
                        `endif
                    end
                    current_state <= ST_IDLE;
                end
            end
            
            default: current_state <= ST_IDLE;
        endcase
    end
end

assign error_count = error_reg;

endmodule
