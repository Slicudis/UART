module uart_receiver #(
    parameter CLK_FREQ = 100000000, //Internal clock frequency
    parameter BAUD_RATE = 9600, //UART target baud rate
    parameter BADDRWIDTH = 6, //Receiver FIFO size exponent
    parameter SAMPLE_EXP = 3 //Per-bit sample exponent
)(
    input  wire       i_clk,
    input  wire       i_clk_en,
    input  wire       i_sync_rst,

    output wire       o_data_available,
    output wire [7:0] o_data,
    input  wire       i_read_req,

    input  wire       i_uart_rx
);

    localparam BIT_CLKDIVWIDTH = $clog2(CLK_FREQ/BAUD_RATE);
    localparam [BIT_CLKDIVWIDTH-1:0] BIT_CLKDIVTHRESHOLD = (BIT_CLKDIVWIDTH)'(CLK_FREQ/BAUD_RATE)-1;
    localparam SAMPLES = 2**SAMPLE_EXP;
    localparam SAMPLE_CLKDIVWIDTH = $clog2((CLK_FREQ/(BAUD_RATE*SAMPLES)));
    localparam [SAMPLE_CLKDIVWIDTH-1:0] SAMPLE_CLKDIVTHRESHOLD = (SAMPLE_CLKDIVWIDTH)'((CLK_FREQ/(BAUD_RATE*SAMPLES)))-1;
    
    
    //RX CDC

    reg rx_buffer = 1;
    generate
        //4 CDC buffers because why not
        reg cdc_rx_buffer0 = 1'b1;
        reg cdc_rx_buffer1 = 1'b1;
        reg cdc_rx_buffer2 = 1'b1;
        always_ff @(posedge i_clk) begin
            if(i_clk_en) begin
                cdc_rx_buffer0 <= i_uart_rx;
                cdc_rx_buffer1 <= cdc_rx_buffer0;
                cdc_rx_buffer2 <= cdc_rx_buffer1;
                rx_buffer <= cdc_rx_buffer2;
            end
        end
    endgenerate

    //Negative edge detector

    wire rx_negedge = rx_prev && !rx_buffer;
    generate
        reg rx_prev;
        always_ff @(posedge i_clk) begin
            if(i_sync_rst) begin
                rx_prev <= 1; 
            end else if(i_clk_en) begin
                rx_prev <= rx_buffer;
            end
        end
    endgenerate
    
    //RX logic
    typedef enum logic [1:0] {
        IDLE, //Wait for an RX negative edge (start bit)
        START_BIT, //Check if the start bit was a start bit or a just glitch
        RECEIVING, //Get the serial data
        COOLDOWN //Wait for 'half' of a cycle
    } state_t;

    reg [7:0] data_reg;
    reg [2:0] data_reg_ptr;

    reg [BIT_CLKDIVWIDTH-1:0] bit_clk_div_cntr;
    reg [SAMPLE_CLKDIVWIDTH-1:0] sample_clk_div_cntr;
    reg [SAMPLE_EXP-1:0] bit_sample_cntr;
    reg [1:0] state = IDLE;
    reg data_ready_notif; //Is set to 1 for a single clock cycle after all the data is received

    wire bit_clk_div_cntr_threshold_hit = (bit_clk_div_cntr == BIT_CLKDIVTHRESHOLD);
    wire sample_clk_div_cntr_threshold_hit = (sample_clk_div_cntr == SAMPLE_CLKDIVTHRESHOLD);

    always_ff @(posedge i_clk) begin
        if(i_sync_rst) begin
            state <= IDLE;
            bit_clk_div_cntr <= 0;
            sample_clk_div_cntr <= 0;
            data_reg_ptr <= 0;
            bit_sample_cntr <= 0;
            data_ready_notif <= 0;
        end else if(i_clk_en) begin
            case(state)
                IDLE: begin
                    if(rx_negedge) state <= START_BIT;
                    bit_clk_div_cntr <= 0;
                    sample_clk_div_cntr <= 0;
                    data_reg_ptr <= 0;
                    bit_sample_cntr <= 0;
                    data_ready_notif <= 0;
                    end
                START_BIT: begin

                    //Counters
                    sample_clk_div_cntr <= sample_clk_div_cntr_threshold_hit ? 0 : (sample_clk_div_cntr + 1);
                    bit_clk_div_cntr <= bit_clk_div_cntr_threshold_hit ? 0 : (bit_clk_div_cntr + 1);

                    //Start bit verification
                    if(rx_buffer && sample_clk_div_cntr_threshold_hit) begin
                        if(bit_sample_cntr != SAMPLES-1) bit_sample_cntr <= bit_sample_cntr + 1;
                    end
                    if(bit_clk_div_cntr_threshold_hit) begin
                        if(bit_sample_cntr < (SAMPLES/2)) state <= RECEIVING; //It's actually a start bit
                        else state <= IDLE; //False alarm: it was just a signal glitch
                    end
                    end
                RECEIVING: begin

                    //Counters
                    sample_clk_div_cntr <= sample_clk_div_cntr_threshold_hit ? 0 : (sample_clk_div_cntr + 1);
                    bit_clk_div_cntr <= bit_clk_div_cntr_threshold_hit ? 0 : (bit_clk_div_cntr + 1);

                    //Sampling
                    if(bit_clk_div_cntr_threshold_hit) begin
                        bit_sample_cntr <= 0;
                    end else if(rx_buffer && sample_clk_div_cntr_threshold_hit) begin
                        if(bit_sample_cntr != SAMPLES-1) bit_sample_cntr <= bit_sample_cntr + 1;
                    end

                    if(bit_clk_div_cntr_threshold_hit) begin
                        if(bit_sample_cntr < (SAMPLES/2)) data_reg[data_reg_ptr] <= 1'b0;
                        else data_reg[data_reg_ptr] <= 1'b1;
                        data_reg_ptr <= data_reg_ptr + 1;
                        if(data_reg_ptr == 3'h7) begin
                            state <= COOLDOWN;
                            data_ready_notif <= 1;
                        end
                    end
                    end
                COOLDOWN: begin
                    data_ready_notif <= 0;
                    bit_clk_div_cntr <= bit_clk_div_cntr_threshold_hit ? 0 : (bit_clk_div_cntr + 1);
                    if(bit_clk_div_cntr == BIT_CLKDIVTHRESHOLD/2) state <= IDLE;
                end
                default: /* */;
            endcase
        end
    end

    //FIFO logic

    reg [BADDRWIDTH-1:0] fifo_head_ptr;
    reg [BADDRWIDTH-1:0] fifo_tail_ptr;
    reg [7:0]            fifo_buffer;

    //If size > 512 bytes, use BRAMs.
    generate
        if(BADDRWIDTH < 9) begin
            (*ramstyle = "logic"*)
            reg [7:0] fifo [2**BADDRWIDTH-1:0];
            always_ff @(posedge i_clk) begin
                if(i_clk_en) begin
                    fifo_buffer <= fifo[fifo_head_ptr];
                    if(data_ready_notif) begin
                        fifo[fifo_tail_ptr] <= data_reg;
                    end
                end
            end
        end else begin
            (*ramstyle = "m9k"*)
            reg [7:0] fifo [2**BADDRWIDTH-1:0];
            always_ff @(posedge i_clk) begin
                if(i_clk_en) begin
                    fifo_buffer <= fifo[fifo_head_ptr];
                    if(data_ready_notif) begin
                        fifo[fifo_tail_ptr] <= data_reg;
                    end
                end
            end
        end
    endgenerate

    always_ff @(posedge i_clk) begin
        if(i_sync_rst) begin
            fifo_head_ptr <= 0;
        end else if(i_clk_en && i_read_req && (fifo_head_ptr != fifo_tail_ptr)) begin
            fifo_head_ptr <= fifo_head_ptr + 1;
        end
    end

    always_ff @(posedge i_clk) begin
        if(i_sync_rst) begin
            fifo_tail_ptr <= 0;
        end else if(i_clk_en && data_ready_notif) begin
            fifo_tail_ptr <= fifo_tail_ptr + 1;
        end
    end
    
    assign o_data_available = (fifo_head_ptr != fifo_tail_ptr);
    assign o_data = fifo_buffer;

    //TODO: Make example timing diagram

endmodule : uart_receiver
