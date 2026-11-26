LIST      P=16F887
    #INCLUDE  <P16F887.INC>

    __CONFIG _CONFIG1, _FOSC_XT & _WDTE_OFF & _PWRTE_ON & _MCLRE_ON & _CP_OFF & _CPD_OFF & _BOREN_OFF & _IESO_OFF & _FCMEN_OFF & _LVP_OFF

;==================================================================
; CONSTANTES
;==================================================================
N_REB           EQU     D'8'     ; ticks de antirrebote (8 x 2ms ~ 16ms)
N_CC_TICKS      EQU     D'5'     ; ticks de TMR0 por centesima (5x2ms=10ms)

; Precarga de TMR0. Ideal: T0 = (256-131) x 16 x 1us = 2,000 ms.
; La formula ideal no incluye la demora hasta la recarga: latencia
; de interrupcion (~3-4 ciclos) + ~13 ciclos de ISR antes del
; MOVWF TMR0 + 2 ciclos de inhibicion de TMR0 = ~18 us por tick.
; Con 132 se restan 16 us (un paso de prescaler): T0 real ~2,00 ms.
; ESTIMACION: confirmar con el osciloscopio (selector = 4 x T0 = 8 ms).
PRECARGA        EQU     D'132'

; Valor de arranque del cronometro. Entrega: 0 y 0.
; Para probar 09:99 -> 10:00 o 59:99 -> 00:00 poner, por ejemplo,
; SS_INI = D'9' o D'59' y CC_INI = D'95'. Volver a 0 y 0 al terminar.
SS_INI          EQU     D'0'
CC_INI          EQU     D'0'

EST_DETENIDO    EQU     D'0'
EST_CONTANDO    EQU     D'1'
EST_PAUSADO     EQU     D'2'

BTN_IDLE        EQU     D'0'     ; suelto, en reposo
BTN_CONF_PULSA  EQU     D'1'     ; confirmando que la presion es real
BTN_HELD        EQU     D'2'     ; presion validada, contando duracion
BTN_CONF_SUELTA EQU     D'3'     ; confirmando que la soltada es real

;==================================================================
; VARIABLES (Banco 0)
;==================================================================
    CBLOCK 0x20
        SS              ; segundos, binario 0-59
        CC              ; centesimas, binario 0-99
        SS_DEC          ; digitos que MUESTRA la ISR (decenas de segundos)
        SS_UNI          ;   unidades de segundos
        CC_DEC          ;   decenas de centesimas
        CC_UNI          ;   unidades de centesimas
        N_SS_DEC        ; digitos NUEVOS (buffer de calculo del principal)
        N_SS_UNI
        N_CC_DEC
        N_CC_UNI
        CONTADOR        ; entrada reutilizable de BIN_TO_BCD
        DECENAS         ; salida reutilizable de BIN_TO_BCD
        UNIDADES        ; salida reutilizable de BIN_TO_BCD
        TEMP_VAL        ; auxiliar de BIN_TO_BCD
        SEG_TMP         ; patron de 7 segmentos en curso
        DIG_SEL         ; 0..3, digito que toca mostrar ahora
        DIV_CC          ; cuenta regresiva de ticks hasta la centesima
        TICKS_PEND      ; ticks de TMR0 pendientes de atender (ISR suma)
        ESTADO          ; EST_DETENIDO / EST_CONTANDO / EST_PAUSADO
        BTN_STATE       ; estado de la maquina de antirrebote
        REB_CNT         ; cuenta regresiva de antirrebote
        PRESS_CC        ; centesimas transcurridas desde que se valido la presion
        LARGA_DISPARADA ; bit0: la pulsacion larga ya actuo en esta presion
    ENDC

;==================================================================
; VARIABLES DE CONTEXTO ISR (RAM compartida 0x70-0x7F)
;==================================================================
    CBLOCK 0x70
        W_TEMP
        STATUS_TEMP
        PCLATH_TEMP
    ENDC

;==================================================================
; VECTOR DE RESET
;==================================================================
    ORG     0x00
    GOTO    INICIO

;==================================================================
; VECTOR DE INTERRUPCION
;==================================================================
    ORG     0x04
    GOTO    ISR

