; ============================================================================
;  mandel.asm -- a Mandelbrot explorer that fits in one 512-byte boot sector
;
;  Boots on any 386 or later PC, talks to nothing but the BIOS:
;       int 10h / ah=00h al=13h   VGA 320x200x256, default palette
;       int 16h / ah=00h          wait for a keystroke
;  Pixels go straight into the frame buffer at A000:0000.
;
;  Controls:  arrows  pan
;             + / -   zoom in / out   (main keyboard or numeric keypad)
;
;  Arithmetic is 32-bit signed fixed point, 8.24 (1.0 == 1 << 24).  The
;  escape test x*x + y*y > 4 keeps every iterate inside |z| < 2, so the
;  squares stay well below the 8.24 overflow point of +-11.3; MAXSTEP keeps
;  the zoomed-out view inside that circle as well.
;
;  Assemble:  nasm -f bin -o mandel.bin mandel.asm
;  Run:       qemu-system-i386 -fda mandel.bin
;  On iron:   write mandel.bin to the first sector of a USB stick / floppy
; ============================================================================

        bits    16
        org     0x7c00

STEP0   equ     0x00026666      ; 0.009375 -> 3.0 units across the screen
E0      equ     17              ; bsr(STEP0), the reference zoom exponent
MAXSTEP equ     0x000c0000      ; zoom-out limit (keeps the maths in range)
ITBASE  equ     64              ; iterations at the default zoom
PAN     equ     5               ; pan one 32nd of a screen (1 << 5 pixels)

; ---------------------------------------------------------------------------
start:
        xor     ax, ax
        mov     ds, ax
        mov     ss, ax
        mov     sp, start               ; stack grows down from 7C00
        cld
        mov     ax, 0x0013
        int     0x10                    ; mode 13h + default 256-colour palette
        push    0xa000
        pop     es                      ; ES = frame buffer segment

; --------------------------------------------------------------- draw a frame
render:
        mov     eax, [step]

        ; iteration limit rises with the zoom: ITBASE + 8 * (E0 - log2 step)
        bsr     ecx, eax
        mov     bx, E0
        sub     bx, cx
        jns     .depth
        xor     bx, bx                  ; zoomed out: stay at ITBASE
.depth:
        shl     bx, 3
        add     bx, ITBASE
        mov     [maxit], bx

        ; mode 13h pixels are 1.25x taller than they are wide
        mov     ebx, eax
        shr     ebx, 2
        add     ebx, eax
        mov     [stepy], ebx

        ; top-left corner = centre - (160, 100) * step
        imul    ebx, eax, 160
        mov     edx, [cenx]
        sub     edx, ebx
        mov     [xleft], edx
        imul    ebx, dword [stepy], 100
        mov     edx, [ceny]
        sub     edx, ebx
        mov     [ci], edx

        xor     di, di                  ; frame buffer offset
        mov     word [rows], 200
.row:
        mov     edx, [xleft]
        mov     [cr], edx
        mov     word [cols], 320

; ---------------------------------------------------------------- one pixel
.pixel:
        xor     ebx, ebx                ; x = 0
        xor     esi, esi                ; y = 0
        mov     cx, [maxit]
.iter:
        mov     eax, ebx
        imul    eax                     ; edx:eax = x * x
        shrd    eax, edx, 24
        mov     ebp, eax                ; ebp = xx
        mov     eax, esi
        imul    eax                     ; edx:eax = y * y
        shrd    eax, edx, 24            ; eax = yy
        mov     edx, ebp
        add     edx, eax
        cmp     edx, 4 << 24            ; xx + yy > 4.0 -> escaped
        ja      .plot
        sub     ebp, eax
        add     ebp, [cr]               ; x' = xx - yy + cr
        mov     eax, ebx
        imul    esi                     ; edx:eax = x * y
        shrd    eax, edx, 23            ; eax = 2 * x * y
        add     eax, [ci]               ; y' = 2xy + ci
        mov     esi, eax
        mov     ebx, ebp
        loop    .iter
.plot:
        imul    ax, cx, 5               ; spread the count over the palette;
        stosb                           ; cx = 0 in the set, so that is black

        mov     eax, [step]
        add     [cr], eax
        dec     word [cols]
        jnz     .pixel

        mov     eax, [stepy]
        add     [ci], eax
        dec     word [rows]
        jnz     .row

; ------------------------------------------------------------------ keyboard
key:
        xor     ah, ah
        int     0x16                    ; ah = scan code, al = ASCII
        mov     edx, [step]
        shl     edx, PAN
        cmp     al, '+'
        je      zoomin
        cmp     al, '-'
        je      zoomout
        cmp     ah, 0x4b                ; left
        je      panleft
        cmp     ah, 0x4d                ; right
        je      panx
        cmp     ah, 0x48                ; up
        je      panup
        cmp     ah, 0x50                ; down
        je      pany
        jmp     key                     ; anything else: keep the picture

panleft:
        neg     edx
panx:
        add     [cenx], edx
        jmp     render
panup:
        neg     edx
pany:
        add     [ceny], edx
        jmp     render

zoomin:
        shr     dword [step], 1
        jnz     again
        inc     dword [step]            ; never let the step reach zero
        jmp     render
zoomout:
        shl     dword [step], 1
        cmp     dword [step], MAXSTEP
        jbe     again
        shr     dword [step], 1         ; at the limit: leave the view alone
again:
        jmp     render

; ------------------------------------------------------------------ variables
step    dd      STEP0                   ; world units per pixel, horizontally
cenx    dd      -0x00800000             ; centre of the view: -0.5 + 0.0i
ceny    dd      0
stepy   dd      0                       ; step * 1.25
xleft   dd      0                       ; world x of the left edge
cr      dd      0                       ; c for the pixel being drawn
ci      dd      0
maxit   dw      0
cols    dw      0
rows    dw      0

        times   510 - ($ - $$) db 0
        dw      0xaa55
