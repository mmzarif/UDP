`timescale 1ns/1ps

module tb_udp_tx_rx_loopback;

    // ===============================================================
    // Clock & Reset
    // ===============================================================
    logic clk = 0;
    logic rst = 1;

    always #5 clk = ~clk;   // 100 MHz

    initial begin
        rst = 1;
        repeat (10) @(posedge clk);
        rst = 0;
    end

    // ===============================================================
    // DUT Parameters
    // ===============================================================
    localparam SRC_MAC = 48'hAA_BB_CC_DD_EE_FF;
    localparam DST_MAC = 48'h11_22_33_44_55_66;

    localparam SRC_IP  = {8'd10,8'd0,8'd0,8'd1};
    localparam DST_IP  = {8'd10,8'd0,8'd0,8'd2};

    localparam SRC_PORT = 16'd5000;
    localparam DST_PORT = 16'd6000;

    // ===============================================================
    // DUT I/O for UDP TX
    // ===============================================================
    logic [7:0]  user_tdata;
    logic        user_tvalid;
    logic        user_tready;
    logic        user_tlast;

    logic [7:0]  mac_tx_tdata;
    logic        mac_tx_tvalid;
    logic        mac_tx_tready;
    logic        mac_tx_tlast;

    // ===============================================================
    // DUT I/O for UDP RX
    // (loopback: MAC TX output → RX input)
    // ===============================================================
    logic [7:0]  mac_rx_tdata;
    logic        mac_rx_tvalid;
    logic        mac_rx_tready;
    logic        mac_rx_tlast;

    logic [7:0]  rx_payload_tdata;
    logic        rx_payload_tvalid;
    logic        rx_payload_tlast;
    logic        rx_payload_tready = 1;

    logic [31:0] rx_src_ip;
    logic [15:0] rx_src_port;

    // ===============================================================
    // Instantiate UDP TX with FIFO
    // ===============================================================
    udp_tx_axi_with_fifo tx_dut (
        .clk(clk),
        .rst(rst),

        .user_tdata (user_tdata),
        .user_tvalid(user_tvalid),
        .user_tready(user_tready),
        .user_tlast (user_tlast),

        .mac_tdata (mac_tx_tdata),
        .mac_tvalid(mac_tx_tvalid),
        .mac_tready(mac_tx_tready),
        .mac_tlast (mac_tx_tlast),

        .src_ip  (SRC_IP),
        .dst_ip  (DST_IP),
        .src_port(SRC_PORT),
        .dst_port(DST_PORT),

        .src_mac (SRC_MAC),
        .dst_mac (DST_MAC)
    );

    // ===============================================================
    // Instantiate UDP RX with FIFO
    // ===============================================================
    udp_rx_axi_with_fifo rx_dut (
        .clk(clk),
        .rst(rst),

        .s_axis_tdata (mac_rx_tdata),
        .s_axis_tvalid(mac_rx_tvalid),
        .s_axis_tready(mac_rx_tready),
        .s_axis_tlast (mac_rx_tlast),

        .m_axis_tdata (rx_payload_tdata),
        .m_axis_tvalid(rx_payload_tvalid),
        .m_axis_tready(rx_payload_tready),
        .m_axis_tlast (rx_payload_tlast),

        .src_ip  (rx_src_ip),
        .src_port(rx_src_port)
    );

    // ===============================================================
    // Loopback MAC TX → RX wiring
    // ===============================================================
    assign mac_rx_tdata  = mac_tx_tdata;
    assign mac_rx_tvalid = mac_tx_tvalid;
    assign mac_tx_tready = mac_rx_tready;
    assign mac_rx_tlast  = mac_tx_tlast;

    // ===============================================================
    // TEST PAYLOAD STORAGE
    // ===============================================================
    byte test_payload [0:31];
    byte rx_captured  [0:31];

    initial begin
        foreach (test_payload[i])
            test_payload[i] = i + 8'h30; // ASCII 0–31
    end

    int rx_index = 0;

    // Capture received bytes
    always @(posedge clk) begin
        if (rx_payload_tvalid) begin
            rx_captured[rx_index] = rx_payload_tdata;
            rx_index++;
        end
        if (rx_payload_tvalid && rx_payload_tlast) begin
            $display("RX Payload finished, len=%0d", rx_index);
        end
    end

    // ===============================================================
    // Drive TX payload
    // ===============================================================
    initial begin
        user_tdata  = 0;
        user_tvalid = 0;
        user_tlast  = 0;

        @(negedge rst);
        repeat (5) @(posedge clk);

        $display("=== Sending Payload into UDP TX ===");

        for (int i = 0; i < 32; i++) begin
            @(posedge clk);
            user_tdata  <= test_payload[i];
            user_tvalid <= 1;
            user_tlast  <= (i == 31);
            wait (user_tready);
        end

        @(posedge clk);
        user_tvalid <= 0;
        user_tlast  <= 0;
    end

    // ===============================================================
    // Self-checking logic
    // ===============================================================
    initial begin
        // Wait for RX packet to complete
        wait(rx_payload_tlast);
        @(posedge clk);

        $display("=== Checking payload correctness ===");

        for (int i = 0; i < 32; i++) begin
            if (rx_captured[i] !== test_payload[i]) begin
                $display("ERROR: Mismatch at index %0d: expected 0x%02x, got 0x%02x",
                    i, test_payload[i], rx_captured[i]);
                $fatal;
            end
        end

        $display("PASS: Payload matches exactly!");
        $finish;
    end

endmodule