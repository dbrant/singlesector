; ============================================================================
;  mandel.asm -- a Mandelbrot / Julia explorer in one 512-byte boot sector
;
;  Dmitry Brant, 2025+, feat. Claude Code.
;
;  Boots on any 386 or later PC, talks to nothing but the BIOS:
;       int 10h / ah=00h al=13h   VGA 320x200x256, default palette
;       int 16h / ah=00h          wait for a keystroke
;  Pixels go straight into the frame buffer at A000:0000.
;
;  Controls:  arrows  pan by 32 pixels, or by one pixel with Shift+arrows
;             = / -   zoom in / out   (the keypad + and - work as well)
;             J       explore the Julia set of the point under the crosshair
;             M       back to the Mandelbrot set
;  The two sets keep separate positions and zooms, so you can hop between
;  them; every visit to a Julia set picks up the Mandelbrot crosshair afresh.
;
;  Arithmetic is 32-bit signed fixed point, 8.24 (1.0 == 1 << 24).  The
;  escape test x*x + y*y > 4 keeps every iterate inside |z| < 2, so the
;  squares stay well below the 8.24 overflow point of +-11.3; MAXSTEP keeps
;  the zoomed-out view inside that circle as well.
;
;  Assemble:  nasm -f bin -o mandel.bin mandel.asm
;  Run:       qemu-system-i386 -fda mandel.bin
;  ...or write to a floppy disk or USB drive and boot on a real machine!
; ============================================================================

        bits    16
        org     0x7c00

STEP0   equ     0x00026666      ; 0.009375 -> 3.0 units across the screen
JSTEP0  equ     0x00033333      ; 0.0125   -> 4.0 units, a good Julia view
E0      equ     17              ; bsr(STEP0), the reference zoom exponent
MAXSTEP equ     0x000c0000      ; zoom-out limit (keeps the maths in range)
ITBASE  equ     64              ; iterations at the default zoom
PAN     equ     5               ; pan one 32nd of a screen (1 << 5 pixels)
MIDDLE  equ     100 * 320 + 160 ; centre pixel of the screen
ARM     equ     4               ; crosshair arm length

; ---------------------------------------------------------------------------
start:
        xor     ax, ax
        mov     ds, ax
        mov     ss, ax
        mov     sp, ax                  ; stack grows down from the 64K mark
        cld
        mov     al, 0x13                ; ah is still zero
        int     0x10                    ; mode 13h + default 256-colour palette
        push    0xa000
        pop     es                      ; ES = frame buffer segment

; --------------------------------------------------------------- draw a frame
render:
        mov     eax, [step]

        ; iteration limit rises with the zoom: ITBASE + 8 * (E0 - log2 step).
        ; bsr also clears the top of ecx, which the pixel loop counts on.
        ; MAXSTEP holds log2 step at 19 or below, so the depth never falls
        ; under -2 and the limit stays in 48 .. 200, even zoomed right out.
        bsr     ecx, eax
        mov     bl, E0
        sub     bl, cl
        shl     bl, 3
        add     bl, ITBASE
        mov     [maxit], bl

        ; mode 13h pixels are 1.25x taller than they are wide
        mov     ebx, eax
        shr     ebx, 2
        add     ebx, eax
        mov     [stepy], ebx

        ; top-left corner = centre - (160, 100) * step, and 100 * stepy == 125 * step
        imul    ebx, eax, 160
        mov     edx, [cenx]
        sub     edx, ebx
        mov     [xleft], edx
        imul    ebx, eax, 125
        mov     edx, [ceny]
        sub     edx, ebx
        mov     [py], edx

        xor     di, di                  ; frame buffer offset
        mov     byte [rows], 200
.row:
        mov     edx, [xleft]
        mov     [px], edx
        mov     word [cols], 320

; ---------------------------------------------------------------- one pixel
.pixel:
        mov     ebx, [px]               ; Julia: z starts at the pixel,
        mov     esi, [py]               ;        c is whatever J picked
        test    byte [mode], 1
        jz      .go
        mov     [cr], ebx               ; Mandelbrot: c is the pixel,
        mov     [ci], esi               ;             z starts at 0
        xor     ebx, ebx
        xor     esi, esi
