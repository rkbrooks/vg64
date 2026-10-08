# VG64 cart

A second screen for the C64 w/ VGA compatible timings.


## See (https://www.hack.net/vg64)

## This archive contains the following filetypes:


* .STL files, 3D printer files for the cartridge enclosure.

* .JED, Jedec bitstreams for programming the CPLD

* .O,  C64 executable object files. Place on real or emulated disk and run.

* .BIN,  Image data for demo files.

* .V, Verilog files for the CPLD.  Use Xilinx ISE

* .UCF, Constraint files for pin-mapping, again for Xilinx ISE

* .ASM,  C64 assembly code for various demonstrations of the frame buffer - they require the image data to be in the same directory.

* .ZIP, Gerbers for PCB production. 4 layer board.  Known good for JLCPCB.

* .PNG, Schematic as a bitmap

## prod_25mhz.v (2026 CPLD update)

A reworked CPLD build. It needs one hardware change: replace the 100 MHz oscillator with a **25.175 MHz** one (3.3 V, 2.5 x 2.0 mm, same pads).

* prod_25mhz_xc95144xl-5.jed / prod_25mhz_xc95144xl-10.jed for either speed grade; pins in main_rd.ucf (main.ucf plus the cart's BA on p24).
* Frame buffer lines are now **128 bytes**: pixel (x, y) is at y*128 + x/8 (x/4 in colour mode), and bytes 80..127 of each line are free. The demos are updated; software written for 80-byte lines shows a sheared picture.
* Reading $DE03 returns the byte at the current address.
* Crosshair sprite: $DE04 = X (centre x = 4*X), $DE05 = Y (centre y = 2*Y + 10); Y = 250 hides it.
* $DE00 bit 1 picks the bank shown, from the next frame (double buffering); bit 0 still picks the bank written.
* Fixes: stray SRAM writes, a missed or repeated write after back-to-back register stores, the picture's one-byte horizontal offset, and a write pulse shorter than the SRAM's minimum.

The header of prod_25mhz.v has the details. hrtest.o is still the old 80-byte build, because its picture (polb.mono) isn't in the repo; mc1test.o, mc2test.o and mc3test.o are rebuilt for 128-byte lines.



7-Jun-2021
r.brooks / ryan@hack.net
