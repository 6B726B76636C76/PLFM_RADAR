module cic_decimator_4x_enhanced (
    input wire clk,                 // 400MHz input clock
    input wire reset_n,
    input wire signed [17:0] data_in,  // 18-bit input
    input wire data_valid,
    output reg signed [17:0] data_out, // 18-bit output
    output reg data_out_valid,       // Valid at 100MHz
    // Enhanced monitoring outputs
    output reg saturation_detected,  // Latched saturation indicator
    output reg [7:0] max_value_monitor, // For gain control
    input wire reset_monitors        // Clear saturation and max value
);

parameter STAGES = 5;
parameter DECIMATION = 4;
parameter COMB_DELAY = 1;

// Increased bit width for 18-bit input with headroom
reg signed [35:0] integrator [0:STAGES-1];  // 36-bit for better dynamic range
reg signed [35:0] comb [0:STAGES-1];
reg signed [35:0] comb_delay [0:STAGES-1][0:COMB_DELAY-1];

// Enhanced control and monitoring
reg [1:0] decimation_counter;
reg data_valid_delayed;
reg data_valid_comb;
reg [7:0] output_counter;
reg [35:0] max_integrator_value;
reg overflow_detected;
reg overflow_latched;  // Latched overflow indicator

// Diagnostic registers
reg [7:0] saturation_event_count;
reg [31:0] sample_count;

// Temporary signals for calculations
reg signed [35:0] abs_integrator_value;
reg signed [35:0] temp_scaled_output;
reg signed [17:0] temp_output;  // Temporary output for proper range checking

integer i, j;

// Initialize
initial begin
    for (i = 0; i < STAGES; i = i + 1) begin
        integrator[i] = 0;
        comb[i] = 0;
        for (j = 0; j < COMB_DELAY; j = j + 1) begin
            comb_delay[i][j] = 0;
        end
    end
    decimation_counter = 0;
    data_valid_delayed = 0;
    data_valid_comb = 0;
    output_counter = 0;
    max_integrator_value = 0;
    overflow_detected = 0;
    overflow_latched = 0;
    saturation_detected = 0;
    saturation_event_count = 0;
    sample_count = 0;
    max_value_monitor = 0;
    data_out = 0;
    data_out_valid = 0;
    abs_integrator_value = 0;
    temp_scaled_output = 0;
    temp_output = 0;
end

