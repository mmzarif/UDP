module udp_tx #(
    // Ethernet
    parameter logic [47:0] SRC_MAC  = 48'hAA_BB_CC_DD_EE_FF,
    parameter logic [47:0] DST_MAC  = 48'h11_22_33_44_55_66,

    // IP
    parameter logic [31:0] SRC_IP   = {8'd192,8'd168,8'd1,8'd100},
    parameter logic [31:0] DST_IP   = {8'd239,8'd1,8'd1,8'd1},
    parameter logic [7:0]  TTL      = 8'd64,

    // UDP
    parameter logic [15:0] SRC_PORT = 16'd5000,
    parameter logic [15:0] DST_PORT = 16'd5001
)(
    input  logic clk,
    input  logic rst,

    // Payload input stream
    input  logic [7:0]  payload_data,
    input  logic        payload_valid,
    output logic        payload_ready,
    input  logic        payload_last,

    // Ethernet output stream
    output logic [7:0]  eth_data,
    output logic        eth_valid,
    input  logic        eth_ready,
    output logic        eth_last
);

    // ================================================================
    //  State machine
    // ================================================================
    typedef enum logic [2:0] {
        S_IDLE,
        S_ETH,
        S_IP,
        S_UDP,
        S_PAYLOAD,
        S_DONE
    } state_t;

    state_t state, next_state;

    // Counters for header bytes
    logic [5:0] byte_cnt;

    // Payload length counter
    logic [15:0] payload_len;
    logic        in_payload;

    // ================================================================
    //  IP header checksum helper
    //  (Simple incremental sum of fixed header fields)
    // ================================================================
    function automatic logic [15:0] ip_checksum(
        input logic [31:0] src_ip,
        input logic [31:0] dst_ip,
        input logic [15:0] total_length
    );
        logic [31:0] sum;
        begin
            // Version/IHL + DSCP/ECN
            sum = 32'h4500 + total_length + 16'h0000 + 16'h4000;
            sum += 16'h4011;  // TTL (64) + UDP protocol (17)
            sum += src_ip[31:16] + src_ip[15:0];
            sum += dst_ip[31:16] + dst_ip[15:0];

            // Fold
            sum = (sum[31:16] + sum[15:0]);
            sum = (sum[31:16] + sum[15:0]);

            ip_checksum = ~sum[15:0];
        end
    endfunction

    // IP header length (always 20 bytes)
    localparam IP_HDR_LEN  = 20;
    localparam UDP_HDR_LEN = 8;

    // ================================================================
    // FSM transitions
    // ================================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst) state <= S_IDLE;
        else     state <= next_state;
    end

    always_comb begin
        next_state = state;

        case (state)
            S_IDLE:     if (payload_valid) next_state = S_ETH;
            S_ETH:      if (eth_ready && byte_cnt == 13) next_state = S_IP;
            S_IP:       if (eth_ready && byte_cnt == IP_HDR_LEN-1) next_state = S_UDP;
            S_UDP:      if (eth_ready && byte_cnt == UDP_HDR_LEN-1) next_state = S_PAYLOAD;
            S_PAYLOAD:  if (eth_ready && payload_last) next_state = S_DONE;
            S_DONE:     if (eth_ready) next_state = S_IDLE;
        endcase
    end

    // ================================================================
    // Byte counter
    // ================================================================
    always_ff @(posedge clk or posedge rst) begin
        if (rst) byte_cnt <= 0;
        else if (state != next_state) byte_cnt <= 0;
        else if (eth_valid && eth_ready) byte_cnt <= byte_cnt + 1;
    end

    // ================================================================
    // Output logic
    // ================================================================
    assign eth_valid = (state != S_IDLE);
    assign eth_last  = (state == S_DONE);

    assign payload_ready = (state == S_PAYLOAD) && eth_ready;

    // ================================================================
    //  Generate headers by index
    // ================================================================
    logic [15:0] total_len;
    logic [15:0] ip_len;
    logic [15:0] udp_len;
    logic [15:0] csum;

    // Capture payload length on first valid byte
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            payload_len <= 0;
            in_payload  <= 0;
        end
        else begin
            if (state == S_IDLE && payload_valid) begin
                payload_len <= 1;
                in_payload  <= 1;
            end
            else if (in_payload && state == S_PAYLOAD && payload_valid && !payload_last)
                payload_len <= payload_len + 1;
            else if (payload_last)
                in_payload <= 0;
        end
    end

    always_comb begin
        udp_len = payload_len + UDP_HDR_LEN;
        ip_len  = udp_len + IP_HDR_LEN;

        csum = ip_checksum(SRC_IP, DST_IP, ip_len);
    end

    // ================================================================
    // Mux output bytes based on state & byte_cnt
    // ================================================================
    always_comb begin
        eth_data = 8'h00;

        case (state)

            // ----------------------------------------------------------
            // Ethernet Header (14 bytes)
            // ----------------------------------------------------------
            S_ETH: begin
                case (byte_cnt)
                    0: eth_data = DST_MAC[47:40];
                    1: eth_data = DST_MAC[39:32];
                    2: eth_data = DST_MAC[31:24];
                    3: eth_data = DST_MAC[23:16];
                    4: eth_data = DST_MAC[15:8];
                    5: eth_data = DST_MAC[7:0];

                    6: eth_data = SRC_MAC[47:40];
                    7: eth_data = SRC_MAC[39:32];
                    8: eth_data = SRC_MAC[31:24];
                    9: eth_data = SRC_MAC[23:16];
                    10: eth_data = SRC_MAC[15:8];
                    11: eth_data = SRC_MAC[7:0];

                    12: eth_data = 8'h08;  // IPv4 EtherType = 0x0800
                    13: eth_data = 8'h00;
                endcase
            end

            // ----------------------------------------------------------
            // IPv4 Header (20 bytes)
            // ----------------------------------------------------------
            S_IP: begin
                case (byte_cnt)
                    0:  eth_data = 8'h45;             // Version=4, IHL=5
                    1:  eth_data = 8'h00;             // DSCP/ECN
                    2:  eth_data = ip_len[15:8];
                    3:  eth_data = ip_len[7:0];
                    4:  eth_data = 8'h00;             // Identification
                    5:  eth_data = 8'h01;
                    6:  eth_data = 8'h40;             // Flags + Fragment offset
                    7:  eth_data = 8'h00;
                    8:  eth_data = TTL;
                    9:  eth_data = 8'h11;             // Protocol = UDP (17)
                    10: eth_data = csum[15:8];
                    11: eth_data = csum[7:0];
                    12: eth_data = SRC_IP[31:24];
                    13: eth_data = SRC_IP[23:16];
                    14: eth_data = SRC_IP[15:8];
                    15: eth_data = SRC_IP[7:0];
                    16: eth_data = DST_IP[31:24];
                    17: eth_data = DST_IP[23:16];
                    18: eth_data = DST_IP[15:8];
                    19: eth_data = DST_IP[7:0];
                endcase
            end

            // ----------------------------------------------------------
            // UDP Header (8 bytes)
            // ----------------------------------------------------------
            S_UDP: begin
                case (byte_cnt)
                    0: eth_data = SRC_PORT[15:8];
                    1: eth_data = SRC_PORT[7:0];
                    2: eth_data = DST_PORT[15:8];
                    3: eth_data = DST_PORT[7:0];
                    4: eth_data = udp_len[15:8];
                    5: eth_data = udp_len[7:0];
                    6: eth_data = 8'h00;   // checksum = 0 (IPv4 allowed)
                    7: eth_data = 8'h00;
                endcase
            end

            // ----------------------------------------------------------
            // Payload passthrough
            // ----------------------------------------------------------
            S_PAYLOAD: begin
                eth_data = payload_data;
            end

            // Padding on DONE (optional — can be 0)
            S_DONE: begin
                eth_data = 8'h00;
            end
        endcase
    end

endmodule