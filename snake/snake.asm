; ============================================================================
;  snake.asm -- the snake game in one 512-byte boot sector
;
;  Dmitry Brant, 2025+, feat. Claude Code.
;
;  Boots on any 386 or later PC and talks to nothing but the BIOS and the
;  timer chip:
;       int 10h / ah=00h al=03h   80x25 colour text
;       int 10h / ax=1112h        the 8x8 ROM font, which makes it 80x50
;       int 10h / ah=01h          switch the cursor off
;       int 15h / ah=86h          a pause after each crash
;       int 16h / ah=00h, 01h     read the keyboard, or just look at it
;       ports 40h / 43h           the 8253, told to tick 100 times a second
;  Characters go straight into the text buffer at B800:0000.
;
;  Controls:  arrows  steer
;             space   start a game
;
;  Fifty rows of eight-line characters make cells very nearly square, so the
;  snake covers the same ground whichever way it heads.  The top row is the
;  title bar: this game's score and the best since the machine was switched
;  on at the left, GAME OVER and PRESS SPACE at the right when they apply.
;  Below it is a walled field of 78 x 48 open cells.  Every star eaten scores
;  one and makes the snake four blocks longer, and every fourth one makes it
;  a little quicker, up to twenty steps a second.
;
;  There is no map of the field besides the screen itself.  Wherever the head
;  is about to go, the character already there decides what happens: a blank
;  is open ground, a star is dinner, and anything else, wall, title bar or
;  snake, is the end.  The tail is lifted before the head looks, so the head
;  may follow right on its heels.  That only ever comes up because the snake
;  starts four blocks long and stays a multiple of four: a closed loop on a
;  grid always takes an even number of blocks.
;
;  The snake itself is a queue of text buffer offsets, one word per block,
;  in a segment of its own.  The head goes on at one end and the tail comes
;  off the other, and the two indexes wrap round the 64K by themselves, far
;  more room than the 3744 blocks it would take to fill the field.  Between
;  steps the whole state of play lives in registers:
;       di  the head's offset in the text buffer
;       bp  the step, in the same units: -2, +2, -160 or +160
;       bx  where the head is in the queue
;       si  where the tail is in the queue
;       dx  blocks still to grow
;
;  Assemble:  nasm -f bin -o snake.bin snake.asm
;  Run:       qemu-system-i386 -drive file=snake.bin,format=raw
;  ...or write to a floppy disk or USB drive and boot on a real machine!
; ============================================================================

        bits    16
        org     0x7c00

QUEUE   equ     0x1000          ; the snake's segment, clear of us and the stack
COLS    equ     80
ROWS    equ     50
HOME    equ     25 * 160 + 38 * 2       ; where every game's head starts out
GROWTH  equ     4               ; blocks the snake grows by per star
SLOW    equ     9               ; ticks a step to start with: 11 steps a second
FAST    equ     5               ; and at the most: 20 a second
SPEEDUP equ     4               ; stars between speed-ups, a power of two

WALL    equ     0x1f20          ; white on blue: the walls and the title bar
BLANK   equ     0x0020          ; black space: open ground
BODY    equ     0x02db          ; green block
HEAD    equ     0x0adb          ; light green block
STAR    equ     0x0e2a          ; yellow star
CRASH   equ     0x0cdb          ; red block: the head, after a crash

SCOREAT equ     11 * 2          ; title bar columns, as buffer offsets: the last
BESTAT  equ     23 * 2          ; digit of each count, the title, and the two
TITLEAT equ     37 * 2          ; messages
OVERAT  equ     56 * 2
PRESSAT equ     OVERAT + (message.press - message) * 2

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
        mov     al, 3                   ; ah is still zero
        int     0x10
        mov     ax, 0x1112              ; font block 0 gets the 8x8 font, and
        xor     bx, bx                  ; 400 lines of eight make fifty rows
        int     0x10
        mov     ah, 1
        mov     ch, 0x20                ; a start line past the bottom of the
        int     0x10                    ; cell hides the cursor
        push    0xb800
        pop     es                      ; ES = the text buffer, for good
        push    QUEUE
        pop     fs                      ; FS = the snake, likewise

        mov     al, 0x34                ; timer 0, low byte then high, mode 2;
        out     0x43, al                ; and 2E34h is 11828, which divides
        out     0x40, al                ; the 1193182 Hz crystal down to
        mov     al, 0x2e                ; 100.9 ticks a second
        out     0x40, al

        call    board
        mov     si, message.press       ; nothing to be over yet
        mov     di, PRESSAT
        jmp     over

; ------------------------------------------------- after a crash, and at boot
dead:
        sub     di, bp                  ; back to the head, which is what
        mov     word [es:di], CRASH     ; turns red
        mov     si, message
        mov     di, OVERAT
over:
        call    puts
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
        call    board
        mov     byte [delay], SLOW
        mov     ax, [TICKS]             ; the time spent waiting for space
        mov     [seed], ax              ; picks this game's stars
        mov     dx, GROWTH - 1          ; one block now and three to grow
        mov     bp, 2                   ; heading right
        mov     di, HOME
        mov     si, bx                  ; head and tail are the same block,
        mov     [fs:bx], di             ; wherever the queue starts
        mov     word [es:di], HEAD
        call    food