// Enhanced integrator section with proper saturation monitoring
always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        for (i = 0; i < STAGES; i = i + 1) begin
            integrator[i] <= 0;
        end
        decimation_counter <= 0;
        data_valid_delayed <= 0;
        data_valid_comb <= 0;
        max_integrator_value <= 0;
        overflow_detected <= 0;
        sample_count <= 0;
        abs_integrator_value <= 0;
        
        if (reset_monitors) begin
            overflow_latched <= 0;
            saturation_detected <= 0;
            saturation_event_count <= 0;
            max_value_monitor <= 0;
        end
    end else if (data_valid) begin
        sample_count <= sample_count + 1;
        
        // First integrator stage with enhanced saturation detection
        if (integrator[0] + $signed({{18{data_in[17]}}, data_in}) > (2**35 - 1)) begin
            integrator[0] <= (2**35 - 1);
            overflow_detected <= 1'b1;
            overflow_latched <= 1'b1;
            saturation_detected <= 1'b1;
            saturation_event_count <= saturation_event_count + 1;
            `ifdef SIMULATION
            $display("CIC_SATURATION: Positive overflow at sample %0d", sample_count);
            `endif
        end else if (integrator[0] + $signed({{18{data_in[17]}}, data_in}) < -(2**35)) begin
            integrator[0] <= -(2**35);
            overflow_detected <= 1'b1;
            overflow_latched <= 1'b1;
            saturation_detected <= 1'b1;
            saturation_event_count <= saturation_event_count + 1;
            `ifdef SIMULATION
            $display("CIC_SATURATION: Negative overflow at sample %0d", sample_count);
            `endif
        end else begin
            integrator[0] <= integrator[0] + $signed({{18{data_in[17]}}, data_in});
            overflow_detected <= 1'b0;  // Only clear immediate detection, not latched
        end
        
        // Calculate absolute value for monitoring
        abs_integrator_value <= (integrator[0][35]) ? -integrator[0] : integrator[0];
        
        // Track maximum integrator value for gain monitoring (absolute value)
        if (abs_integrator_value > max_integrator_value) begin
            max_integrator_value <= abs_integrator_value;
            max_value_monitor <= abs_integrator_value[31:24];  // Fixed: use the calculated absolute value
        end
        
        // Remaining integrator stages with saturation protection
        for (i = 1; i < STAGES; i = i + 1) begin
            if (integrator[i] + integrator[i-1] > (2**35 - 1)) begin
                integrator[i] <= (2**35 - 1);
                overflow_detected <= 1'b1;
                overflow_latched <= 1'b1;
                saturation_detected <= 1'b1;
            end else if (integrator[i] + integrator[i-1] < -(2**35)) begin
                integrator[i] <= -(2**35);
                overflow_detected <= 1'b1;
                overflow_latched <= 1'b1;
                saturation_detected <= 1'b1;
            end else begin
                integrator[i] <= integrator[i] + integrator[i-1];
            end
        end
        
        // Enhanced decimation control
        if (decimation_counter == DECIMATION - 1) begin
            decimation_counter <= 0;
            data_valid_delayed <= 1;
            output_counter <= output_counter + 1;
            
            /*// Debug output for first few samples
            if (output_counter < 10) begin
                $display("CIC_DECIM: sample=%0d, integrator[%0d]=%h, max_val=%h, sat=%b", 
                         output_counter, STAGES-1, integrator[STAGES-1], 
                         max_integrator_value, saturation_detected);
            end
				*/
        end else begin
            decimation_counter <= decimation_counter + 1;
            data_valid_delayed <= 0;
        end
    end else begin
        data_valid_delayed <= 0;
        overflow_detected <= 1'b0;  // Clear immediate detection when no data
    end
    
    // Monitor control - clear latched saturation on reset_monitors
    if (reset_monitors) begin
        overflow_latched <= 0;
        saturation_detected <= 0;
        max_integrator_value <= 0;
        max_value_monitor <= 0;
        saturation_event_count <= 0;
    end
end

// Pipeline the valid signal for comb section
always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        data_valid_comb <= 0;
    end else begin
        data_valid_comb <= data_valid_delayed;
    end
end

