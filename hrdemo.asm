; ML demo for VG64
; r. brooks  -  ryan@hack.net
; New Version 1/19/2020 - for reg scheme

; Assumes token register at $DE00, EXROM high, and NO banking at $8000

; 128-byte line stride (CPLD prod_25mhz.v)
;	The frame buffer is now 480 lines of 128 bytes instead of 480 lines
;	of 80, so the CPLD can address it as {line, byte} without a counter.
;	Pixel (x, y) is at y*128 + x/8 in hires (640 wide, 8 pixels a byte)
;	and y*128 + x/4 in multicolor (320 wide, 4 pixels a byte). Only bytes
;	0..79 of each line are shown; bytes 80..127 are free memory, which
;	the C64 can write and (with this CPLD) read back through $DE03.
;	The pictures are still 80 bytes a line, so loadPic skips 48 bytes
;	after each line. These demos no longer suit the old 80-byte CPLD
;	(prod.v): a picture would come out sheared.

; Hires Demo and test code

	!to "hrtest.o", cbm

; BASIC stub to get a tokenized SYS command in.  Grabbed from 
;	https://harald.ist.org/howto/c64/acme-asm-template.html


*= $0801                        ; Load point $0801 (BASIC START)
_FSTART                         ; This binary must begin with the bytes
                                ; representing the BASIC program: 0 SYS2061
BASIC_program
!byte $0b,$08           ; $0801 Pointer to next line
!byte $00,$00           ; $0803 Line number (0)
!byte $9e               ; $0805 SYS
!byte 48+(entry_point/1000)%10  ; Decimal address of program entry point
!byte 48+(entry_point/100)%10
!byte 48+(entry_point/10)%10
!byte 48+(entry_point/1)%10
!byte $00               ; $080a End of BASIC line
!byte $00,$00           ; $080b End of BASIC program
entry_point     ;JMP boot       ; $080d First byte after the BASIC program


;; defines

chrout = $ffd2
chrin = $ffcf

autotoken = $80			;Hires mode, screen on

token = $de00			; vg64 registers
lsb = $de01
msb = $de02
operand = $de03
zp1 = $fd			; available zero page addrs
zp2 = $fe			; pointer to source

zpA = $fb			; framebuffer pointed in zp
zpB = $fc

;; program

!zone main

boot    cld
		lda  #23
		sta  $d018			; Switch to lower case
		lda  #<menu			; print menu
		sta  zp1
		lda  #>menu
		sta  zp2
		jsr	 stringout

.inp	jsr	 chrin
		cmp  #$43			; 'C'
		beq	 clearScreenJ
		cmp  #$46			; 'F'
		beq	fillScreenJ
		cmp  #$4c			; 'L'
		beq loadPicJ
		cmp #$56			; 'V'
		beq vertLineJ
		cmp #$58			; 'X'
		beq exitPrg	
		cmp #$45			; 'E'
		beq	evenFillJ
		cmp #$4f			; 'O'
		beq oddFillJ
		jmp .inp

exitPrg rts     ; Return to BASIC

clearScreenJ 	jsr clearScreen    ; these exist for "long branches"
				jmp boot
fillScreenJ	    jsr fillScreen
				jmp boot
loadPicJ        jsr loadPic
				jmp boot
vertLineJ		jsr vertLine
				jmp boot
evenFillJ		jsr evenFill
				jmp boot
oddFillJ        jsr oddFill
				jmp boot


!zone st

; Prints a string pointed to by zp1+zp2*256, null terminated

stringout 	ldy #$00
.loop		lda (zp1),y
			beq .send
			jsr	chrout
			iny
			beq	 .send		; safety to prevent strings >255 characters / endless printing from a bad pointer
			jmp  .loop
.send		rts

!zone lp

; This is where the magic happens  

loadPic	lda #<picstring	; print message
		sta zp1
		lda #>picstring
		sta zp2
		jsr stringout

		lda #autotoken
		sta token

		; setup loop

		lda #<bitmap  	; load pointer into zero page for 
		sta zp1			; source bitmap LSB
		lda #>bitmap
		sta zp2			; MSB

		lda #$00			; set to beginning of frame buffer
		sta lsb
		sta msb
		sta zpA
		sta zpB

