; ============================================================================
;  paint.asm -- a mouse-driven paint program in one 512-byte boot sector
;
;  Dmitry Brant, 2025+, feat. Claude Code.
;
;  Boots on any 386 or later PC and talks to nothing but the BIOS and the
;  keyboard controller:
;       int 10h / ah=00h al=13h   VGA 320x200x256, default palette
;       int 16h / ah=01h          has a key been pressed?
;       ports 60h / 64h           the 8042, and the PS/2 mouse behind it
;  Pixels go straight into the frame buffer at A000:0000.
;
;  The bottom twenty rows are the palette: sixteen swatches of the standard
;  EGA colours, with a strip above them showing the colour now in hand.  The
;  rest of the screen is canvas.
;
;  Controls:  left button    paint with the current colour
;             right button   rub out (paint with black)
;             click a swatch pick that colour up
;             any key        wipe the canvas clean
;
;  There is no mouse driver here and no interrupt handler either.  The 8042
;  is told to switch its auxiliary port on and the mouse is told to start
;  reporting; after that the three-byte packets are simply polled out of the
;  output buffer.  The BIOS keyboard interrupt still runs underneath and
;  keeps its own bytes out of our way.
;
;  The pointer is drawn by exclusive-or, so taking it off the screen is the
;  same code as putting it on and the picture underneath never needs saving.
;  Masking with 0Fh swaps every EGA colour for its opposite, which leaves the
;  arrow visible whatever it happens to be standing on.
;
;  Assemble:  nasm -f bin -o paint.bin paint.asm
;  Run:       qemu-system-i386 -fda paint.bin
;  On iron:   write paint.bin to the first sector of a USB stick / floppy
; ============================================================================

        bits    16
        org     0x7c00

CANVAS  equ     180             ; the drawing area is rows 0 .. CANVAS-1
SWATCHY equ     184             ; the row of colour swatches starts here
SWATCHW equ     20              ; 16 swatches of 20 pixels fill the width
NCOL    equ     16              ; the EGA sixteen, palette entries 0..15
BRUSH   equ     3               ; the brush lays down a BRUSH x BRUSH square
CURH    equ     10              ; rows in the arrow, one byte of bits each
YMAX    equ     200 - CURH      ; keeps the whole arrow on the screen
INVERT  equ     0x0f            ; xor mask: every colour becomes its opposite

; ---------------------------------------------------------------------------
start:
        xor     ax, ax
        mov     ds, ax
        mov     ss, ax
        mov     sp, ax                  ; stack grows down from the 64K mark
        cld
        mov     al, 0x13                ; ah is still zero
        int     0x10                    ; mode 13h, and the screen comes clear
        push    0xa000
        pop     es                      ; ES = frame buffer segment

; ------------------------------------------------------------ the colour bar
        mov     di, SWATCHY * 320
        mov     dl, 200 - SWATCHY       ; rows of swatches
.rows:
        xor     al, al                  ; every row starts again at black
        mov     bl, NCOL
.swatch:
        mov     cx, SWATCHW
        rep     stosb
        inc     ax                      ; al counts 0..15, ah stays zero
        dec     bl
        jnz     .swatch
        dec     dl
        jnz     .rows
        call    showink                 ; and the strip that shows the choice

; --------------------------------------------------------- wake the mouse up
        call    kbwait
        mov     al, 0xa8
        out     0x64, al                ; A8: enable the auxiliary port
        call    kbwait
        mov     al, 0xd4
        out     0x64, al                ; D4: the next byte is for the mouse
        call    kbwait
        mov     al, 0xf4
        out     0x60, al                ; F4: start reporting movement

        call    cursor                  ; lay the pointer on the picture

