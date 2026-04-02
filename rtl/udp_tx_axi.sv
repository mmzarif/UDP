// ====================================================================
// udp_tx_axi
// UDP transmitter with AXI-Stream payload input and Ethernet FCS
//
// Generates:
//   - Ethernet header
//   - IPv4 header (20 bytes)
//   - UDP header (8 bytes)
//   - Payload from AXI-Stream
//   - CRC32 Ethernet FCS
//
// Output is AXI-Stream to Ethernet MAC.
// ====================================================================

module udp_tx_axi #(
    parameter MTU_BYTES = 2000
)(
    input  logic clk,
    input  logic rst,

    // ------------------------------------------------------------
    // Payload input (AXI Stream)
    // ------------------------------------------------------------
    input  logic [7:0]  s_payload_tdata,
    input  logic        s_payload_tvalid,
    output logic        s_payload_tready,
    input  logic        s_payload_tlast,

    // ------------------------------------------------------------
    // Ethernet output (AXI Stream)
    // ------------------------------------------------------------
    output logic [7:0]  m_axis_tdata,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic        m_axis_tlast,

    // ------------------------------------------------------------
    // Header parameters
    // ------------------------------------------------------------
    input  logic [47:0] src_mac,
    input  logic [47:0] dst_mac,
    input  logic [31:0] src_ip,
    input  logic [31:0] dst_ip,
    input  logic [15:0] src_port,
    input  logic [15:0] dst_port
);

    // ====================================================================
    // Local constants
    // ====================================================================
    localparam ETH_HDR_LEN = 14;
    localparam IP_HDR_LEN  = 20;
    localparam UDP_HDR_LEN = 8;

    // ====================================================================
    // FSM: Ethernet header → IP header → UDP header → Payload → FCS
    // ====================================================================
    typedef enum logic [2:0] {
        S_IDLE,
        S_ETH,
        S_IP,
        S_UDP,
        S_PAYLOAD,
        S_FCS
    } tx_state_t;

    tx_state_t state, next_state;

    logic [15:0] byte_cnt;

    // ====================================================================
    // Payload length counter (UDP length = payload + 8)
    // ====================================================================
    logic [15:0] payload_len;
    logic        payload_counting;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            payload_len <= 0;
            payload_counting <= 0;
        end else begin
            if (state == S_IDLE && s_payload_tvalid) begin
                payload_len <= 1;
                payload_counting <= 1;
            end else if (payload_counting &&
                         state == S_PAYLOAD &&
                         s_payload_tvalid &&
                         !s_payload_tlast) begin
                payload_len <= payload_len + 1;
            end else if (s_payload_tlast) begin
                payload_counting <= 0;
            end
        end
    end

    // ====================================================================
    // Calculate IPv4 header checksum (standard)
    // ====================================================================
    function automatic logic [15:0] ip_checksum(
        input logic [31:0] src_ip,
        input logic [31:0] dst_ip,
        input logic [15:0] total_length
    );
        logic [31:0] sum;
        begin
            sum = 32'h4500 + total_length + 16'h0000 + 16'h4000;
            sum += 16'h4011; // TTL=64, Protocol=UDP=17
            sum += src_ip[31:16] + src_ip[15:0];
            sum += dst_ip[31:16] + dst_ip[15:0];
            sum = (sum[31:16] + sum[15:0]);
            sum = (sum[31:16] + sum[15:0]);
            ip_checksum = ~sum[15:0];
        end
    endfunction

    logic [15:0] udp_len;
    logic [15:0] ip_len;
    logic [15:0] checksum;

    always_comb begin
        udp_len  = payload_len + UDP_HDR_LEN;
        ip_len   = udp_len + IP_HDR_LEN;
        checksum = ip_checksum(src_ip, dst_ip, ip_len);
    end

    // ====================================================================
    // CRC32 Generator for Ethernet FCS
    // ====================================================================
    logic [31:0] crc_out;
    logic crc_done;

    // Feed CRC for entire frame except FCS bytes.
    wire crc_feed = m_axis_tvalid && m_axis_tready && (state != S_FCS);

    crc32_eth tx_crc32 (
        .clk(clk),
        .rst(rst),
        .valid(crc_feed),
        .data(m_axis_tdata),
        .last(m_axis_tlast),
        .crc_out(crc_out),
        .crc_valid(crc_done)
    );

    // ====================================================================
    // FSM Transition
    // ====================================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            state <= S_IDLE;
        else
            state <= next_state;
    end

    always_comb begin
        next_state = state;

        case (state)
            S_IDLE:
                if (s_payload_tvalid)
                    next_state = S_ETH;

            S_ETH:
                if (m_axis_tvalid && m_axis_tready && byte_cnt == ETH_HDR_LEN-1)
                    next_state = S_IP;

            S_IP:
                if (m_axis_tvalid && m_axis_tready && byte_cnt == IP_HDR_LEN-1)
                    next_state = S_UDP;

            S_UDP:
                if (m_axis_tvalid && m_axis_tready && byte_cnt == UDP_HDR_LEN-1)
                    next_state = S_PAYLOAD;

            S_PAYLOAD:
                if (s_payload_tvalid && m_axis_tready && s_payload_tlast)
                    next_state = S_FCS;

            S_FCS:
                if (m_axis_tvalid && m_axis_tready && byte_cnt == 3)
                    next_state = S_IDLE;
        endcase
    end

    // ====================================================================
    // Byte counter
    // ====================================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            byte_cnt <= 0;
        else if (state != next_state)
            byte_cnt <= 0;
        else if (m_axis_tvalid && m_axis_tready)
            byte_cnt <= byte_cnt + 1;
    end

    // ====================================================================
    // Output Logic
    // ====================================================================
    assign s_payload_tready = (state == S_PAYLOAD) && m_axis_tready;

    always_comb begin
        m_axis_tdata  = 0;
        m_axis_tvalid = 0;
        m_axis_tlast  = 0;

        case (state)

            // ------------------------------------------------------------
            // Ethernet Header
            // ------------------------------------------------------------
            S_ETH: begin
                m_axis_tvalid = 1;
                case (byte_cnt)
                    0: m_axis_tdata = dst_mac[47:40];
                    1: m_axis_tdata = dst_mac[39:32];
                    2: m_axis_tdata = dst_mac[31:24];
                    3: m_axis_tdata = dst_mac[23:16];
                    4: m_axis_tdata = dst_mac[15:8];
                    5: m_axis_tdata = dst_mac[7:0];

                    6: m_axis_tdata = src_mac[47:40];
                    7: m_axis_tdata = src_mac[39:32];
                    8: m_axis_tdata = src_mac[31:24];
                    9: m_axis_tdata = src_mac[23:16];
                    10: m_axis_tdata = src_mac[15:8];
                    11: m_axis_tdata = src_mac[7:0];

                    12: m_axis_tdata = 8'h08; // EtherType IPv4
                    13: m_axis_tdata = 8'h00;
                endcase
            end

            // ------------------------------------------------------------
            // IPv4 Header
            // ------------------------------------------------------------
            S_IP: begin
                m_axis_tvalid = 1;
                case (byte_cnt)
                    0:  m_axis_tdata = 8'h45;
                    1:  m_axis_tdata = 8'h00;
                    2:  m_axis_tdata = ip_len[15:8];
                    3:  m_axis_tdata = ip_len[7:0];
                    4:  m_axis_tdata = 8'h00;
                    5:  m_axis_tdata = 8'h01;
                    6:  m_axis_tdata = 8'h40;
                    7:  m_axis_tdata = 8'h00;
                    8:  m_axis_tdata = 8'h40;   // TTL=64
                    9:  m_axis_tdata = 8'h11;   // UDP protocol
                    10: m_axis_tdata = checksum[15:8];
                    11: m_axis_tdata = checksum[7:0];
                    12: m_axis_tdata = src_ip[31:24];
                    13: m_axis_tdata = src_ip[23:16];
                    14: m_axis_tdata = src_ip[15:8];
                    15: m_axis_tdata = src_ip[7:0];
                    16: m_axis_tdata = dst_ip[31:24];
                    17: m_axis_tdata = dst_ip[23:16];
                    18: m_axis_tdata = dst_ip[15:8];
                    19: m_axis_tdata = dst_ip[7:0];
                endcase
            end

            // ------------------------------------------------------------
            // UDP Header
            // ------------------------------------------------------------
            S_UDP: begin
                m_axis_tvalid = 1;
                case (byte_cnt)
                    0: m_axis_tdata = src_port[15:8];
                    1: m_axis_tdata = src_port[7:0];
                    2: m_axis_tdata = dst_port[15:8];
                    3: m_axis_tdata = dst_port[7:0];
                    4: m_axis_tdata = udp_len[15:8];
                    5: m_axis_tdata = udp_len[7:0];
                    6: m_axis_tdata = 8'h00; // checksum optional for IPv4
                    7: m_axis_tdata = 8'h00;
                endcase
            end

            // ------------------------------------------------------------
            // Payload
            // ------------------------------------------------------------
            S_PAYLOAD: begin
                m_axis_tvalid = s_payload_tvalid;
                m_axis_tdata  = s_payload_tdata;
            end

            // ------------------------------------------------------------
            // FCS: emit 32-bit CRC32 little-endian
            // ------------------------------------------------------------
            S_FCS: begin
                m_axis_tvalid = 1;
                case (byte_cnt)
                    0: m_axis_tdata = crc_out[7:0];
                    1: m_axis_tdata = crc_out[15:8];
                    2: m_axis_tdata = crc_out[23:16];
                    3: m_axis_tdata = crc_out[31:24];
                endcase

                if (byte_cnt == 3)
                    m_axis_tlast = 1;
            end
        endcase
    end

endmodule
``