.ol     ldx	#$00

.l2		lda (zp1,x)		; load bitmap byte into accumulator
		eor	#$ff  		; flip bits
		sta operand     ; store

		inc  zpA
		bne  .lab
		inc  zpB
.lab	lda  zpA		; 128-byte stride: after the 80th byte of a line,
		and  #$7f		; skip the 48 bytes the screen doesn't show
		cmp  #80
		bne  .laa
		lda  zpA
		clc
		adc  #48		; 80 + 48 = 128, the start of the next line
		sta  zpA
		bcc  .laa
		inc  zpB
.laa    lda  zpA
		sta  lsb
		lda  zpB
		sta  msb
		inc  zp1        ; inc source lsb
		bne  .l2a		; if we haven't reached zero, don't increment MSB    
		bne .laa  
		inc  zp2
.l2a	lda  zp2
		cmp  #1+>endOfBitmap
		beq  .l3
		jmp  .l2

.l3		lda #<estring	; print completion message
		sta zp1
		lda #>estring
		sta zp2
		jsr stringout
	
		rts 

!zone na

nonauto					; This routine increments and stores to the pointer hardware

		rts




!zone cs

clearScreen			; writes all 64 KB of the bank, so it covers the 128-byte
				; lines as before (and the unused bytes 80..127 of each)

		lda #<clearstring
		sta zp1
		lda #>clearstring
		sta zp2
		jsr stringout

		lda #autotoken
		sta token

		lda #$00
		sta	zpA
		sta	zpB



		ldx #$00
.l		lda zpA
		sta lsb
		lda zpB
		sta msb
		stx operand
		inc zpA
		bne .l
		inc zpB
		bne .l

.out		rts

!zone fs

fillScreen			; writes all 64 KB of the bank, so it covers the 128-byte
				; lines as before (and the unused bytes 80..127 of each)

		lda #<fillstring
		sta zp1
		lda #>fillstring
		sta zp2
		jsr stringout


		lda #$00
		sta	zpA
		sta	zpB



		ldx #$ff
.l		lda zpA
		sta lsb
		lda zpB
		sta msb
		stx operand
		inc zpA
		bne .l
		inc zpB
		bne .l

.out	rts

!zone ef

evenFill			; writes all 64 KB of the bank, so it covers the 128-byte
				; lines as before (and the unused bytes 80..127 of each)

		lda #<fillstring
		sta zp1
		lda #>fillstring
		sta zp2
		jsr stringout

		lda #autotoken
		sta token

		lda #$00
		sta	zpA
		sta	zpB



		ldx #170
.l		lda zpA
		sta lsb
		lda zpB
		sta msb
		stx operand
		inc zpA
		bne .l
		inc zpB
		bne .l

.out	rts

!zone of

oddFill			; writes all 64 KB of the bank, so it covers the 128-byte
				; lines as before (and the unused bytes 80..127 of each)

		lda #<fillstring
		sta zp1
		lda #>fillstring
		sta zp2
		jsr stringout


		lda #autotoken
		sta token

		lda #$00
		sta	zpA
		sta	zpB



		ldx #85
.l		lda zpA
		sta lsb
		lda zpB
		sta msb
		stx operand
		inc zpA
		bne .l
		inc zpB
		bne .l

.out	rts

!zone dl

vertLine

		lda #<linestring
		sta zp1
		lda #>linestring
		sta zp2
		jsr stringout


.out		rts

;; variable

currentBank   !byte  $40				; lower nybble is what we care about


;; Strings and binary attachment

menu  	!pet "HR: Press L to load pic, C to Clear, ",13,"F to Fill, V for vert line,",13,"E/O for even/odd fill, or X to exit:",13,13,0

linestring !pet 13,"Drawing vertical line.",13,0
clearstring !pet 13,"Clearing framebuffer.",13,0
fillstring !pet 13,"Filling framebuffer.",13,0
picstring !pet "Loading pic to video sram...",13,0

estring !pet "Completed.",13,0

bitmap	!binary "polb.mono"

endOfBitmap
