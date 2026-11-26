;==============================================================================
; TdL5 - Teclado matricial 4x4  |  PIC16F887 @ 4 MHz (MPASM)
;
; Hardware (segun asignacion de pines del curso):
;   Segmentos a-f -> RC0-RC5 | g -> RE0 | dp -> RE1   (displays catodo comun)
;   Selectores de digito (BC547, activo en alto): D1=RA1 D2=RA2 D3=RA3 D4=RA5
;   Teclado: filas RB0-RB3 (salida), columnas RB4-RB7 (entrada con pull-up)
;   LEDs en RD0-RD7: no se usan en este TdL (quedan apagados)
;
; Mapeo medido del teclado (pines del conector 1..8):
;   pines 1-4 = filas 1-4 -> RB0-RB3 | pines 5-8 = columnas 1-4 -> RB4-RB7
;
; Arquitectura:
;   - ISR de TMR0 (2 ms): multiplexado de los 4 displays + marca de tick.
;   - Lazo principal (1 vez por tick): escaneo -> antirrebote -> estado de la
;     tecla (ninguna/nueva/mantenida/liberada) -> decodificacion -> maquina de
;     estados de visualizacion/edicion.
;==============================================================================

        LIST    p=16F887
        #include <p16f887.inc>
        errorlevel -302                 ; sin avisos de cambio de banco

; __CONFIG: lo define el bootloader / tu cabecera del TdL4 (no se toca aca)

;------------------------------------------------------------------------------
; Constantes
;------------------------------------------------------------------------------
N_REBOTE        equ     d'8'            ; ticks estables para validar (~16 ms)
PRECARGA_T0     equ     d'131'          ; 256-131=125 x 16 us = 2 ms

; Funciones de tecla (resultado de la decodificacion): 0-9 = digito
K_A             equ     d'10'
K_B             equ     d'11'
K_C             equ     d'12'
K_D             equ     d'13'
K_AST           equ     d'14'           ; '*'
K_NUM           equ     d'15'           ; '#'

; Estados de la tecla
TECLA_NINGUNA   equ     d'0'
TECLA_NUEVA     equ     d'1'
TECLA_MANTENIDA equ     d'2'
TECLA_LIBERADA  equ     d'3'

; Bits
F_TICK          equ     0               ; FLAGS: paso un tick de 2 ms
E_EDICION       equ     0               ; ESTADO: 0 = visualizacion, 1 = edicion

;------------------------------------------------------------------------------
; Variables
;------------------------------------------------------------------------------
        cblock  0x20
        CONF0                           ; ultimo valor confirmado (CONF0 = millares)
        CONF1
        CONF2
        CONF3                           ; unidades
        EDIT0                           ; valor en edicion (EDIT0 = millares)
        EDIT1
        EDIT2
        EDIT3
        ESTADO                          ; bit0: 0 visualizacion / 1 edicion
        CURSOR                          ; 0..3 (cifra seleccionada)
        DIGIDX                          ; digito que se multiplexa (0..3)
        SEG                             ; patron de segmentos temporal
        FLAGS
        FILA
        COL
        PATRON
        COLMASK
        KEYCODE                         ; resultado del escaneo (0-15 / 0xFF)
        KEY_CAND                        ; candidato en antirrebote
        KEY_EST                         ; tecla estable (0xFF = ninguna)
        KEY_ANT                         ; tecla estable del tick anterior
        CNT_REB
        ESTADO_TEC                      ; ninguna/nueva/mantenida/liberada
        TECLA                           ; funcion de la tecla (0-9, K_A...)
        BLINK_CNT                       ; cuenta de ticks para el titileo (bit7 = fase)
        endc

        cblock  0x70                    ; RAM comun a todos los bancos (ISR)
        W_TEMP
        STATUS_TEMP
        PCLATH_TEMP
        FSR_TEMP
        endc

;------------------------------------------------------------------------------
; Vectores
;------------------------------------------------------------------------------
        ORG     0x0000
        goto    INICIO
        ORG     0x0004
        goto    ISR

