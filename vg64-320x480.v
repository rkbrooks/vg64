`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////////////////////////

//
// This is a rewrite of the register based r/w mapped graphics
//

//  token LSB = 0 first 64k bank of video memory, LSB = 1 second 64k bank of video memory
//			? MSB Screen on? TBD
// MSB 							LSB
// 7    6    5   4   3   2   1   0
//
// 0 = bank 
// 7 = screen on/off  (1 = ON) (NYI)
// 6 = 640/320 horz res (0 = 640)

module main(

	input  clk100,			// onboard clock osc
	 
	 // video connector
	 
	output  hs,           // horizontal sync
	output  vs,           // vertical sync
	output  r,
	output  g,
	output  b,
	 
	 // c64 cart port
	 
	 	// control signals

	    input  	rst,           // reset from c64
	    input  	i_64clk,			// 6510 ph 2 clock
	    input  	i_64rw,
	    input  	i_dotclk,		// VIC dot clock
	    output  o_game,			// PLA configuration hints 
	    output  o_exrom,		// 	active low
	    input  	i_ba,			// VIC Bus Available
	    output  o_dma,			// DMA request (active low) [1]

    	// busses

	    input  [15:0] 	i_64addr,	// We only listen (for now)
	    input  [7:0] 	i_64data,

    //  external sram

    	// signals

	    output  s_ce,		// 
	    output  s_ce2,		//
	    output  s_oe,		// 
	    output  s_we,		// [0] = write


	    // busses

	    inout  [7:0] 	s_d,		//connection to 
	    output  [16:0] 	o_saddr		//128k of video sram

    );

// Main

reg [2:0] divider;
reg [9:0] h_pos;
reg [9:0] v_pos;
reg active;
reg o_h;
reg o_v;
reg o_r;
reg o_g;
reg o_b;
reg [2:0] framebitpos;  // (bit position at beam 0->7, with overflow)

reg [16:0] saddr;	// this is the current sram read position (pointer) - 17 bits
reg [16:0] readaddr;

assign o_saddr = saddr;	// address bus to sram
reg [7:0] bytebuf;	// currently displayed byte buffer

//CPLD registers available to the C64.
//The are R/W if in Io1 or Io2 space, otherwise Write only, with shadow writes to system.

parameter tokenAddr = 16'hDE00;
reg [7:0] token;
parameter lsbAddr = tokenAddr+1;
parameter msbAddr = lsbAddr+1;
parameter operandAddr = msbAddr+1;

reg [15:0] addr;
reg [7:0] operand;


reg wip;		// The C64 domain will cause this to be set so we can execute a write at high speed.
reg wipip;		// the fast clock domain write in progress-in progress

// sram controls

reg ce, ce2, oe, we;

assign s_ce = ce;
assign s_ce2 = 1'b1;  //let's keep this selected
assign s_oe = oe;
assign s_we = we;		// we're also going to say that we\ is the data direction register for our inout buffer.

assign clk25=divider[1];	// used for vga pixel clock
assign clk50=divider[0];	// 2x pixel clock

reg [7:0] dataToSRAM;			// these are the bidirectional reg/wire to the sram
reg [7:0] dataFromSRAM;
reg [7:0] intData;

// tristate async portion

assign s_d = (~s_ce & s_oe) ? intData : 8'hZZ; 

// others

reg visible;          // active high


assign hs=o_h;
assign vs=o_v;

assign r=o_r && visible;
assign g=o_g && visible;
assign b=o_b && visible;

/////
// 100MHz clock domain / 10nS, or 4.5 SRAM cycles (round to 5 = 3 bit state machine)
/////

always @(negedge clk100) begin

	if(rst==1'b1) begin
		divider <= divider+1;			// this generates all local clks

		intData <= dataToSRAM;			// tri-state data bus logic
  		dataFromSRAM <= s_d;
	end

	if(rst==1'b0) begin
		divider <= 0;		// not needed- but is nice for simulation
		
		dataFromSRAM <= 0;
		intData <= 0;
	end

end

/////
// Logic clocked by c64 
/////

always @(negedge i_64clk) begin  // gated by 6502 PHI2 clock - Is this really PHASE 2? I had to switch to negedge!

	// reset from 64, so cpld registers reset

	if(rst==1'b0) begin

		token <= 8'b0;
		operand <= 8'b0;
		addr <= 16'b0;
		wip <= 1'b1;		// write in progress (no)

	end
	
	// writing to cpld registers 

	if(rst == 1'b1 && i_64rw == 1'b0) begin

		if(i_64addr == tokenAddr) token <= i_64data;	 // token 

		if(i_64addr == lsbAddr) addr[7:0] <= i_64data;	// little endian

		if(i_64addr == msbAddr) addr[15:8] <= i_64data;	

		if(i_64addr == operandAddr) begin // this commences the write, with the operand data

			operand <= i_64data;	
			wip <= 1'b0;		// active low   -- writing to this address is what starts da sram write.

		end

		if(wip == 1'b0) wip <= 1'b1;   // we're going to assume there are enough pixel clocks (25MHz)
										// to catch this during a 1MHz 6502 cycle.  Safe bet?
	end  // end of non-reset logic clocked by c64


end

// End of c64 bus timing domain


////
// VGA pixel clock-based logic
////

always @(negedge clk25) begin		

	if(rst==1'b0) begin 

		h_pos<=0;
		v_pos<=0;
		o_h<= 1;
		o_v<= 1;
		visible <= 0;
		ce <= 1'b1;
		oe <= 1'b1;
		we <= 1'b1;
		framebitpos <= 0;   	// lets go from Msbit to Lsbit: 0-------7
		readaddr <= 0;

		wipip <= 1'b1;				//  no write in progress in progess :-)

	end
	
	if(rst==1'b1) begin 
		
		// raster

		if(h_pos == 799) begin

			h_pos<=0;
			v_pos<=v_pos+1;

		end else h_pos<=h_pos+1; // change

		if(v_pos == 525) begin // reached end of screen, set framebuffer pointer back to zero
			readaddr <= 0;
			v_pos <=0;  
		end 

	

		// sync - changed this from ranges to simple sets

		if(h_pos == 16 ) o_h<=0;
		if(h_pos == 113) o_h<=1; 
		if(v_pos == 490) o_v<=0;
		if(v_pos == 493) o_v<=1;

		// Main pixel barfing and sram writing machine

		// Visible logic

		if(h_pos > 158 && v_pos < 480) visible <= 1'b1;	// when visible is low, we are blanking
			else visible <= 1'b0;



		// we're always going to increment the pixel bit position, even if we're off screen.
		// this allows writes during any period of the frame. 
		
		framebitpos <= framebitpos + 1;     // LSbit -> MSbit  (can't leave this inside visible - NO WRITES)


		
		if(wip == 1'b0) wipip <= 1'b0;			// A 6502 write has happened and we have <1uS to complete
												// hmm.. once the write starts, it could bail out, so I
												// need to add a second wip-ip flag.


		case(framebitpos)	// I unrolled these in a refactor, first nybble
							// is a (potential) write, second a read.

			3'b000: begin


					o_r<=bytebuf[0];
					o_g<=bytebuf[0];
					o_b<=bytebuf[0];


				if(wipip == 1'b0) begin

					oe <= 1'b1;
					ce <= 1'b0;
					dataToSRAM <= operand;	
					saddr[15:0] <= addr[15:0];
					saddr[16] <= token[0];	// video ram bank 
				end

			end

			3'b001: begin

				o_r<=bytebuf[1];
				o_g<=bytebuf[1];
				o_b<=bytebuf[1];

				if(wipip == 1'b0)  we <= 1'b0;

			end

			3'b010: begin

				o_r<=bytebuf[2];
				o_g<=bytebuf[2];
				o_b<=bytebuf[2];

				if(wipip == 1'b0) begin
					we <= 1'b1;
					ce <= 1'b1;
					wipip <= 1'b1;		// we're done with our queued write
				end

			end

			3'b011: begin

				o_r<=bytebuf[3];
				o_g<=bytebuf[3];
				o_b<=bytebuf[3];

			end

			3'b100: begin

				o_r<=bytebuf[4];
				o_g<=bytebuf[4];
				o_b<=bytebuf[4];

				saddr <= readaddr;

				oe <= 1'b0;
				ce <= 1'b0;
				we <= 1'b1;
			end

			3'b101: begin

				o_r<=bytebuf[5];
				o_g<=bytebuf[5];
				o_b<=bytebuf[5];

			end

			3'b110: begin	

				o_r<=bytebuf[6];
				o_g<=bytebuf[6];
				o_b<=bytebuf[6];

			end

			3'b111: begin

				o_r<=bytebuf[7];
				o_g<=bytebuf[7];
				o_b<=bytebuf[7];

				if(visible == 1'b1) bytebuf <= dataFromSRAM;	// Load data from sram
				if(visible == 1'b1) readaddr <= readaddr + 1;


			end

		endcase 

	end

end

endmodule