.go:
        mov     cl, [maxit]
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
        add     [px], eax
        dec     word [cols]
        jnz     .pixel

        mov     eax, [stepy]
        add     [py], eax
        dec     byte [rows]
        jnz     .row

; ------------------------------------------- crosshair, Mandelbrot mode only
        test    byte [mode], 1
        jz      key
        mov     al, 15                  ; white
        mov     cl, ARM * 2 + 1         ; ch is still zero, as ever
        mov     bx, MIDDLE - ARM * 320
        mov     di, MIDDLE - ARM
.cross:
        stosb                           ; a pixel of the horizontal arm
        mov     [es:bx], al             ; a pixel of the vertical arm
        add     bx, 320
        loop    .cross

; ------------------------------------------------------------------ keyboard
key:
        xor     ah, ah
        int     0x16                    ; ah = scan code, al = ASCII
        or      al, 0x20                ; fold J and M to lower case
        mov     edx, [step]             ; one pixel of pan
        test    byte [0x417], 3         ; BIOS keyboard flags: either shift?
        jnz     .fine
        shl     edx, PAN                ; no shift: pan by 32 pixels
.fine:
        cmp     al, '='                 ; zoom in, no shift needed
        je      zoomin
        cmp     al, '+'                 ; so does the keypad +
        je      zoomin
        cmp     al, '-'
        je      zoomout
        cmp     al, 'j'
        je      swapset
        cmp     al, 'm'
        je      swapset
        cmp     ah, 0x4b                ; left
        je      panleft
        cmp     ah, 0x4d                ; right
        je      panx
        cmp     ah, 0x48                ; up
        je      panup
        cmp     ah, 0x50                ; down
        je      pany
        jmp     key                     ; anything else: keep the picture

; ---------------------------------------------------------- change of subject
swapset:
        xchg    al, [mode]              ; al = the set we are leaving
        cmp     al, [mode]
        je      key                     ; already there: nothing to do
        cmp     al, 'm'
        jne     .views                  ; leaving Julia: just restore the view
        mov     eax, [cenx]             ; leaving Mandelbrot: the crosshair
        mov     [cr], eax               ; picks the Julia constant
        mov     eax, [ceny]
        mov     [ci], eax
.views:                                 ; exchange the live and stored views
        mov     si, view
        mov     cx, 6
.swap:
        mov     ax, [si]
        xchg    ax, [si + 12]
        mov     [si], ax
        inc     si
        inc     si
        loop    .swap
        jmp     again

; --------------------------------------------------------------------- moving
panleft:
        neg     edx
panx:
        add     [cenx], edx
        jmp     again
panup:
        neg     edx
pany:
        add     [ceny], edx
        jmp     again

zoomin:
        shr     dword [step], 1
        jnz     again
        inc     dword [step]            ; never let the step reach zero
        jmp     again
zoomout:
        shl     dword [step], 1
        cmp     dword [step], MAXSTEP
        jbe     again
        shr     dword [step], 1         ; at the limit: leave the view alone
again:
        jmp     render

; ------------------------------------------------------------------ variables
view:                                   ; the set we are looking at
cenx    dd      -0x00800000             ; centre of the view: -0.5 + 0.0i
ceny    dd      0
step    dd      STEP0                   ; world units per pixel, horizontally
        ; the set we are not looking at; Julia sets sit nicely around 0
        dd      0
        dd      0
        dd      JSTEP0
mode    db      'm'                     ; 'm'andelbrot or 'j'ulia; bit 0 tells
cr      dd      0                       ; the c of the iteration
ci      dd      0
px      dd      0                       ; world coordinates of this pixel
py      dd      0
stepy   dd      0                       ; step * 1.25
xleft   dd      0                       ; world x of the left edge
maxit   db      0
cols    dw      0
rows    db      0

        times   510 - ($ - $$) db 0
        dw      0xaa55