;==================================================================
; TABLA 7 SEGMENTOS (identica a TDL3, sin cambios)
; bit0=a(RC0) bit1=b(RC1) bit2=c(RC2) bit3=d(RC3) bit4=e(RC4)
; bit5=f(RC5) bit6=g(RE0)
;==================================================================
    ORG     0x100
TABLA_7SEG:
    ANDLW   0x0F
    MOVWF   SEG_TMP
    MOVLW   HIGH TABLA_7SEG
    MOVWF   PCLATH
    MOVF    SEG_TMP, W
    ADDWF   PCL, F
    RETLW   B'00111111'     ; 0
    RETLW   B'00000110'     ; 1
    RETLW   B'01011011'     ; 2
    RETLW   B'01001111'     ; 3
    RETLW   B'01100110'     ; 4
    RETLW   B'01101101'     ; 5
    RETLW   B'01111101'     ; 6
    RETLW   B'00000111'     ; 7
    RETLW   B'01111111'     ; 8
    RETLW   B'01101111'     ; 9
    RETLW   B'00000000'     ; default / seguridad

;==================================================================
; PROGRAMA PRINCIPAL: configuracion
;==================================================================
    ORG     0x120
INICIO:
    BANKSEL ANSEL
    CLRF    ANSEL
    CLRF    ANSELH

    BANKSEL TRISD
    CLRF    TRISD                  ; banco de LED de TDL2/3, no se usa aca
                                    ; pero se conserva configurado (progresivo)

    BANKSEL TRISA
    MOVLW   B'00010000'
    MOVWF   TRISA                  ; RA4 entrada; RA1,RA2,RA3,RA5 salidas

    BANKSEL TRISC
    MOVLW   B'11000000'
    MOVWF   TRISC                  ; RC0-RC5 salidas; RC6/RC7 reservados UART

    BANKSEL TRISE
    MOVF    TRISE, W
    ANDLW   B'11111000'
    MOVWF   TRISE                  ; RE0(g) y RE1(dp) salidas

    BANKSEL PORTD
    CLRF    PORTD
    CLRF    PORTA
    CLRF    PORTC
    CLRF    PORTE

    ; --- variables del cronometro ---
    MOVLW   SS_INI
    MOVWF   SS
    MOVLW   CC_INI
    MOVWF   CC
    CLRF    ESTADO                 ; EST_DETENIDO = 0
    CLRF    DIG_SEL
    CLRF    TICKS_PEND
    MOVLW   N_CC_TICKS
    MOVWF   DIV_CC
    CLRF    BTN_STATE              ; BTN_IDLE = 0
    CLRF    PRESS_CC
    CLRF    LARGA_DISPARADA
    CALL    ACTUALIZAR_DIGITOS     ; T0IE todavia en 0: el GIE que deja
                                    ; esta rutina no dispara nada aun

    ; --- Timer0: Fosc/4, prescaler 1:16, precarga 132 -> T0 ~ 2,000 ms ---
    BANKSEL OPTION_REG
    MOVLW   B'10000011'            ; RBPU=1 T0CS=0 PSA=0 PS2:PS0=011(1:16)
    MOVWF   OPTION_REG

    BANKSEL TMR0
    MOVLW   PRECARGA
    MOVWF   TMR0

    BANKSEL INTCON
    BCF     INTCON, T0IF
    BSF     INTCON, T0IE
    BSF     INTCON, GIE

    BANKSEL PORTA

;==================================================================
; PROGRAMA PRINCIPAL: lazo
; Atiende UN tick pendiente por vuelta. DECF es una sola instruccion,
; asi que no se pisa con el INCF de la ISR.
;==================================================================
LOOP_PRINCIPAL:
    MOVF    TICKS_PEND, W
    BTFSC   STATUS, Z
    GOTO    LOOP_PRINCIPAL         ; nada pendiente: seguir esperando
    DECF    TICKS_PEND, F          ; consumir un tick

    ; Centesima: solo cada N_CC_TICKS ticks
    DECFSZ  DIV_CC, F
    GOTO    LP_BOTON
    MOVLW   N_CC_TICKS
    MOVWF   DIV_CC
    CALL    TICK_CC
LP_BOTON:
    ; Antirrebote / duracion del pulsador: todos los ticks
    CALL    BOTON_TICK
    GOTO    LOOP_PRINCIPAL

