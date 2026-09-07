`timescale 1ns / 1ps
module tb_adaptive_metrics;
reg clk = 0, bus_clk = 0, reset_n = 0;
always #80 clk = ~clk;
always #4 bus_clk = ~bus_clk;
reg [15:0] amplitude = 0;
reg signed [13:0] frequency_error = 0;
reg signed [31:0] phase_error = 0;
reg locked = 1, frequency_bad = 0, phase_bad = 0;
reg rail_positive = 0, rail_negative = 0;
wire [31:0] seq, n, bad_count, rail_count, phase_sat_count;
wire toggle;
wire signed [63:0] freq_sum, phase_sum;
wire [63:0] freq_square, legacy_freq_abs;
wire signed [31:0] first_phase, last_phase;
wire [1023:0] source_bundle, dest_bundle;
assign source_bundle = {672'd0, freq_sum, freq_square, phase_sum,
                       first_phase, last_phase, bad_count, rail_count, phase_sat_count};

adaptive_statistics #(.WINDOW_LOG2(2)) dut (
    .clk(clk), .reset_n(reset_n), .amplitude(amplitude),
    .frequency_error(frequency_error), .phase_error(phase_error), .loop_output(32'sd0),
    .locked(locked), .rail_positive(rail_positive), .rail_negative(rail_negative),
    .frequency_bad(frequency_bad), .phase_bad(phase_bad),
    .snapshot_seq(seq), .snapshot_toggle(toggle), .sample_count(n),
    .frequency_abs_sum(legacy_freq_abs),
    .frequency_signed_sum(freq_sum), .frequency_square_sum(freq_square),
    .phase_signed_sum(phase_sum), .phase_first(first_phase), .phase_last(last_phase),
    .residual_bad_sample_count(bad_count), .rail_sample_count(rail_count),
    .phase_saturated_sample_count(phase_sat_count)
);
adaptive_snapshot_cdc #(.DATA_WIDTH(1024)) cdc (
    .dst_clk(bus_clk), .dst_reset_n(reset_n), .src_toggle(toggle),
    .src_data(source_bundle), .dst_data(dest_bundle)
);

// Exercise actual measurement window size and the largest frequency square sum.
wire [31:0] full_seq, full_n;
wire signed [63:0] full_freq_sum, full_phase_sum;
wire [63:0] full_square;
wire [31:0] full_sat;
adaptive_statistics #(.WINDOW_LOG2(17)) full_window (
    .clk(bus_clk), .reset_n(reset_n), .amplitude(16'd1),
    .frequency_error(14'sh2000), .phase_error(32'sh80000000), .loop_output(32'sd0),
    .locked(1'b1), .rail_positive(1'b0), .rail_negative(1'b0),
    .frequency_bad(1'b0), .phase_bad(1'b0),
    .snapshot_seq(full_seq), .sample_count(full_n),
    .frequency_signed_sum(full_freq_sum), .frequency_square_sum(full_square),
    .phase_signed_sum(full_phase_sum), .phase_saturated_sample_count(full_sat)
);

// Minimum supported window verifies first/last selection with only two samples.
wire [31:0] short_seq;
wire signed [31:0] short_first, short_last;
adaptive_statistics #(.WINDOW_LOG2(1)) short_window (
    .clk(clk), .reset_n(reset_n), .amplitude(16'd0),
    .frequency_error(frequency_error), .phase_error(phase_error), .loop_output(32'sd0),
    .locked(locked), .rail_positive(1'b0), .rail_negative(1'b0),
    .frequency_bad(1'b0), .phase_bad(1'b0), .snapshot_seq(short_seq),
    .phase_first(short_first), .phase_last(short_last)
);

integer win, sample, seed = 32'h5a012345;
integer ref_bad, ref_rail, ref_sat;
reg signed [63:0] ref_freq, ref_phase, f64, p64;
reg [63:0] ref_square, ref_abs;
reg signed [31:0] ref_first, ref_short_first;
reg [1023:0] frozen;

task check;
    input good;
    input [511:0] message;
    begin
        if (good !== 1'b1) $fatal(1, "FAIL: %0s", message);
    end
endtask

initial begin
    repeat (3) @(negedge clk);
    reset_n = 1;
    for (win=0; win<64; win=win+1) begin
        ref_freq=0; ref_phase=0; ref_square=0; ref_abs=0;
        ref_bad=0; ref_rail=0; ref_sat=0;
        for (sample=0; sample<4; sample=sample+1) begin
            if (win != 0 || sample != 0) @(negedge clk);
            frequency_error=$random(seed); phase_error=$random(seed);
            frequency_bad=$random(seed); phase_bad=$random(seed);
            rail_positive=$random(seed); rail_negative=$random(seed);
            if (win==0) begin
                frequency_error=(sample==0) ? -8192 : ((sample==3) ? 8191 : 0);
                phase_error=(sample==0) ? 32'sh80000000 : ((sample==3) ? 32'sh7fffffff : 0);
                frequency_bad=1; phase_bad=1; rail_positive=1; rail_negative=1;
            end
            if (win==1) begin
                frequency_error=0; phase_error=0;
                frequency_bad=0; phase_bad=0; rail_positive=0; rail_negative=0;
            end
            if (sample==0) ref_first=phase_error;
            if (sample==0 || sample==2) ref_short_first=phase_error;
            f64=frequency_error; p64=phase_error;
            ref_freq=ref_freq+f64; ref_square=ref_square+f64*f64;
            ref_phase=ref_phase+p64;
            ref_abs=ref_abs+((f64==-8192) ? 8191 : ((f64<0) ? -f64 : f64));
            ref_bad=ref_bad+(frequency_bad | phase_bad);
            ref_rail=ref_rail+(rail_positive | rail_negative);
            ref_sat=ref_sat+((phase_error==32'sh80000000)||(phase_error==32'sh7fffffff));
            @(posedge clk); #1;
            if (sample==1 || sample==3)
                check(short_first==ref_short_first && short_last==phase_error, "two-sample first/last");
            if (sample<3) begin
                check(seq==win, "snapshot remains frozen before boundary");
                if (win>0) check(source_bundle==frozen, "all extended fields remain frozen");
            end else begin
                check(seq==win+1 && n==4, "window sequence and count");
                check(freq_sum==ref_freq && freq_square==ref_square, "exact signed frequency moments");
                check(legacy_freq_abs==ref_abs, "legacy absolute-value compatibility");
                check(phase_sum==ref_phase && first_phase==ref_first && last_phase==phase_error, "phase sum and endpoints");
                check(bad_count==ref_bad && rail_count==ref_rail, "OR counts never double-count");
                check(phase_sat_count==ref_sat, "phase saturation samples");
                frozen=source_bundle;
                repeat (6) @(posedge bus_clk); #1;
                check(dest_bundle==frozen, "1024-bit snapshot CDC including extensions");
            end
        end
    end
    wait(full_seq==1); #1;
    check(full_n==131072 && full_freq_sum==-64'sd1073741824, "real measurement window signed sum");
    check(full_square==64'd8796093022208, "square-sum high word");
    check(full_phase_sum==-64'sd281474976710656 && full_sat==131072, "full window phase limits");
    @(negedge clk); reset_n=0;
    @(posedge clk); #1;
    check(seq==0 && freq_square==0 && phase_sum==0 && bad_count==0, "reset clears extension");
    $display("PASS: adaptive metrics RTL self-check");
    $finish;
end
initial begin
    #2000000;
    $fatal(1, "FAIL: adaptive metrics simulation timeout");
end
endmodule
