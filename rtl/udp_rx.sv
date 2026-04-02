module udp_rx #(
    // Expected Ethernet/IP/UDP filters
    parameter logic [47:0] MY_MAC   = 48'hAA_BB_CC_DD_EE_FF,
    parameter logic [31:0] MY_IP    = {8'd192,8'd168,8'd1,8'd100},
    parameter logic [15:0] MY_PORT  = 16'd5001
)(
    input  logic clk,
    input  logic rst,

    // Ethernet input stream
    input  logic [7:0]  eth_data,
    input  logic        eth_valid,
    output logic        eth_ready,
    input  logic        eth_last,

    // Payload output stream
    output logic [7:0]  payload_data,
    output logic        payload_valid,
    input  logic        payload_ready,
    output logic        payload_last,

    // Metadata outputs
    output logic [31:0] src_ip,
    output logic [15:0] src_port
);

    // ================================================================
    //  State machine
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

    // Header buffers
    logic [47:0] dst_mac, src_mac;
    logic [31:0] ip_src, ip_dst;
    logic [15:0] udp_src_port, udp_dst_port;
    logic [15:0] udp_len, ip_total_len;

    // CRC calculator signals
    logic [31:0] crc_calc;
    logic        crc_done;
    logic        crc_ok;

    logic payload_enable;

    // Buffer last 4 bytes of frame (FCS)
    logic [31:0] fcs_shift;

    // Track final 4 bytes so CRC excludes FCS
    logic [2:0] fcs_countdown;

    // ================================================================
    //  CRC32 modules & logic
    // ================================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            fcs_countdown <= 0;
        else if (eth_valid && eth_last)
            fcs_countdown <= 3;  // next 3 bytes after this one are FCS
        else if (eth_valid && fcs_countdown != 0)
            fcs_countdown <= fcs_countdown - 1;
    end

    wire crc_enable = eth_valid && eth_ready && (fcs_countdown == 0);

    // Capture incoming FCS (last 4 bytes)
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            fcs_shift <= 32'h0;
        else if (eth_valid && eth_ready)
            fcs_shift <= {fcs_shift[23:0], eth_data};
    end

    // CRC32 instance
    crc32_eth crc_inst (
        .clk        (clk),
        .rst        (rst),
        .valid      (crc_enable),
        .data       (eth_data),
        .last       (eth_last),
        .crc_out    (crc_calc),
        .crc_valid  (crc_done)
    );

    assign crc_ok = (crc_done && fcs_shift == crc_calc);

    // ================================================================
    //  Output assignments
    // ================================================================
    assign src_ip   = ip_src;
    assign src_port = udp_src_port;

    assign eth_ready = (state != S_PAYLOAD) ? 1'b1 :
                       (payload_ready     ? 1'b1 : 1'b0);

    assign payload_data = (state == S_PAYLOAD) ? eth_data : 8'h00;

    assign payload_valid =
           payload_enable &&
           (state == S_PAYLOAD) &&
           eth_valid;

    assign payload_last =
           payload_valid && eth_last;

    // ================================================================
    //  Payload enable logic (corrected)
    // ================================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            payload_enable <= 0;

        else if (state == S_ETH && next_state == S_IP)
            payload_enable <= 0;  // reset per-frame

        else if (state == S_UDP && next_state == S_PAYLOAD)
            payload_enable <= 1;  // entering payload

        else if (state == S_PAYLOAD && eth_last && !crc_ok)
            payload_enable <= 0;  // disable on bad CRC
    end

    // ================================================================
    //  FSM transition logic
    // ================================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst) state <= S_ETH;
        else     state <= next_state;
    end

    always_comb begin
        next_state = state;

        case (state)
            // Ethernet header: 14 bytes
            S_ETH: begin
                if (eth_valid && eth_last)
                    next_state = S_DROP;
                else if (eth_valid && byte_cnt == 13)
                    next_state = S_IP;
            end

            // IPv4 header: 20 bytes
            S_IP: begin
                if (eth_valid && eth_last)
                    next_state = S_DROP;
                else if (eth_valid && byte_cnt == 19)
                    next_state = S_UDP;
            end

            // UDP header: 8 bytes
            S_UDP: begin
                if (eth_valid && eth_last)
                    next_state = S_DROP;
                else if (eth_valid && byte_cnt == 7)
                    next_state = (udp_dst_port == MY_PORT) ? S_PAYLOAD : S_DROP;
            end

            // Payload until eth_last
            S_PAYLOAD: begin
                if (eth_valid && eth_last)
                    next_state = S_ETH;   // ALWAYS restart cleanly
            end

            // Drop mode
            S_DROP: begin
                if (eth_valid && eth_last)
                    next_state = S_ETH;   // ALWAYS restart cleanly
            end
        endcase
    end

    // ================================================================
    //  Byte counter per state
    // ================================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            byte_cnt <= 0;
        else if (state != next_state)
            byte_cnt <= 0;
        else if (eth_valid && eth_ready)
            byte_cnt <= byte_cnt + 1;
    end

    // ================================================================
    //  Header parsing
    // ================================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            dst_mac        <= '0;
            src_mac        <= '0;
            ip_src         <= '0;
            ip_dst         <= '0;
            udp_src_port   <= '0;
            udp_dst_port   <= '0;
            udp_len        <= '0;
            ip_total_len   <= '0;
        end
        else if (eth_valid && eth_ready) begin
            case (state)

                // Ethernet header
                S_ETH: begin
                    case (byte_cnt)
                        0: dst_mac[47:40] <= eth_data;
                        1: dst_mac[39:32] <= eth_data;
                        2: dst_mac[31:24] <= eth_data;
                        3: dst_mac[23:16] <= eth_data;
                        4: dst_mac[15:8]  <= eth_data;
                        5: dst_mac[7:0]   <= eth_data;

                        6: src_mac[47:40] <= eth_data;
                        7: src_mac[39:32] <= eth_data;
                        8: src_mac[31:24] <= eth_data;
                        9: src_mac[23:16] <= eth_data;
                        10: src_mac[15:8] <= eth_data;
                        11: src_mac[7:0]  <= eth_data;
                    endcase
                end

                // IPv4 header
                S_IP: begin
                    case (byte_cnt)
                        2:  ip_total_len[15:8] <= eth_data;
                        3:  ip_total_len[7:0]  <= eth_data;

                        12: ip_src[31:24] <= eth_data;
                        13: ip_src[23:16] <= eth_data;
                        14: ip_src[15:8]  <= eth_data;
                        15: ip_src[7:0]   <= eth_data;

                        16: ip_dst[31:24] <= eth_data;
                        17: ip_dst[23:16] <= eth_data;
                        18: ip_dst[15:8]  <= eth_data;
                        19: ip_dst[7:0]   <= eth_data;
                    endcase
                end

                // UDP header
                S_UDP: begin
                    case (byte_cnt)
                        0: udp_src_port[15:8] <= eth_data;
                        1: udp_src_port[7:0]  <= eth_data;

                        2: udp_dst_port[15:8] <= eth_data;
                        3: udp_dst_port[7:0]  <= eth_data;

                        4: udp_len[15:8] <= eth_data;
                        5: udp_len[7:0]  <= eth_data;
                    endcase
                end

            endcase
        end
    end

endmodule