;==================================================================
; INTERRUPCION DE TMR0 (unico origen de interrupciones de este TP)
; Solo: contexto, recarga, bandera, multiplexado, TICKS_PEND.
;==================================================================
ISR:
    MOVWF   W_TEMP
    SWAPF   STATUS, W
    CLRF    STATUS                 ; fuerza Banco 0 para toda la ISR
    MOVWF   STATUS_TEMP
    MOVF    PCLATH, W
    MOVWF   PCLATH_TEMP
    CLRF    PCLATH

    BTFSS   INTCON, T0IF
    GOTO    ISR_FIN

    ; *** Recargar TMR0 es lo PRIMERO que se hace, antes que nada ***
    ; Asi la precision del periodo no depende de cuanto tarde el
    ; resto de la ISR. No agregar instrucciones antes de esta recarga
    ; sin recalcular PRECARGA.
    MOVLW   PRECARGA
    MOVWF   TMR0
    BCF     INTCON, T0IF

    CALL    AVANZAR_MUX            ; muestra el siguiente digito
    INCF    TICKS_PEND, F          ; avisa al principal: paso un tick

ISR_FIN:
    MOVF    PCLATH_TEMP, W
    MOVWF   PCLATH
    SWAPF   STATUS_TEMP, W
    MOVWF   STATUS
    SWAPF   W_TEMP, F
    SWAPF   W_TEMP, W
    RETFIE

;==================================================================
; AVANZAR_MUX: apaga el digito actual y enciende el siguiente
;==================================================================
AVANZAR_MUX:
    BCF     PORTA, 1
    BCF     PORTA, 2
    BCF     PORTA, 3
    BCF     PORTA, 5

    MOVF    PORTC, W
    ANDLW   B'11000000'            ; mantiene RC6/RC7 (reservados UART)
    MOVWF   PORTC
    BCF     PORTE, 0
    BCF     PORTE, 1

    MOVF    DIG_SEL, W
    BTFSC   STATUS, Z
    GOTO    MUX_SS_DEC
    MOVF    DIG_SEL, W
    XORLW   D'1'
    BTFSC   STATUS, Z
    GOTO    MUX_SS_UNI
    MOVF    DIG_SEL, W
    XORLW   D'2'
    BTFSC   STATUS, Z
    GOTO    MUX_CC_DEC
    GOTO    MUX_CC_UNI             ; unico caso que queda: DIG_SEL=3

MUX_SS_DEC:
    MOVF    SS_DEC, W
    CALL    TABLA_7SEG
    MOVWF   SEG_TMP
    CALL    ESCRIBIR_SEGMENTOS
    BSF     PORTA, 1
    GOTO    MUX_SIG

MUX_SS_UNI:
    MOVF    SS_UNI, W
    CALL    TABLA_7SEG
    MOVWF   SEG_TMP
    CALL    ESCRIBIR_SEGMENTOS
    BSF     PORTE, 1               ; punto decimal: separador SS . CC
    BSF     PORTA, 2
    GOTO    MUX_SIG

MUX_CC_DEC:
    MOVF    CC_DEC, W
    CALL    TABLA_7SEG
    MOVWF   SEG_TMP
    CALL    ESCRIBIR_SEGMENTOS
    BSF     PORTA, 3
    GOTO    MUX_SIG

MUX_CC_UNI:
    MOVF    CC_UNI, W
    CALL    TABLA_7SEG
    MOVWF   SEG_TMP
    CALL    ESCRIBIR_SEGMENTOS
    BSF     PORTA, 5

MUX_SIG:
    INCF    DIG_SEL, F
    MOVF    DIG_SEL, W
    XORLW   D'4'
    BTFSS   STATUS, Z
    RETURN
    CLRF    DIG_SEL
    RETURN

;==================================================================
; TICK_CC: se ejecuta (desde el principal) una vez por centesima
;   - si ESTADO=CONTANDO, avanza SS:CC y refresca los digitos BCD
;   - si el boton esta en BTN_HELD, cuenta la duracion de la presion
;     y dispara la accion larga al llegar a 1,00 s (100 centesimas)
; Resolucion de la duracion de la larga: 10 ms.
;==================================================================
TICK_CC:
    MOVF    ESTADO, W
    XORLW   EST_CONTANDO
    BTFSS   STATUS, Z
    GOTO    TC_DURACION

    INCF    CC, F
    MOVLW   D'100'
    SUBWF   CC, W
    BTFSS   STATUS, Z
    GOTO    TC_ACTUALIZAR
    CLRF    CC
    INCF    SS, F
    MOVLW   D'60'
    SUBWF   SS, W
    BTFSS   STATUS, Z
    GOTO    TC_ACTUALIZAR
    CLRF    SS