; ------------------------------------------------------------------ one step
step:
        movzx   cx, byte [delay]
.wait:
        mov     ax, [TICKS]
.tick:
        hlt                             ; sleep until the clock moves on
        cmp     ax, [TICKS]
        je      .tick
        loop    .wait

.key:
        mov     ah, 1                   ; one turn a step at most, and the rest
        int     0x16                    ; wait their turn, so two quick turns
        jz      .go                     ; make two separate steps
        mov     ah, 0
        int     0x16
        push    si
        mov     si, arrows - 3
        mov     cx, 4
.find:
        add     si, 3
        cmp     ah, [si]                ; the scan code,
        loopne  .find
        mov     ax, [si + 1]            ; and the step it stands for
        pop     si
        jne     .key                    ; not an arrow: next key
        mov     cx, ax                  ; a real turn?  A turn adds 2 to 160,
        add     cx, bp                  ; either sign, and sets bit 1 of the
        test    cl, 2                   ; sum; carrying on or doubling back
        jz      .key                    ; adds 2 to 2 or 160 to 160 and does
        mov     bp, ax                  ; not.  Those keys are dropped on the
                                        ; spot, so a held-down arrow that
                                        ; auto-repeats never holds up the next

.go:
        mov     word [es:di], BODY      ; the old head is just body now
        add     di, bp
        dec     dx                      ; still growing?  then the tail stays
        jns     .look
        inc     dx
        fs lodsw                        ; if not, it moves up a block
        xchg    ax, bx
        mov     word [es:bx], BLANK
        xchg    ax, bx

.look:
        mov     ax, [es:di]
        cmp     ax, BLANK
        je      .move
        cmp     ax, STAR
        jne     dead

        add     dx, GROWTH
        inc     word [score]
        mov     ax, [score]
        cmp     ax, [best]
        jbe     .show
        mov     [best], ax
.show:
        call    showscore
        test    al, SPEEDUP - 1         ; every so many stars, a little faster
        jnz     .food
        cmp     byte [delay], FAST
        jbe     .food
        dec     byte [delay]
.food:
        call    food

.move:
        inc     bx
        inc     bx
        mov     [fs:bx], di
        mov     word [es:di], HEAD
        jmp     step

; ---------------------------------------------------------------------------
;  Put a star on a blank cell picked at random.  The top byte of the seed,
;  scaled to the screen, picks a cell, and if it is not open ground the seed
;  goes round again.  The multiplier is 1 mod 4 and the increment odd, so
;  the seed runs through all 65536 values before repeating, and a blank cell
;  is always found as long as there is one.
food:
        pusha
.try:
        imul    ax, [seed], 25173
        inc     ax
        mov     [seed], ax
        mov     cx, COLS * ROWS
        mul     cx                      ; dx = the cell
        mov     bx, dx
        add     bx, bx
        cmp     word [es:bx], BLANK
        jne     .try
        mov     word [es:bx], STAR
        popa
        ret

; ---------------------------------------------------------------------------
;  The playing field: fill the screen with wall, hollow out all but the edge
;  of it, and letter the title bar, counts and all.
board:
        xor     di, di
        mov     ax, WALL
        mov     cx, COLS * ROWS
        rep     stosw
        mov     di, 160 + 2             ; row 1, column 1
        mov     ax, BLANK
        mov     bl, ROWS - 2
.row:
        mov     cl, COLS - 2
        rep     stosw
        scasw                           ; step over the right-hand wall and
        scasw                           ; the next row's left-hand one
        dec     bl
        jnz     .row
        mov     si, labels
        mov     di, 2 * 2
        call    puts
        mov     di, TITLEAT             ; si has moved on to the title
        call    puts
                                        ; and on into showscore
; ---------------------------------------------------------------------------
;  Write this game's count and the best count into the title bar.
showscore:
        pusha
        mov     ax, [score]
        mov     di, SCOREAT
        call    putnum
        mov     ax, [best]
        mov     di, BESTAT
        call    putnum
        popa
        ret

putnum:                                 ; four digits of ax, backwards from di
        mov     cx, 4
        mov     bx, 10
.digit:
        xor     dx, dx
        div     bx
        add     dl, '0'
        mov     [es:di], dl
        dec     di
        dec     di
        loop    .digit
        ret

; ---------------------------------------------------------------------------
;  Letter the string at si into the title bar from di, leaving the colours.
puts:
        lodsb
        test    al, al
        jz      .done
        stosb
        inc     di
        jmp     puts
.done:
        ret

; ------------------------------------------------------------------ variables
delay   db      SLOW                    ; ticks a step
score   dw      0
best    dw      0
seed    dw      0

arrows:                                 ; scan code, and the step it takes
        db      0x48
        dw      -160
        db      0x50
        dw      160
        db      0x4b
        dw      -2
        db      0x4d
        dw      2

labels:
        db      "SCORE        BEST", 0
        db      "SNAKE", 0
message:
        db      "GAME OVER  "
.press:
        db      "PRESS SPACE", 0

        times   510 - ($ - $$) db 0
        dw      0xaa55
