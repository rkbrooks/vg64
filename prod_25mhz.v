`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// VG64 - CPLD for the C64 VGA cart: XC95144XL-5 or -10 TQ100, pins in main_rd.ucf
// (main.ucf plus the cart's BA on p24, as schematic.png shows it).
//
// Clock: a 25.175 MHz oscillator on p22 (GCK1) in place of the 100 MHz one
// (25.000 MHz works too). The counters run 800 x 525 clocks: 640x480 at 60 Hz.
//
// Frame buffer: the 128 KB SRAM is two 64 KB banks. A frame is 480 lines of
// 128 bytes, so pixel (x, y) is at y*128 + x/8 in mono (640 wide) and at
// y*128 + x/4 in colour (320 wide). Bytes 80..127 of each line are not shown
// and are free memory. (prod.v used 80-byte lines: y*80 + x/8.)
//
// Registers, latched at the end of PHI2:
//   $DE00  token: bit 0 = bank the C64 writes and reads; bit 1 = bank shown,
//          taken at the next frame start so a flip never tears; bit 6 = 320
//          colour mode (0 = 640 mono)
//   $DE01  address, low byte
//   $DE02  address, high byte
//   $DE03  write: store the byte at the address
//          read:  the byte at the address. The CPLD re-reads it every 320 ns
//          in the slots writes leave free, so it is always ready and a write
//          reads back at once. D0-D7 are driven only while PHI2 is high, R/W
//          is high, BA is high and the address is $DE03.
//   $DE04  sprite X, in 4-pixel steps: the crosshair's centre is at screen
//          x = 4*X, so X = x/4 (x = 0..636 -> X = 0..159)
//   $DE05  sprite Y, in 2-line steps: the crosshair's centre is at screen
//          y = 2*Y + 10, so Y = (y - 10)/2 (y = 10..479 -> Y = 0..234).
//          Y = 250 parks it in vertical blanking (the value after reset).
// The sprite is a 16x16 box whose top-left corner is screen (4*X - 8,
// 2*Y + 2); inside it a crosshair with a gap in the middle is XORed onto the
// bitmap, so it shows on black and on white. It can run off the left, right
// and bottom edges, but not the top: its centre can't go above line 10.
//
// Timing: h_pos is numbered so the fetch runs in byte columns 0..79, which
// makes the read address just {bank, v_pos, h_pos[9:3]}. The screen is
// h_pos 9..648 and hsync is low for 665..761: the same porches and sync widths
// as prod.v. WE is low for two pixel clocks (80 ns; prod.v gave it one, 40 ns,
// under the AS6C1008-55's 45 ns minimum).
//
// Fixes from prod.v:
//   1. A write request that arrived between slot 0 and slot 1 pulled WE low
//      at the read address with nothing driving s_d. WE now only goes low in
//      a write slot that actually started.
//   2. wip stayed low until the next C64 *write* cycle, so storing to $DE00-
//      $DE02 straight after $DE03 could repeat the old byte at the new
//      address. wip now lasts one PHI2 cycle.
//   3. Each line showed the previous line's last byte (plus one stale pixel)
//      at the left edge and lost its own last byte off the right. The fetch
//      now runs a byte column ahead of the screen.
//
// Registers dropped from prod.v: framebitpos (always h_pos[2:0]), dataFromSRAM
// (bytebuf samples s_d directly), dataToSRAM and intData (s_d is driven from
// operand, which lives in the s_d pin macrocells), readaddr (the address comes
// from the counters) and the 100 MHz divider.
//
// Fitted with ISE 14.7, default cpldfit settings: 126 of 144 macrocells on the
// XC95144XL-5 (pixel clock paths 11.0 ns) and on the -10 (20.5 ns), against
// the 40 ns pixel clock.
//////////////////////////////////////////////////////////////////////////////////

module main(

	input  clk100,			// onboard clock osc: 25.175 MHz in this version (name kept for main_rd.ucf)

	 // video connector

	output  hs,           // horizontal sync
	output  vs,           // vertical sync
	output  r,
	output  g,
	output  b,

	 // c64 cart port

	    input  	rst,           // reset from c64
	    input  	i_64clk,			// 6510 ph 2 clock
	    input  	i_64rw,
	    input  	i_dotclk,		// VIC dot clock
	    output  o_game,			// PLA configuration hints
	    output  o_exrom,		// 	active low
	    input  	i_ba,			// VIC Bus Available
	    output  o_dma,			// DMA request (active low) [1]

	    input  [15:0] 	i_64addr,
	    inout  [7:0] 	i_64data,

    //  external sram

	    output  s_ce,
	    output  s_ce2,
	    output  s_oe,
	    output  s_we,

	    inout  [7:0] 	s_d,
	    output  [16:0] 	o_saddr		//128k of video sram

    );

parameter tokenAddr = 16'hDE00;
parameter lsbAddr = tokenAddr+1;
parameter msbAddr = lsbAddr+1;
parameter operandAddr = msbAddr+1;
parameter sprXAddr = operandAddr+1;
parameter sprYAddr = sprXAddr+1;

// $DE00-$DE07 decoded once and kept as a node, so each register only needs
// A2-A0 instead of all 16 address lines (the fitter ran out of block inputs)
(* KEEP = "TRUE" *) wire io_sel;
assign io_sel = (i_64addr[15:3] == 13'h1BC0);	// $DE00 >> 3

reg [9:0] h_pos;
reg [9:0] v_pos;
reg o_h, o_v;
reg o_r, o_g, o_b;
reg visible;				// the pixel registers hold an on-screen pixel
reg fetch;					// in slot 7: this byte column is fetched
reg [16:0] saddr;
reg [7:0] bytebuf;

reg [7:0] token;			// only bits 0, 1 and 6 are used; synthesis drops the rest
reg disp_bank;				// token[1], taken at the frame start
reg [15:0] addr;
reg [7:0] operand;			// also the sram write data: it sits in the s_d pin macrocells
reg [7:0] rdata;			// the byte at {token[0], addr}: it sits in the D0-D7 pin macrocells
reg wip;					// C64 domain: low for one PHI2 cycle after a write to operandAddr
reg wipip;					// pixel domain: a write is queued

reg ce, oe, we;

// sprite
reg [7:0] spr_x, spr_y;		// C64 domain
reg ymatch;					// pixel domain: the beam is in the sprite's 2-line row
reg hrun, vrun;				// the beam is inside the 16x16 box
reg [1:0] ux;				// box column = {ux, h_pos[1:0]}
reg [2:0] uy;				// box row    = {uy, v_pos[0]}
reg spr;					// sprite pixel, in step with o_r/o_g/o_b

wire clk25 = clk100;
wire hires = token[6];		// 0 = 640 mono, 1 = 320 colour
wire [2:0] framebitpos = h_pos[2:0];
(* KEEP = "TRUE" *) wire h_end;		// shared compares, kept as nodes
(* KEEP = "TRUE" *) wire v_end;
assign h_end = (h_pos == 799);
assign v_end = (v_pos == 525);

assign o_saddr = saddr;
assign s_ce = ce;
assign s_ce2 = 1'b1;
assign s_oe = oe;
assign s_we = we;
wire wslot = ~ce & oe;		// a write slot has started (slots 0-3)
assign s_d = wslot ? operand : 8'hzz;
assign i_64data = (i_64clk && i_64rw && i_ba && io_sel && i_64addr[2:0] == 3'd3) ? rdata : 8'hzz;

assign hs = o_h;
assign vs = o_v;
assign r = (o_r ^ spr) && visible;
assign g = (o_g ^ spr) && visible;
assign b = (o_b ^ spr) && visible;

/////
// C64 bus (registers latched at the end of PHI2)
/////

always @(negedge i_64clk) begin

	if(rst == 1'b0) begin

		token <= 8'b0;
		operand <= 8'b0;
		addr <= 16'b0;
		wip <= 1'b1;
		spr_x <= 8'd0;
		spr_y <= 8'd250;		// parked in vertical blanking

	end else begin

		wip <= 1'b1;		// one PHI2 cycle, whatever the next cycle is

		if(i_64rw == 1'b0) begin

			if(io_sel && i_64addr[2:0] == 3'd0) token <= i_64data;
			if(io_sel && i_64addr[2:0] == 3'd1) addr[7:0] <= i_64data;
			if(io_sel && i_64addr[2:0] == 3'd2) addr[15:8] <= i_64data;
			if(io_sel && i_64addr[2:0] == 3'd4) spr_x <= i_64data;
			if(io_sel && i_64addr[2:0] == 3'd5) spr_y <= i_64data;
			if(io_sel && i_64addr[2:0] == 3'd3) begin		// after the release, so INC $DE03 writes twice
				operand <= i_64data;
				wip <= 1'b0;
			end

		end
	end
end

/////
// 25MHz pixel clock
/////

// next pixel for each gun, before blanking
reg pix_r, pix_g, pix_b;

always @* begin
	if(hires == 1'b0) begin
		pix_r = bytebuf[framebitpos];
		pix_g = pix_r;
		pix_b = pix_r;
	end else begin
		pix_r = framebitpos[2] ? bytebuf[5] : bytebuf[4];
		pix_g = bytebuf[framebitpos[2:1]];
		pix_b = framebitpos[2] ? bytebuf[7] : bytebuf[6];
	end
end

// The crosshair in the 16x16 box, centred between rows/columns 7 and 8:
// 2-pixel arms with a 4x4 gap in the middle. Any 16x16 pattern works here.
(* KEEP = "TRUE" *) wire xm;	// the beam is in the sprite's first 4-pixel column
assign xm = (h_pos[9:2] == spr_x);
wire [3:0] sx = {xm ? 2'd0 : ux, h_pos[1:0]};
wire [3:0] sy = {uy, v_pos[0]};
wire arm_v = (sx == 7 || sx == 8) && (sy < 6 || sy > 9);
wire arm_h = (sy == 7 || sy == 8) && (sx < 6 || sx > 9);

// The byte fetched in byte column c = h_pos[9:3] (address in slot 5, loaded
// in slot 7) is shifted out in column c+1 and seen a clock later, because the
// pixel outputs are registered: columns 0..79 are fetched, 1..80 shifted out,
// and the screen is h_pos 9..648. (prod.v used one window for both, so it
// fetched a column late.)

always @(negedge clk25) begin

	if(rst == 1'b0) begin

		h_pos <= 0;
		v_pos <= 0;
		o_h <= 1;
		o_v <= 1;
		visible <= 0;
		fetch <= 0;
		disp_bank <= 0;
		hrun <= 0;
		vrun <= 0;
		spr <= 0;
		ce <= 1'b1;
		oe <= 1'b1;
		we <= 1'b1;
		wipip <= 1'b1;

	end else begin

		// raster

		if(h_end) begin
			h_pos <= 0;
			v_pos <= v_pos + 1'b1;
		end else h_pos <= h_pos + 1'b1;

		if(v_end) begin
			v_pos <= 0;
			disp_bank <= token[1];
		end

		if(h_pos == 664) o_h <= 0;		// 16 clocks after the screen, 97 wide, 47 before it
		if(h_pos == 761) o_h <= 1;
		if(v_pos == 490) o_v <= 0;
		if(v_pos == 493) o_v <= 1;

		visible <= (v_pos < 480) && (h_pos > 7) && (h_pos < 648);	// h_pos+1 in 9..648
		fetch <= (v_pos < 480) && (h_pos > 5) && (h_pos < 639);		// h_pos+1 in 7..639
		o_r <= pix_r;
		o_g <= pix_g;
		o_b <= pix_b;

		// sprite. The box starts on the matching 4-pixel column (h_pos =
		// 4*X, column 0 from xm) and runs three more (hrun, ux = 1..3); it
		// starts on the line pair after the matching one (v_pos = 2*Y + 2),
		// because ymatch is registered and the row starts at the line end.

		ymatch <= (v_pos[9:1] == {1'b0, spr_y});
		spr <= (xm || hrun) && vrun && (arm_v || arm_h);

		if(h_pos[1:0] == 2'd3) begin
			if(xm) begin
				hrun <= 1'b1;
				ux <= 2'd1;
			end else if(hrun) begin
				if(ux == 2'd3) hrun <= 1'b0;
				else ux <= ux + 1'b1;
			end
		end

		if(h_end && v_pos[0] == 1'b1) begin
			if(ymatch) begin
				vrun <= 1'b1;
				uy <= 3'd0;
			end else if(vrun) begin
				uy <= uy + 1'b1;
				if(uy == 3'd7) vrun <= 1'b0;
			end
		end

		// sram: slots 0-3 write (if queued) or read for the C64, 5-7 read for the screen

		if(wip == 1'b0) wipip <= 1'b0;

		case(framebitpos)

			3'd0: begin
					saddr <= {token[0], addr};
					if(wipip == 1'b0) begin
						oe <= 1'b1;
						ce <= 1'b0;
					end
				end

			3'd1: if(wslot) we <= 1'b0;

			3'd2: rdata <= s_d;		// the sram's byte, or in a write slot the byte being written

			3'd3: if(wslot) begin		// WE was low for slots 1 and 2: 80 ns
					we <= 1'b1;
					ce <= 1'b1;
					wipip <= 1'b1;
				end

			3'd5: begin
					saddr <= {disp_bank, v_pos[8:0], h_pos[9:3]};	// fetch columns 0..79 = bytes 0..79
					oe <= 1'b0;
					ce <= 1'b0;
					we <= 1'b1;
				end

			3'd7: if(fetch) begin
					bytebuf <= s_d;
				end

			default: ;

		endcase
	end
end

endmodule