TC_ACTUALIZAR:
    CALL    ACTUALIZAR_DIGITOS

TC_DURACION:
    MOVF    BTN_STATE, W
    XORLW   BTN_HELD
    BTFSS   STATUS, Z
    RETURN
    BTFSC   LARGA_DISPARADA, 0
    RETURN
    INCF    PRESS_CC, F
    MOVLW   D'100'
    SUBWF   PRESS_CC, W
    BTFSS   STATUS, Z
    RETURN
    BSF     LARGA_DISPARADA, 0
    CALL    ACCION_LARGA
    RETURN

;==================================================================
; BOTON_TICK: antirrebote no bloqueante + deteccion corta/larga
;   4 estados: BTN_IDLE, BTN_CONF_PULSA, BTN_HELD, BTN_CONF_SUELTA
;   RA4 activo en bajo (0 = presionado), con pull-up externo
;==================================================================
BOTON_TICK:
    MOVF    BTN_STATE, W
    BTFSC   STATUS, Z
    GOTO    BT_IDLE
    MOVF    BTN_STATE, W
    XORLW   BTN_CONF_PULSA
    BTFSC   STATUS, Z
    GOTO    BT_CONF_PULSA
    MOVF    BTN_STATE, W
    XORLW   BTN_HELD
    BTFSC   STATUS, Z
    GOTO    BT_HELD
    GOTO    BT_CONF_SUELTA         ; unico estado que queda

BT_IDLE:
    BTFSC   PORTA, 4                ; 1 = sigue suelto, nada que hacer
    RETURN
    MOVLW   N_REB
    MOVWF   REB_CNT
    MOVLW   BTN_CONF_PULSA
    MOVWF   BTN_STATE
    RETURN

BT_CONF_PULSA:
    BTFSC   PORTA, 4                ; se solto antes de confirmar: rebote
    GOTO    BT_A_IDLE
    DECFSZ  REB_CNT, F
    RETURN
    ; presion confirmada: arranca el conteo de duracion
    MOVLW   BTN_HELD
    MOVWF   BTN_STATE
    CLRF    PRESS_CC
    BCF     LARGA_DISPARADA, 0
    RETURN

BT_A_IDLE:
    MOVLW   BTN_IDLE
    MOVWF   BTN_STATE
    RETURN

BT_HELD:
    BTFSS   PORTA, 4                ; 0 = sigue presionado, nada que hacer
    RETURN
    MOVLW   N_REB
    MOVWF   REB_CNT
    MOVLW   BTN_CONF_SUELTA
    MOVWF   BTN_STATE
    RETURN

BT_CONF_SUELTA:
    BTFSS   PORTA, 4                ; volvio a 0: rebote en la soltada
    GOTO    BT_A_HELD
    DECFSZ  REB_CNT, F
    RETURN
    ; liberacion confirmada
    MOVLW   BTN_IDLE
    MOVWF   BTN_STATE
    BTFSC   LARGA_DISPARADA, 0
    RETURN                          ; la larga ya actuo: soltar no hace nada
    CALL    ACCION_CORTA
    RETURN

BT_A_HELD:
    MOVLW   BTN_HELD
    MOVWF   BTN_STATE
    RETURN

;==================================================================
; ACCION_CORTA: se llama al validar la liberacion (antes de 1 s)
; Al pasar a CONTANDO (desde detenido o desde pausa) se reinicia
; DIV_CC: la primera centesima dura completa y la pausa no
; arrastra un resto de tiempo.
;==================================================================
ACCION_CORTA:
    MOVF    ESTADO, W
    BTFSS   STATUS, Z               ; Z=1 si ESTADO==EST_DETENIDO(0)
    GOTO    AC_NO_DETENIDO
    MOVLW   EST_CONTANDO
    MOVWF   ESTADO                  ; Detenido + corta -> Contando (ya en inicio)
    GOTO    AC_ARRANCA