;==============================================================================
; Interrupcion TMR0 (cada 2 ms): multiplexado de displays
;==============================================================================
ISR
        movwf   W_TEMP
        swapf   STATUS,w
        movwf   STATUS_TEMP
        movf    PCLATH,w
        movwf   PCLATH_TEMP
        movf    FSR,w
        movwf   FSR_TEMP
        clrf    PCLATH
        bcf     STATUS,RP0              ; banco 0
        bcf     STATUS,RP1

        btfss   INTCON,T0IF
        goto    ISR_FIN
        bcf     INTCON,T0IF
        movlw   PRECARGA_T0
        movwf   TMR0
        incf    BLINK_CNT,f             ; base de tiempo del titileo (256 ticks = 512 ms)

        clrf    PORTA                   ; 1) apagar los 4 selectores (evita fantasmas)

        movlw   CONF0                   ; 2) fuente: confirmado o en edicion
        btfsc   ESTADO,E_EDICION
        movlw   EDIT0
        addwf   DIGIDX,w
        movwf   FSR
        movf    INDF,w                  ;    cifra 0-9
        call    TABLA_7SEG
        movwf   SEG

        btfss   ESTADO,E_EDICION        ; 3) titileo de la cifra seleccionada
        goto    ISR_SIN_BLINK
        movf    CURSOR,w
        xorwf   DIGIDX,w
        btfss   STATUS,Z
        goto    ISR_SIN_BLINK
        btfsc   BLINK_CNT,7             ; mitad de cada ciclo: cifra apagada
        clrf    SEG
ISR_SIN_BLINK
        movlw   0xC0                    ; segmentos a-f en RC0-RC5 (RC6/RC7 intactos)
        andwf   PORTC,f
        movf    SEG,w
        andlw   0x3F
        iorwf   PORTC,f
        movlw   0xFC                    ; g -> RE0, dp -> RE1
        andwf   PORTE,f
        btfsc   SEG,6
        bsf     PORTE,0
        btfsc   SEG,7
        bsf     PORTE,1

        movf    DIGIDX,w                ; 4) encender el selector de este digito
        call    TABLA_SEL
        movwf   PORTA

        incf    DIGIDX,f                ; 5) proximo digito (0..3)
        movlw   0x03
        andwf   DIGIDX,f

        bsf     FLAGS,F_TICK            ; avisa al lazo principal
ISR_FIN
        movf    FSR_TEMP,w
        movwf   FSR
        movf    PCLATH_TEMP,w
        movwf   PCLATH
        swapf   STATUS_TEMP,w
        movwf   STATUS
        swapf   W_TEMP,f
        swapf   W_TEMP,w
        retfie

;==============================================================================
; Tablas (retlw). Deben estar dentro de una misma pagina de 256 palabras
; (direcciones bajas, lejos del limite 0x00FF; se puede confirmar en el .lst).
;==============================================================================
TABLA_7SEG                              ; bit0=a ... bit5=f, bit6=g, bit7=dp
        addwf   PCL,f
        retlw   0x3F                    ; 0
        retlw   0x06                    ; 1
        retlw   0x5B                    ; 2
        retlw   0x4F                    ; 3
        retlw   0x66                    ; 4
        retlw   0x6D                    ; 5
        retlw   0x7D                    ; 6
        retlw   0x07                    ; 7
        retlw   0x7F                    ; 8
        retlw   0x6F                    ; 9

TABLA_SEL                               ; selector de digito -> PORTA
        addwf   PCL,f
        retlw   b'00000010'             ; D1 = RA1
        retlw   b'00000100'             ; D2 = RA2
        retlw   b'00001000'             ; D3 = RA3
        retlw   b'00100000'             ; D4 = RA5

TABLA_TECLAS                            ; codigo de escaneo (fila*4+col) -> funcion
        addwf   PCL,f
        retlw   d'1'                    ; 0  fila 1: 1 2 3 A
        retlw   d'2'
        retlw   d'3'
        retlw   K_A
        retlw   d'4'                    ; 4  fila 2: 4 5 6 B
        retlw   d'5'
        retlw   d'6'
        retlw   K_B
        retlw   d'7'                    ; 8  fila 3: 7 8 9 C
        retlw   d'8'
        retlw   d'9'
        retlw   K_C
        retlw   K_AST                   ; 12 fila 4: * 0 # D
        retlw   d'0'
        retlw   K_NUM
        retlw   K_D

