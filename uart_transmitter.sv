module uart_transmitter #(
    parameter CLK_FREQ = 100000000,
    parameter BAUD_RATE = 9600
)(
    input  wire       i_clk,
    input  wire       i_clk_en,
    input  wire       i_sync_rst,
 
    output wire       o_send_busy,
    input  wire       i_send_req,
    input  wire [7:0] i_send_data,

    output wire       o_uart_tx

);

    localparam CLKDIVWIDTH = $clog2(CLK_FREQ/BAUD_RATE);
    localparam [CLKDIVWIDTH-1:0] CLKDIVTHRESHOLD = (CLKDIVWIDTH)'(CLK_FREQ/BAUD_RATE)-1;

    //* === TX logic ===

    // Example timing diagram: (baud rate = 2 * clock speed, 4-bit data)
    //
    // clk:              __--__--__--__--__--__--__--__--__--__--__--__--__--__--__--__
    // i_send_req:       __----XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX________
    // tx_state:         IDLE=||================SENDING=======================||=IDLE==
    // tx_clk_div_cntr:  XXXXXX000011110000111100001111000011110000111100001111XXXXXXXX
    // tx_shift_reg[0]:  ------________|==D1==||==D2==||==D3==||==D4==|--------XXXXXXXX
    // o_tx:             ----------________|==D1==||==D2==||==D3==||==D4==|------------
    // 

    typedef enum bit {
        IDLE,
        SENDING
    } state_t;

    reg [CLKDIVWIDTH-1:0] clk_div_cntr;
    reg                   state = IDLE;
    reg [10:0]            shift_reg; //{2 stop bits, data, start bit}
    reg                   output_buffer = 1'b1;

    //TX state machine
    always_ff @(posedge i_clk) begin
        if(i_sync_rst) begin
            state <= IDLE;
            clk_div_cntr <= 0;
        end else if(i_clk_en) begin
            case(state)
                IDLE: begin
                    if(i_send_req) state <= SENDING;
                    clk_div_cntr <= 0;
                    end    
                SENDING: begin
                    if(shift_reg[9:1] == 0) state <= IDLE;
                    clk_div_cntr <= (clk_div_cntr == CLKDIVTHRESHOLD) ? 0 : (clk_div_cntr + 1);
                end
                default: /**/;
            endcase
        end
    end

    //TX data shift register
    always_ff @(posedge i_clk) begin
        if(i_clk_en) begin
            if((state == IDLE) && i_send_req) shift_reg <= {2'b11, i_send_data, 1'b0};
            else if(clk_div_cntr == CLKDIVTHRESHOLD) shift_reg <= shift_reg >> 1;
        end
    end

    //TX buffer
    always_ff @(posedge i_clk) begin
        if(i_sync_rst) begin
            output_buffer <= 1'b1;
        end else if(i_clk_en) begin
            output_buffer <= (state == IDLE) || shift_reg[0];
        end
    end

    //TX pin assignments
    assign o_send_busy = (state == SENDING);
    assign o_uart_tx = output_buffer;

endmodule : uart_transmitter
