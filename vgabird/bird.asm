; ============================================================================
;  bird.asm -- VGABird, a flappy bird game in one 512-byte boot sector
;
;  Dmitry Brant, 2025+, feat. Claude Code.
;
;  Boots on any 386 or later PC and talks to nothing but the BIOS and the
;  timer chip:
;       int 10h / ah=00h al=13h   VGA 320x200x256, default palette
;       int 10h / ah=02h, 0Eh     place the cursor, write the counts
;       int 15h / ah=86h          a pause after each crash
;       int 16h / ah=00h, 01h     read the keyboard, or just look at it
;       ports 40h / 43h           the 8253, told to tick 70 times a second
;  Pixels go into a buffer at 1000:0000 and are copied to A000:0000.
;
;  Controls:  space - flap
;
;  The pipes come in from the right with their gaps at random heights, and
;  keep on coming until the bird touches one of them or the ground.  The top
;  line of the screen counts the pipes passed on this flight (left) and the
;  most passed on any flight since the machine was switched on (right).
;  After a crash, space flies again.
;
;  Every frame is painted from scratch into the buffer and copied to the
;  screen in one go, so nothing flickers.  The copy leaves out the top eight
;  rows, which belong to the BIOS and the counts it writes there.  A frame
;  starts on each tick of the BIOS clock, which the timer now drives at
;  70 Hz instead of 18.2, so the game keeps the same pace on any machine
;  fast enough to draw a frame in a tick.
;
;  There is no collision geometry.  The sky is all one colour and anything
;  that is not sky is solid.  The bird is painted last, and if any pixel of
;  it lands on something other than sky, the flight is over.  That goes for
;  the very first frame too: the bird starts out sitting in the grass, so it
;  crashes straight away, and the game waits for space like after any crash.
;
;  The bird's height is 8.8 fixed point, with its row, counted down from the
;  top of the playfield rather than the screen, in the high byte.
;
;  Assemble:  nasm -f bin -o bird.bin bird.asm
;  Run:       qemu-system-i386 -drive file=bird.bin,format=raw
;  ...or write to a floppy disk or USB drive and boot on a real machine!
; ============================================================================

        bits    16
        org     0x7c00

BUFSEG  equ     0x1000          ; the back buffer, clear of us and the stack
TOP     equ     8               ; rows of status line above the playfield
GROUND  equ     184             ; the first row of the ground
GRASS   equ     4               ; rows of grass on top of it
PIPEW   equ     24              ; pipe width: six bands of shade, 4 pixels each
GAP     equ     48              ; rows of daylight between upper and lower pipe
NPIPE   equ     3               ; pipes in circulation
SPACING equ     120             ; pixels from one pipe to the next
MINTOP  equ     TOP + 16        ; the highest a gap may open
RANGE   equ     GROUND - 16 - GAP - MINTOP + 1  ; rows it may open on
BIRDX   equ     64              ; the bird's left edge; the bird never moves
BIRDH   equ     9               ; rows in the bird, 16 pixels to a row
STARTY  equ     80              ; the screen row every flight starts on
GRAV    equ     48              ; 8.8 rows per frame per frame, downward
FLAP    equ     -660            ; 8.8 rows per frame, upward: an 18-row hop

SKY     equ     0x4e            ; light blue
TURF    equ     0x2f            ; green
DIRT    equ     0x43            ; sand
TEXT    equ     15              ; white

TICKS   equ     0x46c           ; BIOS data area: the clock tick count
KBHEAD  equ     0x41a           ; BIOS data area: keyboard buffer head
KBTAIL  equ     0x41c           ;                 and tail

; ---------------------------------------------------------------------------
start:
        xor     ax, ax
        mov     ds, ax
        mov     ss, ax
        mov     sp, ax                  ; stack grows down from the 64K mark
        cld
        mov     al, 0x13                ; ah is still zero
        int     0x10
        push    BUFSEG
        pop     es                      ; ES = the back buffer, for good

        mov     al, 0x34                ; timer 0, low byte then high, mode 2;
        out     0x43, al                ; and 4234h is 16948, which divides
        out     0x40, al                ; the 1193182 Hz crystal down to
        mov     al, 0x42                ; 70.4 ticks a second
        out     0x40, al

        call    showscore               ; and on to crash in the grass