;==============================================================================
; Inicializacion
;==============================================================================
INICIO
        banksel ANSEL
        movlw   0x01                    ; solo AN0 analogico (potenciometro/LDR)
        movwf   ANSEL
        clrf    ANSELH                  ; RB0-RB5 digitales (imprescindible)

        banksel TRISA
        movlw   0x11                    ; RA0, RA4 entrada; RA1,2,3,5 salida
        movwf   TRISA
        movlw   0xF0                    ; filas RB0-RB3 salida, columnas RB4-RB7 entrada
        movwf   TRISB
        movlw   0xC0                    ; RC0-RC5 segmentos; RC6/RC7 (UART) entrada
        movwf   TRISC
        clrf    TRISD                   ; LEDs
        movlw   0x08                    ; RE0-RE2 salida (RE3 solo entrada)
        movwf   TRISE

        movlw   b'00000011'             ; RBPU=0 (pull-ups ON), T0CS=0, PSA=0, 1:16
        movwf   OPTION_REG
        movlw   0xF0
        movwf   WPUB                    ; pull-up debil en las columnas
        clrf    IOCB                    ; sin interrupcion por cambio

        banksel PORTA
        clrf    PORTA
        movlw   0xFF
        movwf   PORTB                   ; filas en reposo (alto)
        clrf    PORTC
        clrf    PORTD
        clrf    PORTE

        clrf    CONF0                   ; valor inicial 0000
        clrf    CONF1
        clrf    CONF2
        clrf    CONF3
        clrf    EDIT0
        clrf    EDIT1
        clrf    EDIT2
        clrf    EDIT3
        clrf    ESTADO                  ; visualizacion
        clrf    CURSOR
        clrf    DIGIDX
        clrf    FLAGS
        clrf    BLINK_CNT
        clrf    CNT_REB
        clrf    ESTADO_TEC
        movlw   0xFF
        movwf   KEYCODE
        movwf   KEY_CAND
        movwf   KEY_EST
        movwf   KEY_ANT

        movlw   PRECARGA_T0
        movwf   TMR0
        bcf     INTCON,T0IF
        bsf     INTCON,T0IE
        bsf     INTCON,GIE

;==============================================================================
; Lazo principal (una pasada por tick de 2 ms)
;==============================================================================
PRINCIPAL
        btfss   FLAGS,F_TICK
        goto    PRINCIPAL
        bcf     FLAGS,F_TICK

        call    ESCANEAR_TECLADO        ; deteccion fisica -> KEYCODE
        call    ANTIREBOTE              ; -> KEY_EST
        call    CLASIFICAR_TECLA        ; -> ESTADO_TEC

        movlw   TECLA_NUEVA             ; solo se actua en el flanco de pulsacion
        xorwf   ESTADO_TEC,w
        btfss   STATUS,Z
        goto    PRINCIPAL

        clrf    BLINK_CNT               ; tras cada tecla, la cifra queda encendida un rato

        movf    KEY_EST,w               ; interpretacion (separada de la deteccion)
        call    TABLA_TECLAS
        call    PROCESAR_TECLA
        goto    PRINCIPAL

;==============================================================================
; ESCANEAR_TECLADO: activa una fila por vez (en bajo) y lee las columnas.
; Devuelve en W el codigo fila*4+columna (0-15) o 0xFF si no hay tecla.
;==============================================================================
ESCANEAR_TECLADO
        clrf    FILA
        movlw   b'11111110'
        movwf   PATRON
ESC_FILA
        movf    PATRON,w
        movwf   PORTB                   ; una fila en bajo
        nop                             ; tiempo de establecimiento
        nop
        nop
        nop
        swapf   PORTB,w                 ; columnas RB7:RB4 -> bits 3:0
        andlw   0x0F
        xorlw   0x0F                    ; 1 = columna en bajo (tecla)
        btfss   STATUS,Z
        goto    ESC_ENCONTRADA
        bsf     STATUS,C
        rlf     PATRON,f                ; proxima fila
        incf    FILA,f
        btfss   FILA,2                  ; FILA == 4 ?
        goto    ESC_FILA
        movlw   0xFF
        movwf   KEYCODE
        goto    ESC_FIN
ESC_ENCONTRADA
        movwf   COLMASK
        clrf    COL
ESC_COL
        btfsc   COLMASK,0
        goto    ESC_CODIGO
        rrf     COLMASK,f
        incf    COL,f
        goto    ESC_COL
ESC_CODIGO
        bcf     STATUS,C
        rlf     FILA,f                  ; FILA*2
        bcf     STATUS,C
        rlf     FILA,w                  ; FILA*4
        addwf   COL,w                   ; + columna
        movwf   KEYCODE
ESC_FIN
        movlw   0xFF
        movwf   PORTB                   ; filas en reposo
        movf    KEYCODE,w
        return

;==============================================================================
; ANTIREBOTE: W = lectura cruda. KEY_EST solo cambia cuando la lectura se
; mantuvo igual N_REBOTE ticks seguidos (vale para pulsar y para soltar).
;==============================================================================
ANTIREBOTE
        movwf   KEYCODE
        xorwf   KEY_CAND,w
        btfsc   STATUS,Z
        goto    REB_IGUAL
        movf    KEYCODE,w               ; lectura distinta: reiniciar cuenta
        movwf   KEY_CAND
        movlw   N_REBOTE
        movwf   CNT_REB
        return
