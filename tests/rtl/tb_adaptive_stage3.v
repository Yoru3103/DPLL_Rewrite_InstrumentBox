`timescale 1ns / 1ps

module tb_adaptive_stage3;
reg bus_clk = 1'b0;
reg loop_clk = 1'b0;
reg reset_n = 1'b0;
always #4 bus_clk = ~bus_clk;
always #7 loop_clk = ~loop_clk;

reg stats_clk = 1'b0;
always #5 stats_clk = ~stats_clk;
reg [15:0] amplitude;
reg signed [13:0] frequency_error;
reg signed [31:0] phase_error, loop_output;
reg locked, rail_positive, rail_negative, frequency_bad, phase_bad;
wire [31:0] snapshot_seq, sample_count;
wire snapshot_toggle;
wire [63:0] amplitude_sum, frequency_abs_sum, phase_abs_sum;
wire [15:0] amplitude_min, amplitude_max;
wire [31:0] frequency_abs_max, phase_abs_max, output_min, output_max;
wire [31:0] locked_samples, pos_samples, neg_samples, freq_bad_samples, phase_bad_samples;
wire [31:0] loss_events, pos_events, neg_events;

adaptive_statistics #(.WINDOW_LOG2(2)) stats_dut (
    .clk(stats_clk), .reset_n(reset_n), .amplitude(amplitude),
    .frequency_error(frequency_error), .phase_error(phase_error),
    .loop_output(loop_output), .locked(locked), .rail_positive(rail_positive),
    .rail_negative(rail_negative), .frequency_bad(frequency_bad), .phase_bad(phase_bad),
    .snapshot_seq(snapshot_seq), .snapshot_toggle(snapshot_toggle), .sample_count(sample_count),
    .amplitude_sum(amplitude_sum), .amplitude_min(amplitude_min), .amplitude_max(amplitude_max),
    .frequency_abs_sum(frequency_abs_sum), .frequency_abs_max(frequency_abs_max),
    .phase_abs_sum(phase_abs_sum), .phase_abs_max(phase_abs_max),
    .output_min(output_min), .output_max(output_max), .locked_sample_count(locked_samples),
    .positive_rail_sample_count(pos_samples), .negative_rail_sample_count(neg_samples),
    .frequency_bad_sample_count(freq_bad_samples), .phase_bad_sample_count(phase_bad_samples),
    .loss_of_lock_event_count(loss_events), .positive_rail_event_count(pos_events),
    .negative_rail_event_count(neg_events)
);

reg same_write, same_legacy_changed;
reg [15:0] same_address;
reg [31:0] same_wdata;
wire [31:0] same_loop_kp, same_loop_ki, same_loop_kii, same_loop_kd, same_loop_dcoef;
wire same_gain_changed;
wire [7:0] same_shadow_profile, same_active_profile;
wire [31:0] same_shadow_kp, same_shadow_ki, same_shadow_kii, same_shadow_kd, same_shadow_dcoef;
wire [31:0] same_applied_seq, same_status, same_active_kp, same_active_ki;
wire [31:0] same_active_kii, same_active_kd, same_active_dcoef, same_errors;

adaptive_param_commit_same_clock same_dut (
    .clk(bus_clk), .reset_n(reset_n), .bus_write(same_write), .bus_address(same_address),
    .bus_wdata(same_wdata), .legacy_changed(same_legacy_changed),
    .legacy_kp(32'd101), .legacy_ki(32'd102), .legacy_kii(32'd103),
    .legacy_kd(32'd104), .legacy_dcoef(32'd105),
    .loop_kp(same_loop_kp), .loop_ki(same_loop_ki), .loop_kii(same_loop_kii),
    .loop_kd(same_loop_kd), .loop_dcoef(same_loop_dcoef), .loop_gain_changed(same_gain_changed),
    .shadow_profile(same_shadow_profile), .shadow_kp(same_shadow_kp), .shadow_ki(same_shadow_ki),
    .shadow_kii(same_shadow_kii), .shadow_kd(same_shadow_kd), .shadow_dcoef(same_shadow_dcoef),
    .applied_seq(same_applied_seq), .apply_status(same_status), .active_profile(same_active_profile),
    .active_kp(same_active_kp), .active_ki(same_active_ki), .active_kii(same_active_kii),
    .active_kd(same_active_kd), .active_dcoef(same_active_dcoef),
    .commit_error_count(same_errors)
);

reg cdc_write, cdc_legacy_changed;
reg [15:0] cdc_address;
reg [31:0] cdc_wdata;
wire [31:0] cdc_loop_kp, cdc_loop_ki, cdc_loop_kii, cdc_loop_kd, cdc_loop_dcoef;
wire cdc_gain_changed;
wire [7:0] cdc_shadow_profile, cdc_active_profile;
wire [31:0] cdc_shadow_kp, cdc_shadow_ki, cdc_shadow_kii, cdc_shadow_kd, cdc_shadow_dcoef;
wire [31:0] cdc_applied_seq, cdc_status, cdc_active_kp, cdc_active_ki;
wire [31:0] cdc_active_kii, cdc_active_kd, cdc_active_dcoef, cdc_errors;
integer cdc_pulse_count;
integer phase_index;

adaptive_param_commit_cdc cdc_dut (
    .bus_clk(bus_clk), .loop_clk(loop_clk), .reset_n(reset_n),
    .bus_write(cdc_write), .bus_address(cdc_address), .bus_wdata(cdc_wdata),
    .legacy_changed(cdc_legacy_changed), .legacy_kp(32'd201), .legacy_ki(32'd202),
    .legacy_kii(32'd203), .legacy_kd(32'd204), .legacy_dcoef(32'd205),
    .loop_kp(cdc_loop_kp), .loop_ki(cdc_loop_ki), .loop_kii(cdc_loop_kii),
    .loop_kd(cdc_loop_kd), .loop_dcoef(cdc_loop_dcoef), .loop_gain_changed(cdc_gain_changed),
    .shadow_profile(cdc_shadow_profile), .shadow_kp(cdc_shadow_kp), .shadow_ki(cdc_shadow_ki),
    .shadow_kii(cdc_shadow_kii), .shadow_kd(cdc_shadow_kd), .shadow_dcoef(cdc_shadow_dcoef),
    .applied_seq(cdc_applied_seq), .apply_status(cdc_status),
    .active_profile_bus(cdc_active_profile), .active_kp_bus(cdc_active_kp),
    .active_ki_bus(cdc_active_ki), .active_kii_bus(cdc_active_kii),
    .active_kd_bus(cdc_active_kd), .active_dcoef_bus(cdc_active_dcoef),
    .commit_error_count(cdc_errors)
);

reg cdc_data_toggle;
reg [31:0] cdc_source_data;
wire [31:0] cdc_destination_data;
adaptive_snapshot_cdc #(.DATA_WIDTH(32)) snapshot_cdc_dut (
    .dst_clk(bus_clk), .dst_reset_n(reset_n), .src_toggle(cdc_data_toggle),
    .src_data(cdc_source_data), .dst_data(cdc_destination_data)
);

always @(posedge loop_clk)
    if (!reset_n) cdc_pulse_count <= 0;
    else if (cdc_gain_changed) cdc_pulse_count <= cdc_pulse_count + 1;

task same_bus_write;
    input [15:0] address;
    input [31:0] data;
    begin
        @(negedge bus_clk); same_address = address; same_wdata = data; same_write = 1'b1;
        @(negedge bus_clk); same_write = 1'b0;
    end
endtask

task cdc_bus_write;
    input [15:0] address;
    input [31:0] data;
    begin
        @(negedge bus_clk); cdc_address = address; cdc_wdata = data; cdc_write = 1'b1;
        @(negedge bus_clk); cdc_write = 1'b0;
    end
endtask

task check;
    input condition;
    input [255:0] message;
    begin
        if (!condition) begin
            $display("FAIL: %0s", message);
            $finish;
        end
    end
endtask

initial begin
    amplitude = 0; frequency_error = 0; phase_error = 0; loop_output = 0;
    locked = 0; rail_positive = 0; rail_negative = 0; frequency_bad = 0; phase_bad = 0;
    same_write = 0; same_address = 0; same_wdata = 0; same_legacy_changed = 0;
    cdc_write = 0; cdc_address = 0; cdc_wdata = 0; cdc_legacy_changed = 0;
    cdc_data_toggle = 0; cdc_source_data = 0; cdc_pulse_count = 0;
    #23;
    @(negedge stats_clk); amplitude=10; frequency_error=-1; phase_error=-5; loop_output=-9; locked=1; reset_n=1'b1;
    @(negedge stats_clk); amplitude=20; frequency_error=2; phase_error=6; loop_output=10; locked=1;
    @(negedge stats_clk); amplitude=30; frequency_error=-3; phase_error=-7; loop_output=-11; locked=0; rail_positive=1; frequency_bad=1;
    @(negedge stats_clk); amplitude=40; frequency_error=4; phase_error=8; loop_output=12; locked=1; rail_positive=0; phase_bad=1;
    @(negedge stats_clk);
    check(snapshot_seq == 1, "statistics sequence");
    check(sample_count == 4 && amplitude_sum == 100, "statistics count and amplitude sum");
    check(amplitude_min == 10 && amplitude_max == 40, "amplitude extrema");
    check(frequency_abs_sum == 10 && frequency_abs_max == 4, "frequency statistics");
    check(phase_abs_sum == 26 && phase_abs_max == 8, "phase statistics");
    check($signed(output_min) == -11 && $signed(output_max) == 12, "output extrema");
    check(locked_samples == 3 && pos_samples == 1, "status sample counts");
    check(loss_events == 1 && pos_events == 1, "event counts");

    same_bus_write(16'h0061, 7); same_bus_write(16'h0062, 11);
    same_bus_write(16'h0063, 12); same_bus_write(16'h0064, 13);
    same_bus_write(16'h0065, 14); same_bus_write(16'h0066, 15);
    same_bus_write(16'h0067, 1);
    check(same_applied_seq == 1 && same_loop_kp == 11 && same_loop_dcoef == 15,
          "same-clock atomic apply");
    same_bus_write(16'h0067, 1);
    check(same_errors == 1 && same_status[2], "same-clock duplicate rejection");
    @(negedge bus_clk); same_legacy_changed=1; @(negedge bus_clk); same_legacy_changed=0;
    check(same_loop_kp == 101 && !same_status[1], "same-clock legacy fallback");

    cdc_bus_write(16'h0061, 9); cdc_bus_write(16'h0062, 21);
    cdc_bus_write(16'h0063, 22); cdc_bus_write(16'h0064, 23);
    cdc_bus_write(16'h0065, 24); cdc_bus_write(16'h0066, 25);
    cdc_bus_write(16'h0067, 5);
    cdc_bus_write(16'h0067, 6);
    repeat(12) @(posedge loop_clk);
    repeat(8) @(posedge bus_clk);
    check(cdc_applied_seq == 5 && cdc_loop_kp == 21 && cdc_loop_dcoef == 25,
          "CDC atomic apply and acknowledgement");
    check(cdc_pulse_count == 1, "CDC request applied exactly once");
    check(cdc_errors == 1 && cdc_status[2], "CDC busy rejection");
    @(negedge bus_clk); cdc_legacy_changed=1; @(negedge bus_clk); cdc_legacy_changed=0;
    repeat(5) @(posedge loop_clk);
    check(cdc_loop_kp == 201, "CDC legacy fallback");

    for (phase_index = 0; phase_index < 8; phase_index = phase_index + 1) begin
        #(phase_index + 1);
        cdc_bus_write(16'h0061, phase_index);
        cdc_bus_write(16'h0062, 1000 + phase_index);
        cdc_bus_write(16'h0067, 10 + phase_index);
        repeat(8) @(posedge loop_clk);
        repeat(6) @(posedge bus_clk);
        check(cdc_applied_seq == (10 + phase_index), "random-phase CDC sequence");
        check(cdc_loop_kp == (1000 + phase_index), "random-phase CDC bundled data");
    end
    check(cdc_pulse_count == 10, "CDC commits and legacy update counted once each");

    @(negedge loop_clk); cdc_source_data=32'h12345678; cdc_data_toggle=~cdc_data_toggle;
    repeat(5) @(posedge bus_clk);
    check(cdc_destination_data == 32'h12345678, "bundled snapshot CDC");

    $display("PASS: adaptive stage 3 RTL self-check");
    $finish;
end

endmodule
