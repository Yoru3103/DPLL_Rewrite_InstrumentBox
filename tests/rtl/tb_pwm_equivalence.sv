`timescale 1ns/1ps

// Compare the actual production module with the preserved pre-retiming RTL.
// No enable port exists: rstn is synchronous, cfg is captured every clock,
// while v/b update only at the original sixteen-PWM-period boundary.
module pwm_trace_checker #(parameter [7:0] FULL = 8'd156, parameter bit MODEL_DEVICE_INIT = 0)(
    input logic clk, rstn,
    input logic [23:0] cfg
);
    wire actual_pwm, actual_sync, expected_pwm, expected_sync;
    integer known_checks = 0;
    logic reset_hold;
    red_pitaya_pwm #(.FULL(FULL)) dut (
        .clk(clk), .rstn(rstn), .cfg(cfg), .pwm_o(actual_pwm), .pwm_s(actual_sync));
    red_pitaya_pwm_reference #(.FULL(FULL)) reference_dut (
        .clk(clk), .rstn(rstn), .cfg(cfg), .pwm_o(expected_pwm), .pwm_s(expected_sync));

    // Separate device-init fixture: leave the golden source untouched and model
    // the original Vivado INIT=0 flop values through a one-time force/release.
    // New comparator INIT values come directly from the production declaration.
    generate if (MODEL_DEVICE_INIT) begin : device_initialization
        initial begin
            force reference_dut.bcnt=0; force reference_dut.b=0;
            force reference_dut.vcnt=0; force reference_dut.vcnt_r=0;
            force reference_dut.v=0; force reference_dut.v_r=0;
            force reference_dut.cfg_reg=0; force reference_dut.pwm_o_reg=0;
            force dut.bcnt=0; force dut.b=0; force dut.vcnt=0;
            force dut.v=0; force dut.cfg_reg=0; force dut.pwm_o_reg=0;
            #1;
            release reference_dut.bcnt; release reference_dut.b;
            release reference_dut.vcnt; release reference_dut.vcnt_r;
            release reference_dut.v; release reference_dut.v_r;
            release reference_dut.cfg_reg; release reference_dut.pwm_o_reg;
            release dut.bcnt; release dut.b; release dut.vcnt;
            release dut.v; release dut.cfg_reg; release dut.pwm_o_reg;
        end
    end endgenerate

    always @(posedge clk) begin
        #1;
        if (MODEL_DEVICE_INIT && expected_pwm === 1'bx)
            $fatal(1, "Device initialization fixture left reference output unknown");
        if (actual_sync !== expected_sync)
            $fatal(1, "PWM sync mismatch FULL=%0d time=%0t", FULL, $time);
        if (dut.vcnt !== reference_dut.vcnt || dut.bcnt !== reference_dut.bcnt ||
            dut.v !== reference_dut.v || dut.b !== reference_dut.b ||
            dut.cfg_reg !== reference_dut.cfg_reg)
            $fatal(1, "PWM configuration/counter state changed FULL=%0d time=%0t", FULL, $time);
        // The legacy v/b and comparison pipeline have no reset initializer.
        // They have no defined reference output until configuration is latched.
        // All defined outputs, including first clock after every reset, compare.
        if (expected_pwm !== 1'bx) begin
            known_checks = known_checks + 1;
            if (actual_pwm !== expected_pwm)
                $fatal(1, "PWM output mismatch FULL=%0d time=%0t expected=%b actual=%b", FULL, $time, expected_pwm, actual_pwm);
        end
        if (!rstn && actual_pwm !== 1'b0)
            $fatal(1, "PWM synchronous reset not zero FULL=%0d", FULL);
    end

    always @(negedge rstn) begin
        reset_hold = expected_pwm;
        #1;
        if (reset_hold !== 1'bx && actual_pwm !== reset_hold)
            $fatal(1, "PWM acquired an asynchronous reset FULL=%0d time=%0t", FULL, $time);
    end
endmodule

module tb_pwm_equivalence;
    logic clk = 0;
    always #4 clk = ~clk;
    logic rstn = 0;
    logic [23:0] cfg = 0;
    logic natural_done = 0, exhaustive_done = 0;
    logic ex_rstn = 0;
    logic [7:0] ex_counter = 0, ex_value = 0;
    logic [15:0] ex_fraction = 0;
    wire ex_actual, ex_expected, ex_sync_actual, ex_sync_expected;
    integer exhaustive_checks = 0;
    integer distinct_pairs = 0;
    integer observed_index;
    bit [131071:0] observed_pairs = 0;
    integer value_index, pattern_index, cycle_index;
    integer counter_index, input_index, fraction_index;
    logic [31:0] random_state = 32'hcb250917;
    logic [7:0] values [0:8];
    logic [15:0] patterns [0:4];

    pwm_trace_checker #(.FULL(0)) check_0(clk, rstn, cfg);
    pwm_trace_checker #(.FULL(1)) check_1(clk, rstn, cfg);
    pwm_trace_checker #(.FULL(15)) check_15(clk, rstn, cfg);
    pwm_trace_checker #(.FULL(16)) check_16(clk, rstn, cfg);
    pwm_trace_checker #(.FULL(156)) check_156(clk, rstn, cfg);
    pwm_trace_checker #(.FULL(255)) check_255(clk, rstn, cfg);
    pwm_trace_checker #(.FULL(156), .MODEL_DEVICE_INIT(1)) check_device_init(clk, rstn, cfg);

    red_pitaya_pwm ex_dut(.clk(clk), .rstn(ex_rstn), .cfg(24'b0), .pwm_o(ex_actual), .pwm_s(ex_sync_actual));
    red_pitaya_pwm_reference ex_reference(.clk(clk), .rstn(ex_rstn), .cfg(24'b0), .pwm_o(ex_expected), .pwm_s(ex_sync_expected));

    always @(posedge clk) begin
        #1;
        if (ex_rstn && !exhaustive_done) begin
            if (ex_dut.vcnt !== ex_counter || ex_dut.v !== ex_value || ex_dut.b !== ex_fraction)
                $fatal(1, "Exhaustive stimulus did not reach actual DUT registers");
            observed_index = {ex_fraction[0], ex_value, ex_counter};
            if (!observed_pairs[observed_index]) begin
                observed_pairs[observed_index] = 1;
                distinct_pairs = distinct_pairs + 1;
            end
        end
        if (ex_expected !== 1'bx) begin
            if (ex_actual !== ex_expected)
                $fatal(1, "Exhaustive pipeline mismatch counter=%0d value=%0d fraction=%b time=%0t", ex_counter, ex_value, ex_fraction[0], $time);
            exhaustive_checks = exhaustive_checks + 1;
        end
    end

    initial begin
        values[0]=0; values[1]=1; values[2]=15; values[3]=16;
        values[4]=155; values[5]=156; values[6]=157; values[7]=254; values[8]=255;
        patterns[0]=16'h0000; patterns[1]=16'h0001; patterns[2]=16'h8000;
        patterns[3]=16'haaaa; patterns[4]=16'hffff;
        repeat (4) @(negedge clk);
        rstn=1;
        // Each stable cfg spans a complete 16*FULL update cycle even at FULL=0
        // (8-bit wrap) or FULL=255, plus the unmodified output pipeline.
        for (value_index=0; value_index<9; value_index=value_index+1) begin
            for (pattern_index=0; pattern_index<5; pattern_index=pattern_index+1) begin
                cfg={values[value_index],patterns[pattern_index]};
                repeat (4200) @(negedge clk);
            end
        end
        // Per-clock config changes and resets at unrelated PWM/bcnt boundaries.
        for (cycle_index=0; cycle_index<20000; cycle_index=cycle_index+1) begin
            random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
            cfg=random_state[23:0];
            rstn=(cycle_index%509)>2;
            @(negedge clk);
        end
        rstn=1;
        repeat (5000) @(negedge clk);
        if (check_156.known_checks<200000 || check_255.known_checks<200000)
            $fatal(1, "Insufficient defined-output natural trace coverage");
        natural_done=1;
    end

    initial begin
        // Drive all possible eight-bit counter/value pairs through the actual
        // DUT pipeline, including both decimal-bit inputs and 255+1 wrap.
        // Counter injection isolates comparison coverage; natural checkers above
        // independently cover cfg latching, counters, reset and pwm_s.
        force ex_dut.vcnt=ex_counter;
        force ex_reference.vcnt=ex_counter;
        force ex_dut.v=ex_value;
        force ex_reference.v=ex_value;
        force ex_dut.b=ex_fraction;
        force ex_reference.b=ex_fraction;
        repeat (4) @(negedge clk);
        ex_rstn=1;
        for (fraction_index=0; fraction_index<2; fraction_index=fraction_index+1) begin
            ex_fraction=fraction_index;
            for (input_index=0; input_index<256; input_index=input_index+1) begin
                ex_value=input_index;
                for (counter_index=0; counter_index<256; counter_index=counter_index+1) begin
                    ex_counter=counter_index;
                    @(negedge clk);
                end
            end
        end
        repeat (3) @(negedge clk);
        if (exhaustive_checks<131072)
            $fatal(1, "Insufficient exhaustive comparison checks: %0d", exhaustive_checks);
        if (distinct_pairs != 131072)
            $fatal(1, "Incomplete exhaustive input coverage: %0d", distinct_pairs);
        exhaustive_done=1;
    end

    initial begin
        wait(natural_done && exhaustive_done);
        $display("PASS: PWM cycle equivalence; 131072 comparison input pairs, FULL=0/1/15/16/156/255, cfg boundaries, synchronous reset and device INIT0");
        $finish;
    end
    initial begin
        #3000000;
        $fatal(1, "PWM equivalence watchdog expired");
    end
endmodule