REB_IGUAL
        movf    CNT_REB,f
        btfsc   STATUS,Z
        return                          ; ya estable
        decfsz  CNT_REB,f
        return
        movf    KEY_CAND,w              ; la cuenta llego a 0: confirmada
        movwf   KEY_EST
        return

;==============================================================================
; CLASIFICAR_TECLA: ninguna / nueva / mantenida / liberada (en ESTADO_TEC)
; "Nueva" dura un unico tick, asi cada pulsacion se reconoce una sola vez.
;==============================================================================
CLASIFICAR_TECLA
        movf    KEY_EST,w
        xorwf   KEY_ANT,w
        btfss   STATUS,Z
        goto    CT_CAMBIO
        incf    KEY_EST,w               ; Z=1 si KEY_EST = 0xFF
        btfsc   STATUS,Z
        goto    CT_NINGUNA
        movlw   TECLA_MANTENIDA
        movwf   ESTADO_TEC
        return
CT_NINGUNA
        movlw   TECLA_NINGUNA
        movwf   ESTADO_TEC
        return
CT_CAMBIO
        movf    KEY_EST,w
        movwf   KEY_ANT
        incf    KEY_EST,w
        btfsc   STATUS,Z
        goto    CT_LIBERADA
        movlw   TECLA_NUEVA
        movwf   ESTADO_TEC
        return
CT_LIBERADA
        movlw   TECLA_LIBERADA
        movwf   ESTADO_TEC
        return

;==============================================================================
; PROCESAR_TECLA: W = funcion de la tecla. Maquina de estados
; visualizacion / edicion.
;==============================================================================
PROCESAR_TECLA
        movwf   TECLA
        btfsc   ESTADO,E_EDICION
        goto    ST_EDICION

ST_VISUALIZACION                        ; solo '#' hace algo
        movlw   K_NUM
        xorwf   TECLA,w
        btfss   STATUS,Z
        return
        call    COPIAR_CONF_A_EDIT      ; arrancar a editar desde lo confirmado
        clrf    CURSOR
        bsf     ESTADO,E_EDICION
        return

ST_EDICION
        movlw   K_A                     ; 0-9: reemplazar cifra y avanzar
        subwf   TECLA,w                 ; C=1 si TECLA >= 10
        btfsc   STATUS,C
        goto    EDIT_FUNCION
        movlw   EDIT0
        addwf   CURSOR,w
        movwf   FSR
        movf    TECLA,w
        movwf   INDF                    ; EDIT[CURSOR] = digito
        goto    CURSOR_DER              ; avanza (saturado en la ultima cifra)

EDIT_FUNCION
        movf    TECLA,w
        xorlw   K_A
        btfsc   STATUS,Z
        goto    CURSOR_IZQ
        movf    TECLA,w
        xorlw   K_B
        btfsc   STATUS,Z
        goto    CURSOR_DER
        movf    TECLA,w
        xorlw   K_C
        btfsc   STATUS,Z
        goto    ACC_BORRAR
        movf    TECLA,w
        xorlw   K_D
        btfsc   STATUS,Z
        goto    ACC_CONFIRMAR
        movf    TECLA,w
        xorlw   K_AST
        btfsc   STATUS,Z
        goto    ACC_CANCELAR
        return                          ; '#' en edicion: se ignora

CURSOR_IZQ
        movf    CURSOR,f
        btfss   STATUS,Z
        decf    CURSOR,f                ; no baja de 0
        return
CURSOR_DER
        movlw   0x03
        subwf   CURSOR,w                ; C=1 si CURSOR >= 3
        btfss   STATUS,C
        incf    CURSOR,f                ; no pasa de 3
        return

ACC_BORRAR                              ; C: valor en edicion = 0000
        clrf    EDIT0
        clrf    EDIT1
        clrf    EDIT2
        clrf    EDIT3
        clrf    CURSOR
        return
ACC_CONFIRMAR                           ; D: guardar y volver a visualizacion
        call    COPIAR_EDIT_A_CONF
        bcf     ESTADO,E_EDICION
        return
ACC_CANCELAR                            ; *: descartar y volver al ultimo confirmado
        bcf     ESTADO,E_EDICION
        return

COPIAR_CONF_A_EDIT
        movf    CONF0,w
        movwf   EDIT0
        movf    CONF1,w
        movwf   EDIT1
        movf    CONF2,w
        movwf   EDIT2
        movf    CONF3,w
        movwf   EDIT3
        return
COPIAR_EDIT_A_CONF
        movf    EDIT0,w
        movwf   CONF0
        movf    EDIT1,w
        movwf   CONF1
        movf    EDIT2,w
        movwf   CONF2
        movf    EDIT3,w
        movwf   CONF3
        return

        END