; ----------------------------------------------------------------- main loop
main:
        call    packet                  ; bl = buttons, bh = dx, al = dy
        mov     bp, bx                  ; keep the buttons out of harm's way
        call    cursor                  ; lift the pointer off the picture

        mov     esi, [curx]             ; where the pointer was, both words
        mov     [oldx], esi             ; at once, for the stroke to start at

        movsx   cx, bh                  ; x: the mouse counts rightwards, and
        add     cx, [curx]              ;    so does the screen
        mov     dx, 319
        call    clamp
        mov     [curx], cx

        movsx   cx, al                  ; y: the mouse counts upwards, so the
        neg     cx                      ;    sign has to be turned round
        add     cx, [cury]
        mov     dx, YMAX
        call    clamp
        mov     [cury], cx

        mov     ax, bp                  ; remember the buttons, and pick up
        and     ax, 3                   ; what they were doing last time
        xchg    al, [held]

        test    bp, 3                   ; either button down?
        jz      .done
        test    al, al                  ; down already: whatever this is, it
        jnz     .canvas                 ; is the middle of a stroke
        cmp     cx, SWATCHY             ; cx is still the new y
        jb      .canvas

; ---------------------------------------------------------- pick a colour up
        mov     ax, [curx]              ; a fresh press, and it landed on the
        mov     bl, SWATCHW             ; bar rather than on the canvas
        div     bl                      ; al = the swatch under the pointer
        mov     [ink], al
        call    showink
        jmp     .done

; --------------------------------------------------------------------- paint
.canvas:
        mov     al, [ink]
        test    bp, 2                   ; the right button rubs out instead
        jz      .stroke
        xor     al, al
.stroke:
        call    stroke
.done:
        call    cursor                  ; and put the pointer back
        jmp     main

; ---------------------------------------------------- hold cx inside 0 .. dx
clamp:
        test    cx, cx
        jns     .high
        xor     cx, cx
        ret
.high:
        cmp     cx, dx
        jbe     .ok
        mov     cx, dx
.ok:
        ret

; --------------------- fill the strip above the swatches with the chosen ink
showink:
        push    di
        mov     di, CANVAS * 320
        mov     cx, (SWATCHY - CANVAS) * 320
        mov     al, [ink]
        rep     stosb
        pop     di
        ret

; ---------------------------------------------------------------------------
;  Lay the brush down all the way from (oldx,oldy) to (curx,cury) in the
;  colour in al.  One packet can carry a jump of a hundred pixels, and a row
;  of separate blobs is no stroke at all, so the gap is walked out pixel by
;  pixel with the usual Bresenham error term.
stroke:
        mov     [pen], al
        mov     si, [oldx]              ; si, bx = the point we are walking
        mov     bx, [oldy]

        mov     cx, [curx]              ; cx = how far across, made positive,
        sub     cx, si                  ; and sx = which way that was
        mov     ax, 1
        jns     .xpos
        neg     cx
        neg     ax
.xpos:
        mov     [sx], ax

        mov     dx, [cury]              ; dx = how far down, likewise
        sub     dx, bx
        mov     ax, 1
        jns     .ypos
        neg     dx
        neg     ax
.ypos:
        mov     [sy], ax

        mov     bp, cx                  ; the error term starts at dx - dy
        sub     bp, dx
.step:
        call    blob
        cmp     si, [curx]              ; arrived?
        jne     .on
        cmp     bx, [cury]
        je      .end
.on:
        mov     ax, bp
        add     ax, ax                  ; ax = twice the error
        mov     di, dx
        neg     di
        cmp     ax, di                  ; over -dy: time for a step across
        jle     .down
        sub     bp, dx
        add     si, [sx]
.down:
        cmp     ax, cx                  ; under dx: time for a step down
        jge     .step
        add     bp, cx
        add     bx, [sy]
        jmp     .step
.end:
        ret

; ---------------------------------------------------------------------------
;  One square of paint with its top left corner at (si, bx).  A square that
;  would hang over the right edge or over the colour bar is dropped whole,
;  which costs two pixels at the edge of the canvas and saves the mess of
;  clipping one.  Every register is handed back untouched.
blob:
        pusha
        cmp     si, 320 - BRUSH
        ja      .out
        cmp     bx, CANVAS - BRUSH
        ja      .out
        mov     di, bx
        shl     di, 8
        shl     bx, 6
        add     di, bx                  ; di = y * 320
        add     di, si                  ;    + x
        mov     al, [pen]
        mov     dl, BRUSH
