
;==============================================================================
;   - Teclado:  A = cargar hora actual y luego hasta 3 horarios (HHMM y #)
;               B = calibrar sensor (tapa cerrada + #, tapa abierta + #)
;               D = modo demo ON/OFF (1 s real = 1 min de reloj)
;               # = confirmar      * = cancelar / salir de CONFIG
;               En un horario, '#' sin digitos = deshabilitar esa toma.
;==============================================================================

        LIST    P=16F887
        #include <p16f887.inc>
        errorlevel -302                
;------------------------------------------------------------------------------
BUZZER_PASIVO   equ     0               ; 0 = buzzer ACTIVO (RD1 en alto)
                                        ; 1 = buzzer pasivo (tono por TMR0)
TONO_RELOAD     equ     d'164'          ; mayor valor = tono mas agudo
VENTANA_MIN     equ     d'10'           ; minutos para abrir la tapa
UMB_ALTO_DEF    equ     d'150'          ; umbral por defecto (sin calibrar)
UMB_BAJO_DEF    equ     d'100'

; Estados
EST_CONFIG      equ     d'0'
EST_ESPERA      equ     d'1'
EST_ALARMA      equ     d'2'

; Subestados de CONFIG
CF_HORA         equ     d'0'
CF_H1           equ     d'1'
CF_H2           equ     d'2'
CF_H3           equ     d'3'
CF_CAL1         equ     d'4'
CF_CAL2         equ     d'5'

; Codigos de tecla
K_A             equ     d'10'
K_B             equ     d'11'
K_C             equ     d'12'
K_D             equ     d'13'
K_AST           equ     d'14'           ; *
K_NUM           equ     d'15'           ; #

; Eventos para la UART
EV_ALARMA       equ     d'1'
EV_TOMADA       equ     d'2'
EV_NOTOMADA     equ     d'3'
EV_FUERA        equ     d'4'
EV_DEMO_ON      equ     d'5'
EV_DEMO_OFF     equ     d'6'
EV_CALIB        equ     d'7'
EV_INVAL        equ     d'8'

; Alias de bits
#define T0IE_BIT        INTCON,5
#define T0IF_BIT        INTCON,2
#define PEIE_BIT        INTCON,6
#define GIE_BIT         INTCON,7
#define TMR2IF_BIT      PIR1,1
#define TXIF_BIT        PIR1,4
#define GO_BIT          ADCON0,1
#define BUZZ            PORTD,1         ; RD1: buzzer (y tambien el LED 1)

TXBUF           equ     0xA0            ; buffer de transmision (banco 1, 64 bytes)

;------------------------------------------------------------------------------
; RAM (banco 0)
;------------------------------------------------------------------------------
        cblock  0x20
        TICK5, C10, C100                ; contadores de ticks
        F10, F100, F1S, FMIN, FSTAT     ; banderas de tiempo
        DIGIDX, SELMASK, SEGTMP, TMPI   ; multiplexado
        DISP1, DISP2, DISP3, DISP4      ; codigos 7 segmentos (bit7 = punto)
        BLINK, BLCNT, BEEPCNT, BEEPON, ERRTMR
        HORA, MINU, SEGU
        DEMO
        ESTADO, SUBCFG
        H1, M1, H2, M2, H3, M3          ; horarios de toma (H = 0xFF: deshabilitada)
        TOMA_ACT, VENT, ESP_CIER
        TAPA, FAPER
        UMB_ALTO, UMB_BAJO, CAL_CERR, CAL_ABI
        ACC_L, ACC_H, ADC_N, ADC_PROM
        KRAW, KPREV, KSTAB, KEY, KEYNEW
        KROW, KCOL, KMASK, KTMP
        KBUF1, KBUF2, KBUF3, KBUF4, KPOS
        TEMP, TEMP2, HTMP, MTMP, TT, TU, TH, PCTMP
        MD_L, MD_H, NOW_L, NOW_H, BST_L, BST_H, BST_I, SLOT_I
        PRX_H, PRX_M
        EVT, EV_H, EV_M, EV_H2, EV_M2, EV_RET, EV_TOMA
        TXWP, TXPOS, STRIDX
        P_H, P_M
        CNT
        endc

        cblock  0x7D                    ; RAM comun a todos los bancos
        W_TEMP, ST_TEMP, PCL_TEMP
        endc

;------------------------------------------------------------------------------
; VECTORES  
;------------------------------------------------------------------------------
RES_VECT    CODE    0x0000              ; vector de reset
        goto    INICIO

ISR_VECT    CODE    0x0004              ; vector de interrupcion
        goto    ISR

MAIN_PROG   CODE                        ; el linker lo ubica despues de 0x0004

;==============================================================================
; INTERRUPCION: TMR2 cada 2 ms (displays + base de tiempo) y TMR0 (tono)
;==============================================================================
ISR:
        movwf   W_TEMP
        swapf   STATUS,w
        movwf   ST_TEMP
        movf    PCLATH,w
        movwf   PCL_TEMP
        clrf    PCLATH
        bcf     STATUS,RP0
        bcf     STATUS,RP1

        btfss   TMR2IF_BIT
        goto    ISR_T0
        bcf     TMR2IF_BIT
        call    ISR_TICK
ISR_T0
        if BUZZER_PASIVO == 1
        btfss   T0IF_BIT
        goto    ISR_FIN
        bcf     T0IF_BIT
        movlw   TONO_RELOAD
        movwf   TMR0
        movf    BEEPON,f
        btfsc   STATUS,Z
        goto    ISR_FIN
        movlw   0x02
        xorwf   PORTD,f                 ; conmuta RD1 (tono)
        endif
ISR_FIN
        movf    PCL_TEMP,w
        movwf   PCLATH
        swapf   ST_TEMP,w
        movwf   STATUS
        swapf   W_TEMP,f
        swapf   W_TEMP,w
        retfie

;------------------------------------------------------------------------------
; Un digito por tick + contadores de 10 ms, 100 ms y 1 s
;------------------------------------------------------------------------------
ISR_TICK:
        movf    PORTA,w                 ; apagar selectores RA1,RA2,RA3,RA5
        andlw   b'11010001'
        movwf   PORTA

        movf    DIGIDX,w
        btfsc   STATUS,Z
        goto    IT_D1
        movf    DIGIDX,w
        xorlw   d'1'
        btfsc   STATUS,Z
        goto    IT_D2
        movf    DIGIDX,w
        xorlw   d'2'
        btfsc   STATUS,Z
        goto    IT_D3
        movf    DISP4,w                 ; digito 4 -> RA5
        movwf   SEGTMP
        movlw   b'00100000'
        movwf   SELMASK
        goto    IT_OUT
IT_D1:
        movf    DISP1,w                 ; digito 1 -> RA1
        movwf   SEGTMP
        movlw   b'00000010'
        movwf   SELMASK
        goto    IT_OUT
IT_D2:
        movf    DISP2,w                 ; digito 2 -> RA2 (con punto)
        movwf   SEGTMP
        btfsc   BLINK,0
        bsf     SEGTMP,7
        movlw   b'00000100'
        movwf   SELMASK
        goto    IT_OUT
IT_D3:
        movf    DISP3,w                 ; digito 3 -> RA3
        movwf   SEGTMP
        movlw   b'00001000'
        movwf   SELMASK
IT_OUT:
        movf    SEGTMP,w                ; segmentos a-f en RC0-RC5
        andlw   0x3F
        movwf   TMPI
        movf    PORTC,w
        andlw   0xC0                    ; conserva RC6/RC7 (UART)
        iorwf   TMPI,w
        movwf   PORTC
        btfsc   SEGTMP,6                ; g en RE0
        bsf     PORTE,0
        btfss   SEGTMP,6
        bcf     PORTE,0
        btfsc   SEGTMP,7                ; punto en RE1
        bsf     PORTE,1
        btfss   SEGTMP,7
        bcf     PORTE,1
        movf    PORTA,w                 ; habilitar el digito
        iorwf   SELMASK,w
        movwf   PORTA
        incf    DIGIDX,f
        movlw   d'4'
        xorwf   DIGIDX,w
        btfsc   STATUS,Z
        clrf    DIGIDX

        incf    TICK5,f                 ; 5 ticks = 10 ms
        movlw   d'5'
        xorwf   TICK5,w
        btfss   STATUS,Z
        return
        clrf    TICK5
        movlw   d'1'
        movwf   F10
        incf    C10,f                   ; 10 x 10 ms = 100 ms
        movlw   d'10'
        xorwf   C10,w
        btfss   STATUS,Z
        return
        clrf    C10
        movlw   d'1'
        movwf   F100
        incf    C100,f                  ; 10 x 100 ms = 1 s
        movlw   d'10'
        xorwf   C100,w
        btfss   STATUS,Z
        return
        clrf    C100
        movlw   d'1'
        movwf   F1S
        return

;==============================================================================
; INICIALIZACION
;==============================================================================
INICIO:
        banksel ANSEL
        movlw   0x01                    ; solo AN0 analogico
        movwf   ANSEL
        clrf    ANSELH
        clrf    BAUDCTL                 ; BRG de 8 bits

        banksel TRISA
        movlw   b'00010001'             ; RA0 (LDR) y RA4 entradas
        movwf   TRISA
        movlw   0xF0                    ; RB4-RB7 columnas (entrada)
        movwf   TRISB
        movlw   0xC0                    ; RC6/RC7 UART, RC0-RC5 segmentos
        movwf   TRISC
        clrf    TRISD
        movlw   b'00001100'             ; RE0,RE1 salidas
        movwf   TRISE
        movlw   b'00000000'             ; pull-ups ON, TMR0 prescaler 1:2
        movwf   OPTION_REG
        movlw   0xF0
        movwf   WPUB                    ; pull-ups de las columnas
        clrf    IOCB
        clrf    ADCON1                  ; resultado a izquierda, Vref = VDD/VSS
        movlw   d'124'
        movwf   PR2                     ; TMR2: 125 x 16 us = 2 ms
        movlw   b'00000010'
        movwf   PIE1                    ; TMR2IE
        movlw   b'00100100'
        movwf   TXSTA                   ; TXEN=1, BRGH=1
        movlw   d'25'
        movwf   SPBRG                   ; 9600 baud
        banksel PORTA
        clrf    PORTA
        movlw   0xFF
        movwf   PORTB                   ; filas del teclado en alto
        clrf    PORTC
        clrf    PORTD
        clrf    PORTE
        movlw   b'01000001'             ; Fosc/8, AN0, ADC encendido
        movwf   ADCON0
        movlw   b'10000000'
        movwf   RCSTA                   ; SPEN=1
        movlw   b'00000110'
        movwf   T2CON                   ; TMR2 ON, prescaler 1:16
        clrf    PIR1

        movlw   0x20                    ; borrar RAM 0x20-0x7C
        movwf   FSR
CLR_RAM:
        clrf    INDF
        incf    FSR,f
        movlw   0x7D
        xorwf   FSR,w
        btfss   STATUS,Z
        goto    CLR_RAM

        movlw   0xFF
        movwf   H1
        movwf   H2
        movwf   H3
        movwf   KRAW
        movwf   KPREV
        movwf   KSTAB
        movwf   PRX_H
        movlw   UMB_ALTO_DEF
        movwf   UMB_ALTO
        movlw   UMB_BAJO_DEF
        movwf   UMB_BAJO
        movlw   EST_CONFIG
        movwf   ESTADO
        movlw   CF_HORA
        movwf   SUBCFG
        movlw   TXBUF
        movwf   TXWP
        movwf   TXPOS
        movlw   0x40
        movwf   DISP1
        movwf   DISP2
        movwf   DISP3
        movwf   DISP4
        movlw   d'1'
        movwf   FSTAT                   ; primera linea de estado al encender

        bsf     PEIE_BIT
        bsf     GIE_BIT

;==============================================================================
; LAZO PRINCIPAL (nunca espera: todo se hace por banderas)
;==============================================================================
MAIN:
        movf    F10,f
        btfsc   STATUS,Z
        goto    MA_100
        clrf    F10
        call    TECLADO_10MS
MA_100:
        movf    F100,f
        btfsc   STATUS,Z
        goto    MA_1S
        clrf    F100
        call    TAREAS_100MS
MA_1S:
        movf    F1S,f
        btfsc   STATUS,Z
        goto    MA_RESTO
        clrf    F1S
        call    RELOJ_1S
MA_RESTO:
        call    MAQ_ESTADOS
        call    PREPARAR_DISPLAYS
        call    UART_SERVICIO
        goto    MAIN

;==============================================================================
; RELOJ
;==============================================================================
RELOJ_1S:
        movf    DEMO,f
        btfss   STATUS,Z
        goto    RL_MIN                  ; demo: cada segundo = 1 minuto
        incf    SEGU,f
        movlw   d'60'
        xorwf   SEGU,w
        btfss   STATUS,Z
        return
        clrf    SEGU
RL_MIN:
        incf    MINU,f
        movlw   d'60'
        xorwf   MINU,w
        btfss   STATUS,Z
        goto    RL_EVT
        clrf    MINU
        incf    HORA,f
        movlw   d'24'
        xorwf   HORA,w
        btfsc   STATUS,Z
        clrf    HORA
RL_EVT:
        movlw   d'1'
        movwf   FMIN                    ; evento: cambio de minuto
        return

;==============================================================================
; TAREAS CADA 100 ms: sensor, parpadeo del punto, patron de alarma
;==============================================================================
TAREAS_100MS:
        call    LEER_LDR
        incf    BLCNT,f                 ; punto: conmuta cada 500 ms
        movlw   d'5'
        xorwf   BLCNT,w
        btfss   STATUS,Z
        goto    T1_ERR
        clrf    BLCNT
        movlw   d'1'
        xorwf   BLINK,f
T1_ERR:
        movf    ERRTMR,f
        btfss   STATUS,Z
        decf    ERRTMR,f
        ; patron de alarma: 200 ms encendido / 200 ms apagado (buzzer + 8 LEDs)
        movf    ESTADO,w
        xorlw   EST_ALARMA
        btfss   STATUS,Z
        goto    SND_OFF_LED
        incf    BEEPCNT,f
        movlw   d'4'
        xorwf   BEEPCNT,w
        btfsc   STATUS,Z
        clrf    BEEPCNT
        movlw   d'2'
        subwf   BEEPCNT,w
        btfsc   STATUS,C
        goto    SND_OFF
        goto    SND_ON
SND_OFF_LED:
        clrf    BEEPCNT
SND_OFF:                                ; apaga el buzzer y los 8 LEDs
        if BUZZER_PASIVO == 1
        clrf    BEEPON
        bcf     T0IE_BIT
        endif
        clrf    PORTD
        return
SND_ON:                                 ; prende el buzzer y los 8 LEDs
        if BUZZER_PASIVO == 1
        movlw   d'1'
        movwf   BEEPON
        bsf     T0IE_BIT
        movlw   b'11111101'             ; RD1 lo maneja el tono (TMR0)
        iorwf   PORTD,f
        else
        movlw   0xFF                    ; RD0-RD7 = LEDs, RD1 = buzzer activo
        movwf   PORTD
        endif
        return

;==============================================================================
; ADC: 4 muestras promediadas + deteccion de apertura con histeresis
;==============================================================================
LEER_ADC8:
        movlw   d'8'                    ; tiempo de adquisicion ~ 24 us
        movwf   TEMP
LA_ADQ:
        decfsz  TEMP,f
        goto    LA_ADQ
        bsf     GO_BIT
LA_ESP:
        btfsc   GO_BIT
        goto    LA_ESP
        movf    ADRESH,w                ; 8 bits altos
        return

LEER_LDR:
        clrf    ACC_L
        clrf    ACC_H
        movlw   d'4'
        movwf   ADC_N
LL_LOOP:
        call    LEER_ADC8
        addwf   ACC_L,f
        btfsc   STATUS,C
        incf    ACC_H,f
        decfsz  ADC_N,f
        goto    LL_LOOP
        bcf     STATUS,C                ; promedio = suma / 4
        rrf     ACC_H,f
        rrf     ACC_L,f
        bcf     STATUS,C
        rrf     ACC_H,f
        rrf     ACC_L,w
        movwf   ADC_PROM
        movf    TAPA,f
        btfss   STATUS,Z
        goto    LL_ABIERTA
        movf    UMB_ALTO,w              ; cerrada: abre si PROM >= UMB_ALTO
        subwf   ADC_PROM,w
        btfss   STATUS,C
        return
        movlw   d'1'
        movwf   TAPA
        movwf   FAPER                   ; evento: apertura
        return
LL_ABIERTA:
        movf    UMB_BAJO,w              ; abierta: cierra si PROM < UMB_BAJO
        subwf   ADC_PROM,w
        btfsc   STATUS,C
        return
        clrf    TAPA
        return

;==============================================================================
; TECLADO 4x4: exploracion cada 10 ms, estable 2 lecturas (20 ms)
;==============================================================================
SCAN_TECLADO:                           ; W = codigo (0-15) o 0xFF
        clrf    KROW
        movlw   b'11111110'
        movwf   KMASK
SC_LOOP:
        movf    KMASK,w
        movwf   PORTB                   ; una fila en bajo
        nop
        nop
        movf    PORTB,w
        andlw   0xF0
        xorlw   0xF0                    ; bits en 1 = columnas presionadas
        btfss   STATUS,Z
        goto    SC_FOUND
        bsf     STATUS,C
        rlf     KMASK,f
        incf    KROW,f
        movlw   d'4'
        xorwf   KROW,w
        btfss   STATUS,Z
        goto    SC_LOOP
        movlw   0xFF
        movwf   PORTB
        return                          ; W = 0xFF: ninguna tecla
SC_FOUND:
        movwf   KTMP
        clrf    KCOL
        btfsc   KTMP,4
        goto    SC_GOT
        incf    KCOL,f
        btfsc   KTMP,5
        goto    SC_GOT
        incf    KCOL,f
        btfsc   KTMP,6
        goto    SC_GOT
        incf    KCOL,f
SC_GOT:
        movlw   0xFF
        movwf   PORTB
        bcf     STATUS,C
        rlf     KROW,w
        movwf   TEMP
        bcf     STATUS,C
        rlf     TEMP,w                  ; W = fila * 4
        addwf   KCOL,w                  ; W = fila*4 + columna
        movwf   TEMP
        movlw   high TBL_KEYS
        movwf   PCLATH
        movf    TEMP,w
        call    TBL_KEYS
        return

TECLADO_10MS:
        call    SCAN_TECLADO
        movwf   KRAW
        xorwf   KPREV,w
        btfss   STATUS,Z
        goto    TK_FIN                  ; cambio: esperar otra lectura igual
        movf    KRAW,w
        xorwf   KSTAB,w
        btfsc   STATUS,Z
        goto    TK_FIN                  ; sin novedad
        movf    KRAW,w
        movwf   KSTAB
        xorlw   0xFF
        btfsc   STATUS,Z
        goto    TK_FIN                  ; se solto la tecla
        movf    KSTAB,w
        movwf   KEY
        movlw   d'1'
        movwf   KEYNEW                  ; evento: tecla pulsada
TK_FIN:
        movf    KRAW,w
        movwf   KPREV
        return

;==============================================================================
; MAQUINA DE ESTADOS
;==============================================================================
MAQ_ESTADOS:
        movf    ESTADO,w
        btfsc   STATUS,Z
        goto    ST_CONFIG
        xorlw   EST_ESPERA
        btfsc   STATUS,Z
        goto    ST_ESPERA
        goto    ST_ALARMA

;------------------------------------------------------------------ ESPERA ---
ST_ESPERA:
        movf    FMIN,f
        btfsc   STATUS,Z
        goto    SE_APERT
        clrf    FMIN
        call    CALC_PROX
        call    BUSCAR_TOMA             ; W = n de toma (1-3) o 0
        movwf   TOMA_ACT
        movf    TOMA_ACT,f
        btfsc   STATUS,Z
        goto    SE_APERT
        goto    INICIAR_ALARMA
SE_APERT:
        movf    FAPER,f
        btfsc   STATUS,Z
        goto    SE_TECLAS
        clrf    FAPER                   ; apertura fuera de horario
        movf    HORA,w
        movwf   EV_H2
        movf    MINU,w
        movwf   EV_M2
        movlw   EV_FUERA
        call    EV_SET
SE_TECLAS:
        movf    KEYNEW,f
        btfsc   STATUS,Z
        return
        clrf    KEYNEW
        movf    KEY,w
        xorlw   K_A
        btfsc   STATUS,Z
        goto    ENTRAR_CFG_HORA
        movf    KEY,w
        xorlw   K_B
        btfsc   STATUS,Z
        goto    ENTRAR_CAL
        movf    KEY,w
        xorlw   K_D
        btfsc   STATUS,Z
        goto    ALT_DEMO
        return

ENTRAR_CFG_HORA:
        movlw   EST_CONFIG
        movwf   ESTADO
        movlw   CF_HORA
        movwf   SUBCFG
        clrf    KPOS
        movlw   d'1'
        movwf   FSTAT                   ; cambio de estado: avisar a la PC
        return
ENTRAR_CAL:
        movlw   EST_CONFIG
        movwf   ESTADO
        movlw   CF_CAL1
        movwf   SUBCFG
        clrf    KPOS
        movlw   d'1'
        movwf   FSTAT                   ; cambio de estado: avisar a la PC
        return
ALT_DEMO:
        movlw   d'1'
        xorwf   DEMO,f
        clrf    SEGU
        movf    DEMO,f
        btfsc   STATUS,Z
        goto    AD_OFF
        movlw   EV_DEMO_ON
        goto    EV_SET
AD_OFF:
        movlw   EV_DEMO_OFF
EV_SET:
        movwf   EVT
        return

INICIAR_ALARMA:
        movlw   EST_ALARMA
        movwf   ESTADO
        clrf    VENT
        clrf    BEEPCNT
        clrf    ESP_CIER
        clrf    FAPER
        movf    TAPA,f
        btfsc   STATUS,Z
        goto    IA_1
        movlw   d'1'
        movwf   ESP_CIER                ; tapa ya abierta: hay que cerrarla
IA_1:
        movf    TOMA_ACT,w
        movwf   EV_TOMA
        movf    HORA,w
        movwf   EV_H
        movf    MINU,w
        movwf   EV_M
        movlw   EV_ALARMA
        call    EV_SET
        goto    SND_ON                  ; buzzer + 8 LEDs

;------------------------------------------------------------------ ALARMA ---
ST_ALARMA:
        clrf    KEYNEW                  ; teclas ignoradas
        movf    ESP_CIER,f
        btfsc   STATUS,Z
        goto    SA_NORMAL
        movf    TAPA,f
        btfss   STATUS,Z
        goto    SA_MIN                  ; sigue abierta
        clrf    ESP_CIER                ; ya la cerraron
        clrf    FAPER
        goto    SA_MIN
SA_NORMAL:
        movf    FAPER,f
        btfsc   STATUS,Z
        goto    SA_MIN
        clrf    FAPER                   ; apertura: TOMADA
        call    GET_SLOT
        movf    HTMP,w
        movwf   EV_H
        movf    MTMP,w
        movwf   EV_M
        movf    HORA,w
        movwf   EV_H2
        movf    MINU,w
        movwf   EV_M2
        movf    VENT,w
        movwf   EV_RET
        movlw   EV_TOMADA
        call    EV_SET
        goto    FIN_ALARMA
SA_MIN:
        movf    FMIN,f
        btfsc   STATUS,Z
        return
        clrf    FMIN
        incf    VENT,f
        movlw   VENTANA_MIN
        subwf   VENT,w
        btfss   STATUS,C
        return                          ; todavia dentro de la ventana
        call    GET_SLOT                ; ventana vencida: NO TOMADA
        movf    HTMP,w
        movwf   EV_H
        movf    MTMP,w
        movwf   EV_M
        movlw   EV_NOTOMADA
        call    EV_SET
FIN_ALARMA:
        call    SND_OFF                 ; apaga buzzer y LEDs
        movlw   EST_ESPERA
        movwf   ESTADO
        clrf    BEEPCNT
        movlw   d'1'
        movwf   FSTAT                   ; vuelve a ESPERA: avisar a la PC
        goto    CALC_PROX

GET_SLOT:                               ; HTMP:MTMP = horario de TOMA_ACT
        movf    TOMA_ACT,w
        addwf   TOMA_ACT,w
        addlw   H1-2
        movwf   FSR
        movf    INDF,w
        movwf   HTMP
        incf    FSR,f
        movf    INDF,w
        movwf   MTMP
        return

BUSCAR_TOMA:                            ; W = n de toma que coincide con la hora, o 0
        movlw   H1
        movwf   FSR
        movlw   d'1'
        movwf   SLOT_I
BT_LOOP:
        movf    INDF,w
        xorwf   HORA,w
        btfss   STATUS,Z
        goto    BT_NEXT
        incf    FSR,f
        movf    INDF,w
        decf    FSR,f
        xorwf   MINU,w
        btfsc   STATUS,Z
        goto    BT_HIT
BT_NEXT:
        incf    FSR,f
        incf    FSR,f
        incf    SLOT_I,f
        movlw   d'4'
        xorwf   SLOT_I,w
        btfss   STATUS,Z
        goto    BT_LOOP
        retlw   d'0'
BT_HIT:
        movf    SLOT_I,w
        return

;------------------------------------------------------------------ CONFIG ---
ST_CONFIG:
        clrf    FMIN                    ; sin alarmas durante la configuracion
        clrf    FAPER
        movf    KEYNEW,f
        btfsc   STATUS,Z
        return
        clrf    KEYNEW
        movf    KEY,w
        xorlw   K_AST
        btfsc   STATUS,Z
        goto    CFG_SALIR
        movf    SUBCFG,w
        xorlw   CF_CAL1
        btfsc   STATUS,Z
        goto    CFG_CAL1
        movf    SUBCFG,w
        xorlw   CF_CAL2
        btfsc   STATUS,Z
        goto    CFG_CAL2
        movf    KEY,w
        xorlw   K_NUM
        btfsc   STATUS,Z
        goto    CFG_ENTER
        movlw   d'10'
        subwf   KEY,w
        btfsc   STATUS,C
        return                          ; A-D: ignoradas
        movf    KPOS,w
        sublw   d'3'
        btfss   STATUS,C
        return                          ; ya hay 4 digitos
        movlw   KBUF1
        addwf   KPOS,w
        movwf   FSR
        movf    KEY,w
        movwf   INDF
        incf    KPOS,f
        return

CFG_SALIR:
        movlw   EST_ESPERA
        movwf   ESTADO
        clrf    KPOS
        movlw   d'1'
        movwf   FSTAT                   ; sale de CONFIG: avisar a la PC
        goto    CALC_PROX

CFG_ENTER:
        movf    KPOS,w
        btfsc   STATUS,Z
        goto    CFG_VACIO
        movlw   d'4'
        xorwf   KPOS,w
        btfss   STATUS,Z
        goto    CFG_INVAL               ; faltan digitos
        call    KBUF_A_HM               ; HTMP = hh, MTMP = mm
        movlw   d'24'
        subwf   HTMP,w
        btfsc   STATUS,C
        goto    CFG_INVAL
        movlw   d'60'
        subwf   MTMP,w
        btfsc   STATUS,C
        goto    CFG_INVAL
        movf    SUBCFG,w
        xorlw   CF_HORA
        btfsc   STATUS,Z
        goto    CFG_SET_HORA
        ; horario de toma: validar separacion minima con las otras tomas
        movf    HTMP,w
        movwf   P_H
        movf    MTMP,w
        movwf   P_M
        call    CHECK_SEP
        movwf   TEMP2
        movf    P_H,w
        movwf   HTMP
        movf    P_M,w
        movwf   MTMP
        movf    TEMP2,f
        btfss   STATUS,Z
        goto    CFG_INVAL
        movf    SUBCFG,w
        addwf   SUBCFG,w
        addlw   H1-2
        movwf   FSR
        movf    HTMP,w
        movwf   INDF
        incf    FSR,f
        movf    MTMP,w
        movwf   INDF
CFG_NEXT:
        incf    SUBCFG,f
        clrf    KPOS
        movlw   CF_CAL1                 ; despues de la toma 3 se sale
        xorwf   SUBCFG,w
        btfss   STATUS,Z
        return
        goto    CFG_SALIR

CFG_SET_HORA:
        movf    HTMP,w
        movwf   HORA
        movf    MTMP,w
        movwf   MINU
        clrf    SEGU
        movlw   CF_H1
        movwf   SUBCFG
        clrf    KPOS
        return

CFG_VACIO:                              ; '#' sin digitos
        movf    SUBCFG,w
        xorlw   CF_HORA
        btfsc   STATUS,Z
        return                          ; la hora no puede quedar vacia
        movf    SUBCFG,w
        addwf   SUBCFG,w
        addlw   H1-2
        movwf   FSR
        movlw   0xFF
        movwf   INDF                    ; toma deshabilitada
        goto    CFG_NEXT

CFG_INVAL:
        clrf    KPOS
        movlw   d'15'
        movwf   ERRTMR                  ; "EEEE" durante 1,5 s
        movlw   EV_INVAL
        goto    EV_SET

CFG_CAL1:
        movf    KEY,w
        xorlw   K_NUM
        btfss   STATUS,Z
        return
        movf    ADC_PROM,w              ; lectura con tapa cerrada
        movwf   CAL_CERR
        movlw   CF_CAL2
        movwf   SUBCFG
        return
CFG_CAL2:
        movf    KEY,w
        xorlw   K_NUM
        btfss   STATUS,Z
        return
        movf    ADC_PROM,w              ; lectura con tapa abierta
        movwf   CAL_ABI
        call    CALC_UMBRAL
        iorlw   0
        btfss   STATUS,Z
        goto    CFG_CAL_ERR
        movlw   EV_CALIB
        call    EV_SET
        goto    CFG_SALIR
CFG_CAL_ERR:
        movlw   CF_CAL1
        movwf   SUBCFG
        goto    CFG_INVAL

CALC_UMBRAL:                            ; W = 0 ok, 1 error
        movf    CAL_CERR,w
        subwf   CAL_ABI,w               ; delta = ABI - CERR
        btfss   STATUS,C
        retlw   d'1'
        movwf   TEMP
        movlw   d'8'
        subwf   TEMP,w
        btfss   STATUS,C
        retlw   d'1'                    ; delta < 8: diferencia insuficiente
        bcf     STATUS,C
        rrf     TEMP,w                  ; delta / 2
        addwf   CAL_CERR,w
        movwf   TEMP2                   ; punto medio
        bcf     STATUS,C
        rrf     TEMP,f
        bcf     STATUS,C
        rrf     TEMP,f
        bcf     STATUS,C
        rrf     TEMP,f                  ; banda = delta / 8
        movf    TEMP,w
        addwf   TEMP2,w
        movwf   UMB_ALTO
        movf    TEMP,w
        subwf   TEMP2,w
        movwf   UMB_BAJO
        retlw   d'0'

; W = 10 * TEMP (TEMP <= 9); destruye TEMP y TEMP2
MUL10:
        bcf     STATUS,C
        rlf     TEMP,f
        movf    TEMP,w
        movwf   TEMP2                   ; 2x
        bcf     STATUS,C
        rlf     TEMP,f                  ; 4x
        bcf     STATUS,C
        rlf     TEMP,w                  ; 8x
        addwf   TEMP2,w
        return

KBUF_A_HM:                              ; KBUF1..4 -> HTMP (hh), MTMP (mm)
        movf    KBUF1,w
        movwf   TEMP
        call    MUL10
        movwf   HTMP
        movf    KBUF2,w
        addwf   HTMP,f
        movf    KBUF3,w
        movwf   TEMP
        call    MUL10
        movwf   MTMP
        movf    KBUF4,w
        addwf   MTMP,f
        return

; HTMP:MTMP -> MD_H:MD_L = HTMP*60 + MTMP
MIN_DIA:
        clrf    MD_H
        movf    MTMP,w
        movwf   MD_L
        movf    HTMP,w
        btfsc   STATUS,Z
        return
        movwf   CNT
MD_LOOP:
        movlw   d'60'
        addwf   MD_L,f
        btfsc   STATUS,C
        incf    MD_H,f
        decfsz  CNT,f
        goto    MD_LOOP
        return

; Conflicto si el horario HTMP:MTMP queda a VENTANA_MIN minutos o menos de otra toma
; (distancia circular en el dia). SUBCFG indica la toma que se esta editando.
; W = 0 sin conflicto, 1 conflicto.
CHECK_SEP:
        call    MIN_DIA
        movf    MD_L,w
        movwf   NOW_L
        movf    MD_H,w
        movwf   NOW_H
        movlw   H1
        movwf   FSR
        movlw   d'1'
        movwf   SLOT_I
CS_LOOP:
        movf    SLOT_I,w
        xorwf   SUBCFG,w
        btfsc   STATUS,Z
        goto    CS_NEXT                 ; la misma toma
        movf    INDF,w
        movwf   HTMP
        xorlw   0xFF
        btfsc   STATUS,Z
        goto    CS_NEXT                 ; deshabilitada
        incf    FSR,f
        movf    INDF,w
        movwf   MTMP
        decf    FSR,f
        call    MIN_DIA                 ; MD = otra toma
        movf    NOW_L,w                 ; d = MD - NOW
        subwf   MD_L,f
        movf    NOW_H,w
        btfss   STATUS,C
        incf    NOW_H,w
        subwf   MD_H,f
        btfsc   STATUS,C
        goto    CS_POS
        movlw   0xA0                    ; negativo: sumar 1440 (0x05A0)
        addwf   MD_L,f
        btfsc   STATUS,C
        incf    MD_H,f
        movlw   0x05
        addwf   MD_H,f
CS_POS:
        movf    MD_H,f
        btfss   STATUS,Z
        goto    CS_ALTO
        movlw   VENTANA_MIN+1           ; hace falta MAS de VENTANA_MIN minutos:
        subwf   MD_L,w                  ; la ventana termina en el minuto T+10
        btfss   STATUS,C                ; y ese minuto no evalua una toma nueva
        retlw   d'1'                    ; d <= 10 min
        goto    CS_NEXT
CS_ALTO:
        movlw   0x05
        xorwf   MD_H,w
        btfss   STATUS,Z
        goto    CS_NEXT
        movlw   0xA0-VENTANA_MIN        ; d >= 1430 (1440 - 10), parte baja
        subwf   MD_L,w
        btfsc   STATUS,C
        retlw   d'1'
CS_NEXT:
        incf    FSR,f
        incf    FSR,f
        incf    SLOT_I,f
        movlw   d'4'
        xorwf   SLOT_I,w
        btfss   STATUS,Z
        goto    CS_LOOP
        retlw   d'0'

; Proxima toma (PRX_H:PRX_M; PRX_H = 0xFF si no hay ninguna)
CALC_PROX:
        movf    HORA,w
        movwf   HTMP
        movf    MINU,w
        movwf   MTMP
        call    MIN_DIA
        movf    MD_L,w
        movwf   NOW_L
        movf    MD_H,w
        movwf   NOW_H
        movlw   0xFF
        movwf   BST_L
        movlw   0x7F
        movwf   BST_H
        clrf    BST_I
        movlw   H1
        movwf   FSR
        movlw   d'1'
        movwf   SLOT_I
CP_LOOP:
        movf    INDF,w
        movwf   HTMP
        xorlw   0xFF
        btfsc   STATUS,Z
        goto    CP_NEXT                 ; deshabilitada
        incf    FSR,f
        movf    INDF,w
        movwf   MTMP
        decf    FSR,f
        call    MIN_DIA
        movf    NOW_L,w                 ; dist = toma - ahora
        subwf   MD_L,f
        movf    NOW_H,w
        btfss   STATUS,C
        incf    NOW_H,w
        subwf   MD_H,f
        btfsc   STATUS,C
        goto    CP_POS
        movlw   0xA0
        addwf   MD_L,f
        btfsc   STATUS,C
        incf    MD_H,f
        movlw   0x05
        addwf   MD_H,f
CP_POS:
        movf    MD_L,w                  ; dist = 0 -> manana (1440)
        iorwf   MD_H,w
        btfss   STATUS,Z
        goto    CP_CMP
        movlw   0xA0
        movwf   MD_L
        movlw   0x05
        movwf   MD_H
CP_CMP:
        movf    BST_L,w                 ; si dist < mejor -> guardar
        subwf   MD_L,w
        movf    BST_H,w
        btfss   STATUS,C
        incf    BST_H,w
        subwf   MD_H,w
        btfsc   STATUS,C
        goto    CP_NEXT
        movf    MD_L,w
        movwf   BST_L
        movf    MD_H,w
        movwf   BST_H
        movf    SLOT_I,w
        movwf   BST_I
CP_NEXT:
        incf    FSR,f
        incf    FSR,f
        incf    SLOT_I,f
        movlw   d'4'
        xorwf   SLOT_I,w
        btfss   STATUS,Z
        goto    CP_LOOP
        movf    BST_I,w
        btfsc   STATUS,Z
        goto    CP_NONE
        addwf   BST_I,w
        addlw   H1-2
        movwf   FSR
        movf    INDF,w
        movwf   PRX_H
        incf    FSR,f
        movf    INDF,w
        movwf   PRX_M
        return
CP_NONE:
        movlw   0xFF
        movwf   PRX_H
        return

;==============================================================================
; DISPLAYS: hora HH:MM; en CONFIG muestra lo que se edita
;==============================================================================
SEG7:                                   ; W = 0..9 -> codigo de 7 segmentos
        movwf   TEMP
        movlw   high TBL_7SEG
        movwf   PCLATH
        movf    TEMP,w
        goto    TBL_7SEG                ; el retlw vuelve al llamador

DIGMAC  macro   idx, kbuf, disp
        local   typed, done
        movlw   idx+1
        subwf   KPOS,w                  ; C=1 si KPOS > idx (digito cargado)
        btfsc   STATUS,C
        goto    typed
        movlw   0x40                    ; '-'
        movwf   disp
        goto    done
typed:
        movf    kbuf,w
        call    SEG7
        movwf   disp
done:
        endm

PREPARAR_DISPLAYS:
        movf    ERRTMR,f
        btfsc   STATUS,Z
        goto    PD_NOERR
        movlw   0x79                    ; "EEEE"
        movwf   DISP1
        movwf   DISP2
        movwf   DISP3
        movwf   DISP4
        return
PD_NOERR:
        movf    ESTADO,w
        btfsc   STATUS,Z
        goto    PD_CONFIG
        movf    HORA,w
        call    BIN2BCD
        movf    TT,w
        call    SEG7
        movwf   DISP1
        movf    TU,w
        call    SEG7
        movwf   DISP2
        movf    MINU,w
        call    BIN2BCD
        movf    TT,w
        call    SEG7
        movwf   DISP3
        movf    TU,w
        call    SEG7
        movwf   DISP4
        return
PD_CONFIG:
        movf    SUBCFG,w
        xorlw   CF_CAL1
        btfsc   STATUS,Z
        goto    PD_CAL1
        movf    SUBCFG,w
        xorlw   CF_CAL2
        btfsc   STATUS,Z
        goto    PD_CAL2
        movf    KPOS,f
        btfss   STATUS,Z
        goto    PD_TYPED
        movlw   0x40                    ; sin digitos: mostrar que se pide
        movwf   DISP3
        movwf   DISP4
        movf    SUBCFG,w
        btfsc   STATUS,Z
        goto    PD_PHORA
        movwf   TEMP2                   ; "P" + n de toma
        movlw   0x73
        movwf   DISP1
        movf    TEMP2,w
        call    SEG7
        movwf   DISP2
        return
PD_PHORA:
        movlw   0x76                    ; "H---"
        movwf   DISP1
        movlw   0x40
        movwf   DISP2
        return
PD_TYPED:
        DIGMAC  0, KBUF1, DISP1
        DIGMAC  1, KBUF2, DISP2
        DIGMAC  2, KBUF3, DISP3
        DIGMAC  3, KBUF4, DISP4
        return
PD_CAL1:
        movlw   d'1'
        goto    PD_CAL
PD_CAL2:
        movlw   d'2'
PD_CAL:
        call    SEG7                    ; "CAL1" / "CAL2"
        movwf   DISP4
        movlw   0x39
        movwf   DISP1
        movlw   0x77
        movwf   DISP2
        movlw   0x38
        movwf   DISP3
        return

;==============================================================================
; UART: buffer lineal, un caracter por vuelta del lazo (no bloqueante)
;==============================================================================
UART_SERVICIO:
        movf    TXPOS,w
        xorwf   TXWP,w
        btfsc   STATUS,Z
        goto    US_VACIO
        btfss   TXIF_BIT
        return
        movf    TXPOS,w
        movwf   FSR
        movf    INDF,w
        movwf   TXREG
        incf    TXPOS,f
        return
US_VACIO:
        movlw   TXBUF                   ; buffer vacio: reiniciar punteros
        movwf   TXPOS
        movwf   TXWP
        movf    EVT,f
        btfss   STATUS,Z
        goto    COMPONER_EVENTO
        movf    FSTAT,f
        btfsc   STATUS,Z
        return
        clrf    FSTAT
        goto    COMPONER_ESTADO

PUTC:                                   ; agrega W al buffer
        movwf   PCTMP
        movf    TXWP,w
        movwf   FSR
        movf    PCTMP,w
        movwf   INDF
        incf    TXWP,f
        return
PUT_DIG:
        addlw   '0'
        goto    PUTC
PUT_CRLF:
        movlw   0x0D
        call    PUTC
        movlw   0x0A
        goto    PUTC

BIN2BCD:                                ; W (0-99) -> TT decenas, TU unidades
        movwf   TU
        clrf    TT
B2_LOOP:
        movlw   d'10'
        subwf   TU,w
        btfss   STATUS,C
        return
        movwf   TU
        incf    TT,f
        goto    B2_LOOP

PUT_HHMM:                               ; escribe "HH:MM" de P_H:P_M
        movf    P_H,w
        call    BIN2BCD
        movf    TT,w
        call    PUT_DIG
        movf    TU,w
        call    PUT_DIG
        movlw   ':'
        call    PUTC
        movf    P_M,w
        call    BIN2BCD
        movf    TT,w
        call    PUT_DIG
        movf    TU,w
        goto    PUT_DIG

PUT_EVHM:                               ; EV_H:EV_M
        movf    EV_H,w
        movwf   P_H
        movf    EV_M,w
        movwf   P_M
        goto    PUT_HHMM
PUT_EVHM2:                              ; EV_H2:EV_M2
        movf    EV_H2,w
        movwf   P_H
        movf    EV_M2,w
        movwf   P_M
        goto    PUT_HHMM

PUT_DEC3:                               ; W (0-255) en 3 digitos
        movwf   TEMP
        clrf    TH
P3_LOOP:
        movlw   d'100'
        subwf   TEMP,w
        btfss   STATUS,C
        goto    P3_FIN
        movwf   TEMP
        incf    TH,f
        goto    P3_LOOP
P3_FIN:
        movf    TH,w
        call    PUT_DIG
        movf    TEMP,w
        call    BIN2BCD
        movf    TT,w
        call    PUT_DIG
        movf    TU,w
        goto    PUT_DIG

PUTSTR:                                 ; W = desplazamiento en la tabla de textos
        movwf   STRIDX
PS_LOOP:
        movlw   high TABLA_TXT
        movwf   PCLATH
        movf    STRIDX,w
        call    TABLA_TXT
        iorlw   0
        btfsc   STATUS,Z
        return                          ; 0 = fin de texto
        call    PUTC
        incf    STRIDX,f
        goto    PS_LOOP

COMPONER_EVENTO:
        movf    EVT,w
        movwf   TEMP2
        clrf    EVT
        movf    TEMP2,w
        xorlw   EV_ALARMA
        btfsc   STATUS,Z
        goto    CE_ALARMA
        movf    TEMP2,w
        xorlw   EV_TOMADA
        btfsc   STATUS,Z
        goto    CE_TOMADA
        movf    TEMP2,w
        xorlw   EV_NOTOMADA
        btfsc   STATUS,Z
        goto    CE_NOTOMADA
        movf    TEMP2,w
        xorlw   EV_FUERA
        btfsc   STATUS,Z
        goto    CE_FUERA
        movf    TEMP2,w
        xorlw   EV_DEMO_ON
        btfsc   STATUS,Z
        goto    CE_DEMO_ON
        movf    TEMP2,w
        xorlw   EV_DEMO_OFF
        btfsc   STATUS,Z
        goto    CE_DEMO_OFF
        movf    TEMP2,w
        xorlw   EV_CALIB
        btfsc   STATUS,Z
        goto    CE_CALIB
        movlw   S_INVAL-TABLA_TXT-1
        call    PUTSTR
        goto    PUT_CRLF

CE_ALARMA:                              ; ALARMA toma 1 a las 08:00
        movlw   S_ALARMA-TABLA_TXT-1
        call    PUTSTR
        movf    EV_TOMA,w
        call    PUT_DIG
        movlw   S_ALAS-TABLA_TXT-1
        call    PUTSTR
        call    PUT_EVHM
        goto    PUT_CRLF
CE_TOMADA:                              ; Pastilla de las 08:00: TOMADA a las 08:03 (retraso 3 min)
        movlw   S_PAST-TABLA_TXT-1
        call    PUTSTR
        call    PUT_EVHM
        movlw   S_TOM-TABLA_TXT-1
        call    PUTSTR
        call    PUT_EVHM2
        movlw   S_RET-TABLA_TXT-1
        call    PUTSTR
        movf    EV_RET,w
        call    PUT_DIG
        movlw   S_MIN-TABLA_TXT-1
        call    PUTSTR
        goto    PUT_CRLF
CE_NOTOMADA:                            ; Pastilla de las 14:00: NO TOMADA
        movlw   S_PAST-TABLA_TXT-1
        call    PUTSTR
        call    PUT_EVHM
        movlw   S_NOTOM-TABLA_TXT-1
        call    PUTSTR
        goto    PUT_CRLF
CE_FUERA:                               ; Apertura fuera de horario a las 16:45
        movlw   S_FUERA-TABLA_TXT-1
        call    PUTSTR
        call    PUT_EVHM2
        goto    PUT_CRLF
CE_DEMO_ON:
        movlw   S_DEMOON-TABLA_TXT-1
        call    PUTSTR
        goto    PUT_CRLF
CE_DEMO_OFF:
        movlw   S_DEMOOFF-TABLA_TXT-1
        call    PUTSTR
        goto    PUT_CRLF
CE_CALIB:
        movlw   S_CALIB-TABLA_TXT-1
        call    PUTSTR
        goto    PUT_CRLF

COMPONER_ESTADO:                        ; "Estado: ESPERA, proxima: 14:00"
        movf    ESTADO,w
        xorlw   EST_ALARMA
        btfsc   STATUS,Z
        return                          ; en ALARMA ya sale la linea del evento
        movlw   S_ESTADO-TABLA_TXT-1
        call    PUTSTR                  ; "Estado: "
        movf    ESTADO,w
        btfsc   STATUS,Z
        goto    NS_CONFIG
        movlw   S_ESPERA-TABLA_TXT-1
        call    PUTSTR
        movlw   S_PROX-TABLA_TXT-1
        call    PUTSTR                  ; ", proxima: "
        movf    PRX_H,w
        xorlw   0xFF
        btfss   STATUS,Z
        goto    NS_PROX
        movlw   S_NOPROX-TABLA_TXT-1
        call    PUTSTR                  ; "--:--" (ninguna toma cargada)
        goto    PUT_CRLF
NS_PROX:
        movf    PRX_H,w
        movwf   P_H
        movf    PRX_M,w
        movwf   P_M
        call    PUT_HHMM
        goto    PUT_CRLF
NS_CONFIG:
        movlw   S_CONFIG-TABLA_TXT-1
        call    PUTSTR
        goto    PUT_CRLF

;==============================================================================
; TABLAS (todas en la pagina 0x0700-0x07FF: PCLATH = high de la tabla)
;==============================================================================
; Si el codigo principal llegara a pasar de 0x0700, el linker avisa que las
; secciones se superponen.
TABLAS      CODE    0x0700
TBL_7SEG:                               ; catodo comun, a=bit0 ... g=bit6
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

TBL_KEYS:                               ; indice = fila*4 + columna
        addwf   PCL,f
        retlw   d'1'                    ; fila 1: 1 2 3 A
        retlw   d'2'
        retlw   d'3'
        retlw   K_A
        retlw   d'4'                    ; fila 2: 4 5 6 B
        retlw   d'5'
        retlw   d'6'
        retlw   K_B
        retlw   d'7'                    ; fila 3: 7 8 9 C
        retlw   d'8'
        retlw   d'9'
        retlw   K_C
        retlw   K_AST                   ; fila 4: * 0 # D
        retlw   d'0'
        retlw   K_NUM
        retlw   K_D

TABLA_TXT:                              ; el desplazamiento 0 es el primer caracter
        addwf   PCL,f
S_PAST:     dt  "Pastilla de las ",0
S_TOM:      dt  ": TOMADA a las ",0
S_RET:      dt  " (retraso ",0
S_MIN:      dt  " min)",0
S_NOTOM:    dt  ": NO TOMADA",0
S_FUERA:    dt  "Apertura fuera de horario a las ",0
S_ALARMA:   dt  "ALARMA toma ",0
S_ALAS:     dt  " a las ",0
S_ESTADO:   dt  "Estado: ",0
S_PROX:     dt  ", proxima: ",0
S_CONFIG:   dt  "CONFIG",0
S_ESPERA:   dt  "ESPERA",0
S_NOPROX:   dt  "--:--",0
S_DEMOON:   dt  "Modo demo ON",0
S_DEMOOFF:  dt  "Modo demo OFF",0
S_CALIB:    dt  "Umbral calibrado",0
S_INVAL:    dt  "Dato invalido",0

        END
