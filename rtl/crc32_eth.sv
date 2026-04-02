module crc32_eth (
    input  logic       clk,
    input  logic       rst,
    input  logic       valid,
    input  logic [7:0] data,
    input  logic       last,
    output logic [31:0] crc_out,
    output logic        crc_valid
);

    logic [31:0] crc_reg;
    logic        crc_valid_r;

    // Output assignments
    assign crc_out   = ~crc_reg;      // Final XOR
    assign crc_valid = crc_valid_r;

    // Update CRC on each byte
    function automatic [31:0] next_crc32(
        input [7:0] d,
        input [31:0] crc
    );
        integer i;
        reg [31:0] c;
        reg [7:0]  b;
        begin
            c = crc;
            b = d;
            c = c ^ {24'h0, b};
            for (i = 0; i < 8; i++) begin
                if (c[0])
                    c = (c >> 1) ^ 32'hEDB88320;  // reflected poly
                else
                    c = (c >> 1);
            end
            next_crc32 = c;
        end
    endfunction

    // Sequential logic
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            crc_reg      <= 32'hFFFFFFFF;
            crc_valid_r  <= 1'b0;
        end else begin
            crc_valid_r <= 1'b0;

            if (valid) begin
                crc_reg <= next_crc32(data, crc_reg);
            end

            if (last && valid) begin
                crc_valid_r <= 1'b1;
            end
        end
    end

endmodule