; ----------------------------------------------------------------- one frame
frame:
        mov     ax, [TICKS]
.tick:
        hlt                             ; sleep until the clock moves on
        cmp     ax, [TICKS]
        je      .tick

%ifdef AUTO
        mov     si, pipes - 3           ; test build, nasm -dAUTO=10: ignore
.next:  add     si, 3                   ; the keys and fly by itself, flapping
        mov     ax, [si]                ; whenever the bird sinks within AUTO
        sub     ax, BIRDX - PIPEW + 1   ; rows of the bottom of the gap it
        cmp     ax, SPACING             ; has to pass next
        jae     .next
        mov     al, [si + 2]
        add     al, GAP - BIRDH - AUTO - TOP
        cmp     [y + 1], al
        jbe     fall
%else
        mov     ah, 1
        int     0x16
        jz      fall
        mov     ah, 0
        int     0x16
        cmp     al, ' '
        jne     fall
%endif

flap:
        mov     word [vel], FLAP
fall:
        mov     ax, [vel]
        add     ax, GRAV
        mov     [vel], ax
        add     ax, [y]
        cmp     ah, 256 - 32            ; up past the top of the playfield?
        jb      .fly
        xor     ax, ax                  ; then bump against it and stop
        mov     [vel], ax
.fly:
        mov     [y], ax

        xor     di, di                  ; sky, grass, sand
        mov     cx, GROUND * 320
        mov     al, SKY
        rep     stosb
        mov     cx, GRASS * 320
        mov     al, TURF
        rep     stosb
        mov     cx, (200 - GROUND - GRASS) * 320
        mov     al, DIRT
        rep     stosb

; ---------------------------------------------------------------- the pipes
        mov     si, pipes
.pipe:
        dec     word [si]
        cmp     word [si], BIRDX - PIPEW
        jne     .edge                   ; just gone past the bird's tail?
        inc     word [score]
        mov     ax, [score]
        cmp     ax, [best]
        jbe     .show
        mov     [best], ax
.show:
        call    showscore
.edge:
        cmp     word [si], -PIPEW       ; gone off the left edge? then round
        jg      .gap                    ; to the back of the queue
        add     word [si], NPIPE * SPACING
.gap:
        cmp     word [si], 320          ; off the right edge, the gap roams:
        jl      .columns                ; every frame the seed is stirred,
        imul    ax, [seed], 25173       ; with the clock thrown in, which
        add     ax, [TICKS]             ; brings in the time spent waiting
        mov     [seed], ax              ; for space, and the top byte picks
        mov     al, RANGE               ; a row, until the pipe comes in
        mul     ah
        add     ah, MINTOP
        mov     [si + 2], ah
.columns:
        xor     bx, bx                  ; bx = column within the pipe
.column:
        mov     di, [si]
        add     di, bx
        cmp     di, 320                 ; off either side of the screen?
        jae     .nextcol
        push    bx
        shr     bx, 2
        mov     al, [shade + bx]
        pop     bx
        movzx   cx, byte [si + 2]
        call    vline                   ; the top pipe comes down to the gap
        add     di, GAP * 320
        mov     cl, GROUND - GAP
        sub     cl, [si + 2]
        call    vline                   ; and the bottom one comes up to it
.nextcol:
        inc     bx
        cmp     bl, PIPEW
        jb      .column
        add     si, 3
        cmp     si, pipes.end
        jb      .pipe

; ----------------------------------------------------------------- the bird
        movzx   di, byte [y + 1]
        imul    di, di, 320
        add     di, TOP * 320 + BIRDX
        mov     si, bird
        xor     bp, bp                  ; bp counts pixels that hit something
        mov     dh, BIRDH
.row:
        lodsd                           ; two bits a pixel, leftmost at the top
        mov     dl, 16
