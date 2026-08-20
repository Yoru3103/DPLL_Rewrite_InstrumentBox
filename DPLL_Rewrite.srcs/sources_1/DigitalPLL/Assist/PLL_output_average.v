//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2020/09/10 16:12:58
// Design Name: 
// Module Name: PLL_VCO_MUL_DIV
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module PLL_output_average
    #(parameter N_BITS_COUNTER = 16) 
    (
    input wire clk,
    input wire lock_on,
    input wire[31:0] pll_pid_output_value,
    output wire[31:0] pll_average_value
    );
    reg [N_BITS_COUNTER-1:0]inhibit_counter = 1'b1;
    reg [N_BITS_COUNTER+32-1:0]pll_out_value_add = 0;
    wire [N_BITS_COUNTER+32-1:0]pll_in_value_expand;
    reg [31:0]pll_average_value_internal;
    
assign pll_in_value_expand = {{N_BITS_COUNTER{pll_pid_output_value[31]}},pll_pid_output_value[31:0]};

always @(posedge clk) begin
    if(lock_on == 1'b0)
    begin
        inhibit_counter <= 1'b1;
    end else begin
        inhibit_counter <= inhibit_counter + 1'b1;     
    end
    
    //if(inhibit_counter == (~(1'b0<<(N_BITS_COUNTER-1))))
    if(inhibit_counter == 0)
    begin
        pll_out_value_add <= pll_in_value_expand;
        pll_average_value_internal <= pll_out_value_add[N_BITS_COUNTER+32-1:N_BITS_COUNTER];
    end else begin
        pll_out_value_add <= pll_out_value_add + pll_in_value_expand;
    end
end   
assign  pll_average_value = pll_average_value_internal;   
endmodule