// Enhanced comb section with FIXED scaling and saturation monitoring
always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
        for (i = 0; i < STAGES; i = i + 1) begin
            comb[i] <= 0;
            for (j = 0; j < COMB_DELAY; j = j + 1) begin
                comb_delay[i][j] <= 0;
            end
        end
        data_out <= 0;
        data_out_valid <= 0;
        temp_scaled_output <= 0;
        temp_output <= 0;
    end else if (data_valid_comb) begin
        // Enhanced comb processing with saturation check
        for (i = 0; i < STAGES; i = i + 1) begin
            if (i == 0) begin
                // Check for comb stage saturation
                if (integrator[STAGES-1] - comb_delay[0][COMB_DELAY-1] > (2**35 - 1)) begin
                    comb[0] <= (2**35 - 1);
                    overflow_latched <= 1'b1;
                    saturation_detected <= 1'b1;
                end else if (integrator[STAGES-1] - comb_delay[0][COMB_DELAY-1] < -(2**35)) begin
                    comb[0] <= -(2**35);
                    overflow_latched <= 1'b1;
                    saturation_detected <= 1'b1;
                end else begin
                    comb[0] <= integrator[STAGES-1] - comb_delay[0][COMB_DELAY-1];
                end
                
                // Update delay line for first stage
                for (j = COMB_DELAY-1; j > 0; j = j - 1) begin
                    comb_delay[0][j] <= comb_delay[0][j-1];
                end
                comb_delay[0][0] <= integrator[STAGES-1];
            end else begin
                // Check for comb stage saturation
                if (comb[i-1] - comb_delay[i][COMB_DELAY-1] > (2**35 - 1)) begin
                    comb[i] <= (2**35 - 1);
                    overflow_latched <= 1'b1;
                    saturation_detected <= 1'b1;
                end else if (comb[i-1] - comb_delay[i][COMB_DELAY-1] < -(2**35)) begin
                    comb[i] <= -(2**35);
                    overflow_latched <= 1'b1;
                    saturation_detected <= 1'b1;
                end else begin
                    comb[i] <= comb[i-1] - comb_delay[i][COMB_DELAY-1];
                end
                
                // Update delay line
                for (j = COMB_DELAY-1; j > 0; j = j - 1) begin
                    comb_delay[i][j] <= comb_delay[i][j-1];
                end
                comb_delay[i][0] <= comb[i-1];
            end
        end
        
        // FIXED: Use proper scaling for 5 stages and decimation by 4
        // Gain = (4^5) = 1024 = 2^10, so scale by 2^10 to normalize
        temp_scaled_output <= comb[STAGES-1] >>> 10;
        
        // FIXED: Extract 18-bit output properly
        temp_output <= temp_scaled_output[17:0];
        
        // FIXED: Proper saturation detection for 18-bit signed range
        // Check if the 18-bit truncated value matches the intended value
        if (temp_scaled_output > 131071) begin        // 2^17 - 1
            data_out <= 131071;
            overflow_latched <= 1'b1;
            saturation_detected <= 1'b1;
            saturation_event_count <= saturation_event_count + 1;
            `ifdef SIMULATION
            $display("CIC_OUTPUT_SAT: TRUE Positive saturation, raw=%h, scaled=%h, temp_out=%d, final_out=%d", 
                     comb[STAGES-1], temp_scaled_output, temp_output, 131071);
            `endif
        end else if (temp_scaled_output < -131072) begin  // -2^17
            data_out <= -131072;
            overflow_latched <= 1'b1;
            saturation_detected <= 1'b1;
            saturation_event_count <= saturation_event_count + 1;
            `ifdef SIMULATION
            $display("CIC_OUTPUT_SAT: TRUE Negative saturation, raw=%h, scaled=%h, temp_out=%d, final_out=%d", 
                     comb[STAGES-1], temp_scaled_output, temp_output, -131072);
            `endif
        end else begin
            // FIXED: Use the properly truncated 18-bit value
            data_out <= temp_output;
            overflow_latched <= 1'b0;
            saturation_detected <= 1'b0;
            if (output_counter < 20) begin
                //$display("CIC_OUTPUT_GOOD: raw=%h, scaled=%h, temp_out=%d, final_out=%d", 
                      //   comb[STAGES-1], temp_scaled_output, temp_output, data_out);
            end
        end
        
        data_out_valid <= 1;
        
        // Debug output for first samples
        if (output_counter < 10) begin
           // $display("CIC_DEBUG: sample=%0d, raw=%h, scaled=%h, out=%d, sat=%b", 
             //        output_counter, comb[STAGES-1], temp_scaled_output, data_out, saturation_detected);
        end
    end else begin
        data_out_valid <= 0;
    end
end

// Continuous monitoring of saturation status
`ifdef SIMULATION
always @(posedge clk) begin
    if (overflow_detected && sample_count < 100) begin
        $display("CIC_OVERFLOW: Immediate detection at sample %0d", sample_count);
    end
end
`endif

// Clear saturation on external reset
always @(posedge reset_monitors) begin
    if (reset_monitors) begin
        overflow_latched <= 0;
        saturation_detected <= 0;
        saturation_event_count <= 0;
        //$display("CIC_MONITORS: All monitors reset");
    end
end

endmodule