.row:
        mov     cx, BRUSH
        rep     stosb
        add     di, 320 - BRUSH
        dec     dl
        jnz     .row
.out:
        popa
        ret

; ---------------------------------------------------------------------------
;  Exclusive-or the arrow into the frame buffer at (curx, cury).  Drawing it
;  a second time takes it away again and leaves the picture underneath as it
;  was, so nothing has to be remembered.  Columns that would fall off the
;  right-hand edge are dropped; cury is clamped so the rows never can.
cursor:
        pusha
        mov     di, [cury]
        mov     cx, di
        shl     di, 8
        shl     cx, 6
        add     di, cx                  ; di = y * 320
        add     di, [curx]              ;    + x
        mov     si, arrow
        mov     bl, CURH
.row:
        mov     dx, [curx]              ; dx follows di across the screen
        lodsb                           ; al = the eight bits of this row
        mov     cx, 8
.col:
        shl     al, 1
        jnc     .next
        cmp     dx, 320
        jae     .next
        xor     byte [es:di], INVERT
.next:
        inc     di
        inc     dx
        loop    .col
        add     di, 320 - 8
        dec     bl
        jnz     .row
        popa
        ret

; ---------------------------------------------------------------------------
;  Fetch one three-byte packet.  Bit 3 of the first byte is always set and
;  the two overflow bits are all but always clear, which is enough to tell a
;  packet from the acknowledgement and self-test bytes the mouse sends while
;  it is starting up, and enough to find the beat again if one is ever lost.
packet:
        call    auxbyte
        mov     bl, al                  ; buttons, and the two sign bits
        and     al, 0xc8
        cmp     al, 0x08
        jne     packet                  ; not a first byte: keep looking
        call    auxbyte
        mov     bh, al                  ; movement across
        call    auxbyte                 ; movement up, left in al
        ret

; ---------------------------------------------------------------------------
;  Wait for a byte from the mouse.  Bit 0 of the status port says the output
;  buffer is full and bit 5 says the byte came from the auxiliary device; a
;  byte from the keyboard is left well alone for the BIOS to collect.  While
;  there is nothing else to do, watch for a keystroke and wipe the canvas on
;  one.  The pointer is on the screen at this point, so it comes off for the
;  wipe and goes back afterwards; that keeps the exclusive-or in step.
auxbyte:
        mov     ah, 1
        int     0x16
        jz      .poll
        xor     ah, ah
        int     0x16                    ; take the key out of the buffer
        call    cursor
        xor     di, di
        mov     cx, CANVAS * 320
        xor     al, al
        rep     stosb
        call    cursor
.poll:
        in      al, 0x64
        and     al, 0x21
        cmp     al, 0x21
        jne     auxbyte
        in      al, 0x60
        ret

; -------------------------- wait until the 8042 has room for another command
kbwait:
        in      al, 0x64
        test    al, 2
        jnz     kbwait
        ret

; ------------------------------------------------------------------ variables
curx    dw      160                     ; the pointer starts in the middle of
cury    dw      86                      ; the canvas; oldx and oldy follow so
oldx    dw      0                       ; that one 32-bit move copies the pair
oldy    dw      0
sx      dw      0                       ; which way the stroke is walking
sy      dw      0
ink     db      15                      ; white
pen     db      0                       ; the colour this stroke is laying
held    db      0                       ; the buttons as they were last packet

arrow:                                  ; the pointer, tip at the top left
        db      10000000b
        db      11000000b
        db      11100000b
        db      11110000b
        db      11111000b
        db      11111100b
        db      11111110b
        db      11111000b
        db      11011000b
        db      10001100b

        times   510 - ($ - $$) db 0
        dw      0xaa55