.pixel:
        rol     eax, 2
        mov     bl, al
        and     bx, 3
        jz      .clear                  ; nothing there
        cmp     byte [es:di], SKY
        je      .paint
        inc     bp
.paint:
        mov     bl, [colours - 1 + bx]
        mov     [es:di], bl
.clear:
        inc     di
        dec     dl
        jnz     .pixel
        add     di, 320 - 16
        dec     dh
        jnz     .row

; -------------------------------------------------------- onto the screen
        push    es
        push    ds
        push    es
        pop     ds                      ; from the buffer
        push    0xa000
        pop     es                      ; to the screen
        mov     si, TOP * 320
        mov     di, si
        mov     cx, 64000 - TOP * 320
        rep     movsb
        pop     ds
        pop     es

        test    bp, bp
        jz      frame

; ------------------------------------------------- after a crash, and at boot
dead:
        mov     ah, 0x86
        mov     cx, 8                   ; half a second or so to take in the
        int     0x15                    ; crash before the keys count again,
        mov     ax, [KBTAIL]            ; then forget any that came meanwhile
        mov     [KBHEAD], ax
.wait:
        mov     ah, 0
        int     0x16
        cmp     al, ' '
        jne     .wait

        xor     ax, ax
        mov     [score], ax
        mov     byte [y + 1], STARTY - TOP
        call    showscore
        mov     si, pipes
        mov     bx, 320 + 16            ; line the pipes up off to the right
.place:
        mov     [si], bx
        add     bx, SPACING
        add     si, 3
        cmp     si, pipes.end
        jb      .place
        jmp     flap

; ------------------------- cx rows of colour al, straight down from es:di
vline:
        stosb
        add     di, 319
        loop    vline
        ret

; ---------------------------------------------------------------------------
;  Write this flight's count and the best count on the status line.
showscore:
        mov     dx, 1                   ; row 0, column 1
        mov     ax, [score]
        call    .at
        mov     dl, 36                  ; dh is still zero
        mov     ax, [best]
.at:
        push    ax
        mov     ah, 2
        mov     bx, TEXT                ; bh = page 0, bl = colour
        int     0x10
        pop     ax
        mov     cx, 3                   ; three digits, leading zeros and all
        mov     bp, 10
putnum:
        xor     dx, dx
        div     bp
        push    dx                      ; the digits come out backwards, so
        dec     cx                      ; stack them up and print them on the
        jz      .digit                  ; way back out
        call    putnum
.digit:
        pop     ax
        add     ax, 0x0e30              ; ah = teletype, al = the digit
        int     0x10
        ret

; ------------------------------------------------------------------ variables
y       dw      (GROUND - TOP - 4) << 8 ; in the grass, too deep for one flap
vel     dw      0
score   dw      0
best    dw      0
seed    dw      0

pipes:                                  ; x of the left edge, row the gap opens
        times   NPIPE db 0x80, 0x0f, 0  ; nowhere near the screen, until space
.end:

shade:  db      0x2f, 0x46, 0x2f, 0x30, 0x02, 0x78

colours:                                ; for pixel values 1, 2 and 3:
        db      14, 15, 6               ; yellow, white, brown eye and beak

bird:                                   ; 12 x 9, facing right
        dd      00_00_00_00_01_01_01_01_00_00_00_00_00_00_00_00b
        dd      00_00_01_01_01_01_01_10_10_10_00_00_00_00_00_00b
        dd      00_01_01_01_01_01_10_10_10_11_10_00_00_00_00_00b
        dd      10_10_10_01_01_01_10_10_10_11_10_00_00_00_00_00b
        dd      10_10_10_10_01_01_01_10_10_10_10_00_00_00_00_00b
        dd      01_10_10_01_01_01_01_11_11_11_11_11_00_00_00_00b
        dd      00_01_01_01_01_01_11_11_11_11_11_00_00_00_00_00b
        dd      00_00_01_01_01_01_01_11_11_11_11_00_00_00_00_00b
        dd      00_00_00_00_01_01_01_01_00_00_00_00_00_00_00_00b

        times   510 - ($ - $$) db 0
        dw      0xaa55
