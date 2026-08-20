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


module Status_Delay_Show
    #(parameter N_BITS_COUNTER = 20) 
    (
    input wire clk,
    input wire lock_on,
    input wire above_threshold,
    output wire delay_show
    );
    reg [N_BITS_COUNTER:0]inhibit_counter = 0;
    reg delay_show_internal;

always @(posedge clk) begin    
    if(above_threshold == 1'b1)
    begin
        inhibit_counter <= 0;
    end else begin
        if(inhibit_counter[N_BITS_COUNTER] == 1'b0)
        begin
            inhibit_counter <= inhibit_counter + 1'b1;
        end
    end
    delay_show_internal <= ~inhibit_counter[N_BITS_COUNTER];
end   
assign  delay_show = delay_show_internal & lock_on;   
endmodule
