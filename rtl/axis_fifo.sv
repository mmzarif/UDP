module axis_fifo #(
    parameter WIDTH = 8,
    parameter DEPTH = 2048             // Enough for 1500B payload + margin
)(
    input  logic clk,
    input  logic rst,

    // AXI-Stream slave input
    input  logic [WIDTH-1:0] s_axis_tdata,
    input  logic             s_axis_tvalid,
    output logic             s_axis_tready,
    input  logic             s_axis_tlast,

    // AXI-Stream master output
    output logic [WIDTH-1:0] m_axis_tdata,
    output logic             m_axis_tvalid,
    input  logic             m_axis_tready,
    output logic             m_axis_tlast,

    // Control signals
    input  logic flush       // Clears FIFO contents immediately
);

    // ================================================================
    // FIFO storage
    // ================================================================
    typedef struct packed {
        logic [WIDTH-1:0] data;
        logic             last;
    } fifo_word_t;

    fifo_word_t mem [DEPTH-1:0];

    logic [$clog2(DEPTH):0] wr_ptr;
    logic [$clog2(DEPTH):0] rd_ptr;

    logic full;
    logic empty;

    assign full  = (wr_ptr == (rd_ptr ^ DEPTH));
    assign empty = (wr_ptr == rd_ptr);

    // Write logic
    assign s_axis_tready = !full;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            wr_ptr <= 0;
        end else if (flush) begin
            wr_ptr <= 0;      // Clear FIFO
        end else if (s_axis_tvalid && s_axis_tready) begin
            mem[wr_ptr[ $clog2(DEPTH)-1 : 0 ]] <= '{data:s_axis_tdata, last:s_axis_tlast};
            wr_ptr <= wr_ptr + 1;
        end
    end

    // Read logic
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            rd_ptr <= 0;
        end else if (flush) begin
            rd_ptr <= 0;
        end else if (m_axis_tready && !empty) begin
            rd_ptr <= rd_ptr + 1;
        end
    end

    assign m_axis_tvalid = !empty;
    assign m_axis_tdata  = mem[ rd_ptr[$clog2(DEPTH)-1 : 0] ].data;
    assign m_axis_tlast  = mem[ rd_ptr[$clog2(DEPTH)-1 : 0] ].last;

endmodule