    LIST      P=16F887
    #INCLUDE  <P16F887.INC>

    __CONFIG _CONFIG1, _FOSC_XT & _WDTE_OFF & _PWRTE_ON & _MCLRE_ON & _CP_OFF & _CPD_OFF & _BOREN_OFF & _IESO_OFF & _FCMEN_OFF & _LVP_OFF

;==================================================================
; VARIABLES
;==================================================================
    CBLOCK 0x20
        CONT_EXT
        CONT_INT
        MS_COUNT
        CONTADOR
        TIEMPO_CONT
        MODO
        SEQ_A
        SEQ_B
        SEQ_RUN
    ENDC

;==================================================================
; VECTOR DE RESET
;==================================================================
    ORG     0x00
    GOTO    INICIO

;==================================================================
; PROGRAMA PRINCIPAL
;==================================================================
    ORG     0x10
INICIO:
    BANKSEL ANSEL
    CLRF    ANSEL
    CLRF    ANSELH

    BANKSEL TRISD
    CLRF    TRISD
    BANKSEL TRISA
    BSF     TRISA, 4

    BANKSEL PORTD
    CLRF    PORTD
    CLRF    CONTADOR
    CLRF    MODO
    CLRF    TIEMPO_CONT    
    CLRF    SEQ_RUN
    MOVLW   0x01
    MOVWF   SEQ_A       ; arranca en el LED0
    MOVLW   0x80
    MOVWF   SEQ_B       ; arranca en el LED7

LOOP_PRINCIPAL:
    BTFSS   PORTA, 4         ; si RA4=1 (no presionado), salteo el CALL
    CALL    MANEJAR_PULSACION

    MOVF    MODO, W
    BTFSS   STATUS, Z        ; si MODO=0, Z=1 -> salteo el CALL (no hay secuencia)
    CALL    ACTUALIZAR_SECUENCIA

    GOTO    LOOP_PRINCIPAL

;==================================================================
; SUBRUTINA: MANEJAR_PULSACION
; Llamada cuando el loop principal detecta RA4=0
; Aplica antirrebote y mide si fue push corto o largo
;==================================================================
MANEJAR_PULSACION:
    MOVLW   D'20'
    CALL    DELAY_MS
    BTFSC   PORTA, 4
    RETURN                   ; era ruido, no hacemos nada

    CLRF    TIEMPO_CONT
CHECK_ESTADO:
    BTFSC   PORTA, 4
    GOTO    PUSH_CORTO
    MOVLW   D'100'
    CALL    DELAY_MS
    INCF    TIEMPO_CONT, F
    MOVLW   D'30'
    SUBWF   TIEMPO_CONT, W
    BTFSC   STATUS, Z
    GOTO    PUSH_LARGO
    GOTO    CHECK_ESTADO

PUSH_LARGO:
    MOVF    MODO, W
    XORLW   0x01
    MOVWF   MODO

    MOVF    MODO, W
    BTFSS   STATUS, Z        ; si MODO=0 (Z=1), restauro el contador en PORTD
    GOTO    ESPERAR_SUELTA
    MOVF    CONTADOR, W
    MOVWF   PORTD

ESPERAR_SUELTA:
    BTFSS   PORTA, 4
    GOTO    ESPERAR_SUELTA
    RETURN

PUSH_CORTO:
    MOVF    MODO, W
    BTFSS   STATUS, Z        ; si MODO=0 (Z=1) sigo de largo (modo contador)
    GOTO    TOGGLE_SEQ_RUN
    INCF    CONTADOR, F
    MOVF    CONTADOR, W
    MOVWF   PORTD
    RETURN

TOGGLE_SEQ_RUN:
    MOVF    SEQ_RUN, W
    XORLW   0x01
    MOVWF   SEQ_RUN
    RETURN

;==================================================================
; SUBRUTINA: ACTUALIZAR_SECUENCIA
; Rota SEQ_A a la izquierda y SEQ_B a la derecha (circular),
; las combina y muestra el resultado en PORTD
;==================================================================
ACTUALIZAR_SECUENCIA:
    BTFSS   SEQ_RUN, 0
    RETURN                   ; pausada: no avanza

    BCF     STATUS, C
    BTFSC   SEQ_A, 7
    BSF     STATUS, C
    RLF     SEQ_A, F

    BCF     STATUS, C
    BTFSC   SEQ_B, 0
    BSF     STATUS, C
    RRF     SEQ_B, F

    MOVF    SEQ_A, W
    IORWF   SEQ_B, W
    MOVWF   PORTD

    MOVLW   D'150'
    CALL    DELAY_MS
    RETURN

;==================================================================
; SUBRUTINA: DELAY_1MS
;==================================================================
DELAY_1MS:
    MOVLW   D'4'
    MOVWF   CONT_EXT
LOOP_EXT:
    MOVLW   D'83'
    MOVWF   CONT_INT
LOOP_INT:
    DECFSZ  CONT_INT, F
    GOTO    LOOP_INT
    DECFSZ  CONT_EXT, F
    GOTO    LOOP_EXT
    RETURN

;==================================================================
; SUBRUTINA: DELAY_MS
;==================================================================
DELAY_MS:
    MOVWF   MS_COUNT
MS_LOOP:
    CALL    DELAY_1MS
    DECFSZ  MS_COUNT, F
    GOTO    MS_LOOP
    RETURN

    END