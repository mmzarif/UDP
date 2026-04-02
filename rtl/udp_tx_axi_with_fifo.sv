// ====================================================================
// udp_tx_axi_with_fifo
//
// AXI-Stream UDP Transmit Path:
//   USER (AXI Stream payload)
//       │
//       ▼
//   axis_fifo  (buffers payload)
//       │
//       ▼
//   udp_tx_axi (adds Eth + IPv4 + UDP headers)
//       │
//       ▼
//   MAC TX (AXI Stream)
//
// ====================================================================

module udp_tx_axi_with_fifo #(
    parameter integer FIFO_DEPTH = 2048
)(
    input  logic clk,
    input  logic rst,

    // ============================================================
    // USER PAYLOAD INPUT (AXI-Stream)
    // ============================================================
    input  logic [7:0]  user_tdata,
    input  logic        user_tvalid,
    output logic        user_tready,
    input  logic        user_tlast,

    // ============================================================
    // OUTPUT TO ETHERNET MAC (AXI-Stream)
    // ============================================================
    output logic [7:0]  mac_tdata,
    output logic        mac_tvalid,
    input  logic        mac_tready,
    output logic        mac_tlast,

    // ============================================================
    // UDP/IP/Ethernet parameters
    // ============================================================
    input  logic [31:0] src_ip,
    input  logic [31:0] dst_ip,
    input  logic [15:0] src_port,
    input  logic [15:0] dst_port,

    input  logic [47:0] src_mac,
    input  logic [47:0] dst_mac
);

    // ====================================================================
    // FIFO → TX signals
    // ====================================================================
    logic [7:0] fifo_tdata;
    logic       fifo_tvalid;
    logic       fifo_tlast;
    logic       fifo_tready;

    // ====================================================================
    // Payload FIFO
    // ====================================================================
    axis_fifo #(
        .WIDTH(8),
        .DEPTH(FIFO_DEPTH)
    ) payload_fifo (
        .clk(clk),
        .rst(rst),

        // USER writes payload here
        .s_axis_tdata (user_tdata),
        .s_axis_tvalid(user_tvalid),
        .s_axis_tlast (user_tlast),
        .s_axis_tready(user_tready),

        // UDP TX pulls payload here
        .m_axis_tdata (fifo_tdata),
        .m_axis_tvalid(fifo_tvalid),
        .m_axis_tlast (fifo_tlast),
        .m_axis_tready(fifo_tready),

        .flush(1'b0)   // TX usually does not flush FIFO
    );

    // ====================================================================
    // UDP TX AXI module
    // ====================================================================
    udp_tx_axi udp_tx_inst (
        .clk(clk),
        .rst(rst),

        // ------------------------
        // Payload input (from FIFO)
        // ------------------------
        .s_payload_tdata (fifo_tdata),
        .s_payload_tvalid(fifo_tvalid),
        .s_payload_tlast (fifo_tlast),
        .s_payload_tready(fifo_tready),

        // ------------------------
        // Ethernet output
        // ------------------------
        .m_axis_tdata (mac_tdata),
        .m_axis_tvalid(mac_tvalid),
        .m_axis_tready(mac_tready),
        .m_axis_tlast (mac_tlast),

        // ------------------------
        // Header configuration
        // ------------------------
        .src_ip  (src_ip),
        .dst_ip  (dst_ip),
        .src_port(src_port),
        .dst_port(dst_port),
        .src_mac (src_mac),
        .dst_mac (dst_mac)
    );

endmodule