AC_NO_DETENIDO:
    MOVF    ESTADO, W
    XORLW   EST_CONTANDO
    BTFSS   STATUS, Z
    GOTO    AC_ES_PAUSADO
    MOVLW   EST_PAUSADO
    MOVWF   ESTADO                  ; Contando + corta -> Pausado
    RETURN
AC_ES_PAUSADO:
    MOVLW   EST_CONTANDO
    MOVWF   ESTADO                  ; Pausado + corta -> Contando
AC_ARRANCA:
    MOVLW   N_CC_TICKS
    MOVWF   DIV_CC                  ; reinicia el acumulador de ticks
    RETURN

;==================================================================
; ACCION_LARGA: se llama al llegar a 1,00 s, con el boton AUN apretado
; Pone a cero (SS_INI/CC_INI) y reinicia tambien DIV_CC.
;==================================================================
ACCION_LARGA:
    MOVF    ESTADO, W
    BTFSC   STATUS, Z               ; ya esta Detenido: permanece en cero
    RETURN
    MOVLW   EST_DETENIDO
    MOVWF   ESTADO
    MOVLW   SS_INI
    MOVWF   SS
    MOVLW   CC_INI
    MOVWF   CC
    MOVLW   N_CC_TICKS
    MOVWF   DIV_CC                  ; reinicia el acumulador de ticks
    CALL    ACTUALIZAR_DIGITOS
    RETURN

;==================================================================
; ACTUALIZAR_DIGITOS: convierte SS y CC a sus 4 digitos BCD.
; Calcula en el buffer N_xx y copia los 4 digitos JUNTOS con GIE
; apagado, para que la ISR nunca muestre un digito nuevo junto a
; uno viejo (mezcla de cifras).
;==================================================================
ACTUALIZAR_DIGITOS:
    MOVF    CC, W
    MOVWF   CONTADOR
    CALL    BIN_TO_BCD
    MOVF    DECENAS, W
    MOVWF   N_CC_DEC
    MOVF    UNIDADES, W
    MOVWF   N_CC_UNI

    MOVF    SS, W
    MOVWF   CONTADOR
    CALL    BIN_TO_BCD
    MOVF    DECENAS, W
    MOVWF   N_SS_DEC
    MOVF    UNIDADES, W
    MOVWF   N_SS_UNI

AD_BLOQUEAR:
    BCF     INTCON, GIE
    BTFSC   INTCON, GIE             ; si una interrupcion se colo justo
    GOTO    AD_BLOQUEAR             ; en este BCF, GIE quedo en 1: repetir
    MOVF    N_SS_DEC, W
    MOVWF   SS_DEC
    MOVF    N_SS_UNI, W
    MOVWF   SS_UNI
    MOVF    N_CC_DEC, W
    MOVWF   CC_DEC
    MOVF    N_CC_UNI, W
    MOVWF   CC_UNI
    BSF     INTCON, GIE
    RETURN

;==================================================================
; BIN_TO_BCD (identica a TDL3, sin cambios)
;==================================================================
BIN_TO_BCD:
    MOVF    CONTADOR, W
    MOVWF   TEMP_VAL
    CLRF    DECENAS
BCD_RESTA:
    MOVLW   D'10'
    SUBWF   TEMP_VAL, W
    BTFSS   STATUS, C
    GOTO    BCD_FIN
    MOVWF   TEMP_VAL
    INCF    DECENAS, F
    GOTO    BCD_RESTA
BCD_FIN:
    MOVF    TEMP_VAL, W
    MOVWF   UNIDADES
    RETURN

;==================================================================
; ESCRIBIR_SEGMENTOS (identica a TDL3, sin cambios; el punto
; decimal NO se toca aca, se maneja aparte en AVANZAR_MUX)
;==================================================================
ESCRIBIR_SEGMENTOS:
    MOVF    PORTC, W
    ANDLW   B'11000000'
    MOVWF   PORTC

    MOVF    SEG_TMP, W
    ANDLW   B'00111111'
    IORWF   PORTC, F

    BCF     PORTE, 0
    BTFSC   SEG_TMP, 6
    BSF     PORTE, 0
    RETURN

    END