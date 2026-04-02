module udp_rx_axi #(
    parameter logic [47:0] MY_MAC   = 48'hAA_BB_CC_DD_EE_FF,
    parameter logic [31:0] MY_IP    = {8'd192,8'd168,8'd1,8'd100},
    parameter logic [15:0] MY_PORT  = 16'd5001
)(
    input  logic clk,
    input  logic rst,

    // AXI-Stream input (Ethernet frame)
    input  logic [7:0]  s_axis_tdata,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,

    // AXI-Stream output (UDP payload)
    output logic [7:0]  m_axis_tdata,
    output logic        m_axis_tvalid,
    input  logic        m_axis_tready,
    output logic        m_axis_tlast,

    // Metadata
    output logic [31:0] src_ip,
    output logic [15:0] src_port
);

    // ================================================================
    // FSM
    // ================================================================
    typedef enum logic [2:0] {
        S_ETH,
        S_IP,
        S_UDP,
        S_PAYLOAD,
        S_DROP
    } state_t;

    state_t state, next_state;
    logic [6:0] byte_cnt;

    // ================================================================
    // Header Storage
    // ================================================================
    logic [47:0] dst_mac, src_mac;
    logic [31:0] ip_src, ip_dst;
    logic [15:0] udp_src_port, udp_dst_port;
    logic [15:0] udp_len, ip_total_len;

    assign src_ip   = ip_src;
    assign src_port = udp_src_port;

    // ================================================================
    // CRC‑32 Handling
    // ================================================================
    logic [31:0] crc_calc;
    logic        crc_done;
    logic [31:0] fcs_shift;
    logic [2:0]  fcs_countdown;

    // Track FCS bytes arrival for exclusion from CRC
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            fcs_countdown <= 0;
        else if (s_axis_tvalid && s_axis_tlast)
            fcs_countdown <= 3;
        else if (s_axis_tvalid && (fcs_countdown != 0))
            fcs_countdown <= fcs_countdown - 1;
    end

    wire crc_enable = s_axis_tvalid && s_axis_tready && (fcs_countdown == 0);

    // Shift register to capture received FCS
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            fcs_shift <= 32'h0;
        else if (s_axis_tvalid && s_axis_tready)
            fcs_shift <= {fcs_shift[23:0], s_axis_tdata};
    end

    // Instantiate CRC32 module
    crc32_eth crc_inst (
        .clk       (clk),
        .rst       (rst),
        .valid     (crc_enable),
        .data      (s_axis_tdata),
        .last      (s_axis_tlast),
        .crc_out   (crc_calc),
        .crc_valid (crc_done)
    );

    wire crc_ok = (crc_done && (crc_calc == fcs_shift));

    // ================================================================
    // AXI Ready Logic
    // ================================================================
    assign s_axis_tready =
        (state != S_PAYLOAD) ? 1'b1 :    // Always accept headers
        (m_axis_tready);                 // Backpressure only during payload

    // ================================================================
    // Payload Output (AXI Stream)
    // ================================================================
    logic payload_enable;

    assign m_axis_tdata  = s_axis_tdata;
    assign m_axis_tvalid = (state == S_PAYLOAD) &&
                           s_axis_tvalid &&
                           payload_enable;

    assign m_axis_tlast  = m_axis_tvalid && s_axis_tlast;

    // Payload enable control
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            payload_enable <= 0;

        else if (state == S_ETH && next_state == S_IP)
            payload_enable <= 0;

        else if (state == S_UDP && next_state == S_PAYLOAD)
            payload_enable <= 1;

        else if (state == S_PAYLOAD && s_axis_tlast && !crc_ok)
            payload_enable <= 0;
    end

    // ================================================================
    // FSM Transitions
    // ================================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            state <= S_ETH;
        else
            state <= next_state;
    end

    always_comb begin
        next_state = state;

        case (state)

            // Ethernet header (14 bytes)
            S_ETH: begin
                if (s_axis_tvalid && s_axis_tlast)
                    next_state = S_DROP;
                else if (s_axis_tvalid && byte_cnt == 13)
                    next_state = S_IP;
            end

            // IPv4 header (20 bytes)
            S_IP: begin
                if (s_axis_tvalid && s_axis_tlast)
                    next_state = S_DROP;
                else if (s_axis_tvalid && byte_cnt == 19)
                    next_state = S_UDP;
            end

            // UDP header (8 bytes)
            S_UDP: begin
                if (s_axis_tvalid && s_axis_tlast)
                    next_state = S_DROP;
                else if (s_axis_tvalid && byte_cnt == 7)
                    next_state =
                        (udp_dst_port == MY_PORT) ? S_PAYLOAD : S_DROP;
            end

            // Payload until last
            S_PAYLOAD: begin
                if (s_axis_tvalid && s_axis_tlast)
                    next_state = S_ETH;   // always return to fresh frame
            end

            // Drop unwanted frame
            S_DROP: begin
                if (s_axis_tvalid && s_axis_tlast)
                    next_state = S_ETH;
            end
        endcase
    end

    // ================================================================
    // Byte Counter
    // ================================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            byte_cnt <= 0;
        else if (state != next_state)
            byte_cnt <= 0;
        else if (s_axis_tvalid && s_axis_tready)
            byte_cnt <= byte_cnt + 1;
    end

    // ================================================================
    // Header Parsing
    // ================================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            dst_mac      <= '0;
            src_mac      <= '0;
            ip_src       <= '0;
            ip_dst       <= '0;
            udp_src_port <= '0;
            udp_dst_port <= '0;
            udp_len      <= '0;
            ip_total_len <= '0;
        end
        else if (s_axis_tvalid && s_axis_tready) begin
            case (state)

                S_ETH: begin
                    case (byte_cnt)
                        0: dst_mac[47:40] <= s_axis_tdata;
                        1: dst_mac[39:32] <= s_axis_tdata;
                        2: dst_mac[31:24] <= s_axis_tdata;
                        3: dst_mac[23:16] <= s_axis_tdata;
                        4: dst_mac[15:8]  <= s_axis_tdata;
                        5: dst_mac[7:0]   <= s_axis_tdata;

                        6: src_mac[47:40] <= s_axis_tdata;
                        7: src_mac[39:32] <= s_axis_tdata;
                        8: src_mac[31:24] <= s_axis_tdata;
                        9: src_mac[23:16] <= s_axis_tdata;
                        10: src_mac[15:8] <= s_axis_tdata;
                        11: src_mac[7:0]  <= s_axis_tdata;
                    endcase
                end

                S_IP: begin
                    case (byte_cnt)
                        2: ip_total_len[15:8] <= s_axis_tdata;
                        3: ip_total_len[7:0]  <= s_axis_tdata;

                        12: ip_src[31:24] <= s_axis_tdata;
                        13: ip_src[23:16] <= s_axis_tdata;
                        14: ip_src[15:8]  <= s_axis_tdata;
                        15: ip_src[7:0]   <= s_axis_tdata;

                        16: ip_dst[31:24] <= s_axis_tdata;
                        17: ip_dst[23:16] <= s_axis_tdata;
                        18: ip_dst[15:8]  <= s_axis_tdata;
                        19: ip_dst[7:0]   <= s_axis_tdata;
                    endcase
                end

                S_UDP: begin
                    case (byte_cnt)
                        0: udp_src_port[15:8] <= s_axis_tdata;
                        1: udp_src_port[7:0]  <= s_axis_tdata;

                        2: udp_dst_port[15:8] <= s_axis_tdata;
                        3: udp_dst_port[7:0]  <= s_axis_tdata;

                        4: udp_len[15:8] <= s_axis_tdata;
                        5: udp_len[7:0]  <= s_axis_tdata;
                    endcase
                end
            endcase
        end
    end

endmodule