`default_nettype none


module ChipInterface
  (input  logic         CLOCK_100, // 100 MHZ Clock
   input  logic [15:0]  SW,
   input  logic [3:0]   BTN,
   output logic [7:0]   D0_SEG, D1_SEG,
   output logic [3:0]   D0_AN, D1_AN);
   
  logic reset;
  logic [6:0] HEX7, HEX6, HEX5, HEX4, HEX3, HEX2, HEX1, HEX0;
  logic [3:0] BCD7, BCD6, BCD5, BCD4, BCD3, BCD2, BCD1, BCD0;
  logic [31:0] answerQ, clockCount;
  logic [7:0] blank, dpoints;

  assign {BCD7, BCD6, BCD5, BCD4, BCD3, BCD2, BCD1, BCD0} = 
    (SW[0]) ? clockCount : answerQ;

  assign blank = 8'b0000_0000;
  assign dpoints = 8'b0000_0000;

  SevenSegmentDisplay segment(.*);

  SSegDisplayDriver display(.clk(CLOCK_100), .reset(reset),
    .HEX7(HEX7), .HEX6(HEX6), .HEX5(HEX5), .HEX4(HEX4),
    .HEX3(HEX3), .HEX2(HEX2), .HEX1(HEX1), .HEX0(HEX0),
    .dpoints(dpoints), .D1_AN(D0_AN), .D2_AN(D1_AN),
    .D1_SEG(D0_SEG), .D2_SEG(D1_SEG)
  );

  Synchronizer sync_BTN(.async(BTN[0]), .clock(CLOCK_100), .sync(reset));
  compute compute_inst(.clk(CLOCK_100), .reset(reset), .answerQ(answerQ), .clockCount(clockCount));
endmodule : ChipInterface

module compute
  (input logic clk, reset,
   output logic [31:0] answerQ, clockCount);
  
  //romA signals 
  logic [13:0] addraA[16], addrbA[16];
  logic [7:0] doutaA[16], doutbA[16];

  //romB signals
  logic [6:0] addraB;
  logic [7:0] doutaB;

  //compute signals 
  logic [15:0] product[32];
  logic [15:0] accum[32];
  logic [31:0] sum32[32], sum32Q[32], sum16[16], sum16Q[16], sum8[8], sum8Q[8],
   sum4[4], sum4Q[4], sum2[2], sum2Q[2], sum, sumQ, answer, cSumVal;
  logic isLastAddr;
  logic [1:0] row;
  logic [6:0] col;
  logic [2:0] countAdd;
  logic computing, enAccum, enAdd, cDone, done, doneQ, adding, lastAdd;

  fsm fsm(.clk(clk), .reset(reset), .isLastAddr(isLastAddr),
   .computing(computing), .done(done), .adding(adding), .lastAdd(lastAdd),
   .enAccum(enAccum));

  sumC sC(.clk(clk), .reset(reset), .sum(cSumVal), .done(cDone));

  genvar i;
  generate 
    for(i = 0; i < 16; i++) begin : matrixA
      romA_128x128 rA(.clka(clk), .addra(addraA[i]), .douta(doutaA[i]),
       .clkb(clk), .addrb(addrbA[i]), .doutb(doutbA[i]));
    end
  endgenerate

  romB_128x1 rB(.clka(clk), .addra(addraB), .douta(doutaB),
   .clkb(clk), .addrb('d0), .doutb());

  //assign matrix address 
  always_ff @(posedge clk) begin 
    if (reset) begin
      row <= 2'd0;
      col <= 7'd0;
      countAdd <= 3'd0;
    end else 
    if (computing)begin
      row <= row + 2'd1;              
      if (row == 2'd3) col <= col + 7'd1;
    end
    if (adding)begin 
      countAdd <= countAdd + 3'd1;
    end 
  end 

  always_ff @(posedge clk) begin
    if (reset) begin
      clockCount <= 32'd0;
      doneQ <= 1'b0;
    end else begin
      doneQ <= done;
      if (!doneQ) clockCount <= clockCount + 32'd1;
    end
  end

  assign enAdd = adding;
  assign isLastAddr = (row == 2'd3) && (col == 7'd127);
  assign lastAdd = (countAdd == 3'd4);

  generate
    for (genvar m = 0; m < 16; m++) begin : addr_gen
      assign addraA[m] = {row, 1'b0, m[3:0], col};
      assign addrbA[m] = {row, 1'b1, m[3:0], col};
    end
  endgenerate

  assign addraB = col; 
  
  //compute logic 
  generate
    for(i = 0; i < 16; i++) begin : m1
      multiplier_8816 mA(.A(doutaA[i]), .B(doutaB), .P(product[i]));
      multiplier_8816 mB(.A(doutbA[i]), .B(doutaB), .P(product[i+16]));
    end
  endgenerate

  //adder and registers level
  generate
    for(i = 0; i < 32; i++) begin : level1
      Register #(.WIDTH(16)) r1(.clock(clk), .en(1'b1), .clear(reset),
       .D(product[i]), .Q(accum[i]));
      Register #(.WIDTH(32)) r2(.clock(clk), .en(enAccum), .clear(reset),
       .D(sum32[i]), .Q(sum32Q[i]));
      assign sum32[i] = sum32Q[i] + accum[i];
    end
  endgenerate

  generate
    for(i = 0; i < 16; i++) begin : level2
      assign sum16[i] = sum32Q[i] + sum32Q[i+16];
      Register #(.WIDTH(32)) r3(.clock(clk), .en(enAdd), .clear(reset),
       .D(sum16[i]), .Q(sum16Q[i]));
    end
  endgenerate 

  generate
    for(i = 0; i < 8; i++) begin : level3
      assign sum8[i] = sum16Q[i] + sum16Q[i+8];
      Register #(.WIDTH(32)) r4(.clock(clk), .en(enAdd), .clear(reset),
       .D(sum8[i]), .Q(sum8Q[i]));
    end
  endgenerate 

  generate
    for(i = 0; i < 4; i++) begin : level4
      assign sum4[i] = sum8Q[i] + sum8Q[i+4];
      Register #(.WIDTH(32)) r5(.clock(clk), .en(enAdd), .clear(reset),
       .D(sum4[i]), .Q(sum4Q[i]));
    end
  endgenerate 
  
  assign sum2[0] = sum4Q[0] + sum4Q[2];
  assign sum2[1] = sum4Q[1] + sum4Q[3];
  Register #(.WIDTH(32)) r6(.clock(clk), .en(enAdd), .clear(reset),
   .D(sum2[0]), .Q(sum2Q[0]));
  Register #(.WIDTH(32)) r7(.clock(clk), .en(enAdd), .clear(reset),
   .D(sum2[1]), .Q(sum2Q[1]));

  assign sum = sum2Q[0] + sum2Q[1];
  Register #(.WIDTH(32)) r8(.clock(clk), .en(enAdd), .clear(reset),
   .D(sum), .Q(sumQ));
  assign answer = sumQ + cSumVal;
  Register #(.WIDTH(32)) r9(.clock(clk), .en(done&&cDone), .clear(reset),
   .D(answer), .Q(answerQ));

endmodule : compute

module sumC 
(input  logic clk, reset,
   output logic [31:0] sum,
   output logic done);

  logic [6:0] addraC, addrbC;
  logic [15:0] doutaC, doutbC;
  logic [5:0] idx;
  logic running, accEn;

  romC_128x1 rC (.clka(clk), .addra(addraC), .douta(doutaC),
                 .clkb(clk), .addrb(addrbC), .doutb(doutbC));

  assign addraC = {1'b0, idx};
  assign addrbC = {1'b1, idx};

  always_ff @(posedge clk) begin
    if (reset) begin
      idx <= 6'd0;
      running <= 1'b1;
      accEn <= 1'b0;
      sum <= 32'd0;
      done <= 1'b0;
    end
    else begin
      accEn <= running;         

      if (running) begin
        idx <= idx + 6'd1;         
        if (idx == 6'd63) running <= 1'b0;
      end

      if (accEn) sum <= sum + doutaC + doutbC;

      if (!running && !accEn) done <= 1'b1;
    end
  end
endmodule 

module fsm
  (input logic clk, reset, isLastAddr, lastAdd, 
   output logic computing, adding, done, enAccum);

   enum logic [2:0] {START, BUFFER1, BUFFER2, MULTI ,WAIT1, WAIT2, ADD, DONE} state, next_state;

  always_ff @(posedge clk) begin
    if (reset)
      state <= START;
    else
      state <= next_state;
  end

  always_comb begin
    computing = 1'b0;
    done = 1'b0;
    adding = 1'b0;
    enAccum = 1'b0;
    case (state)
      START: next_state = BUFFER1;
      BUFFER1: begin 
        computing = 1'b1;
        next_state = BUFFER2;
      end
      BUFFER2: begin 
        computing = 1'b1;
        next_state = MULTI;
      end
      MULTI: begin
        enAccum = 1'b1;
        computing = 1'b1;
        if (isLastAddr) next_state = WAIT1;
        else next_state = MULTI;
      end
      WAIT1: begin 
        enAccum = 1'b1;
        next_state = WAIT2;
      end  
      WAIT2: begin
        enAccum = 1'b1;
        next_state = ADD;
      end
      ADD: begin 
        adding = 1'b1;
        if (lastAdd) next_state = DONE;
        else next_state = ADD;
      end 
      DONE: begin 
        done = 1'b1;
        next_state = DONE;
      end 
    endcase
  end
endmodule : fsm
