// \file
 //* WS281x LED strip driver for the BeagleBone Black.
 //*
 //* Drives up to 32 strips using the PRU hardware.  The ARM writes
 //* rendered frames into shared DDR memory and sets a flag to indicate
 //* how many pixels wide the image is.  The PRU then bit bangs the signal
 //* out the 32 GPIO pins and sets a done flag.
 //*
 //* To stop, the ARM can write a 0xFF to the command, which will
 //* cause the PRU code to exit.
 //*
 //* At 800 KHz:
 //*  0 is 0.25 usec high, 1 usec low
 //*  1 is 0.60 usec high, 0.65 usec low
 //*  Reset is 50 usec
 //
 // Pins are not contiguous.
 // 16 pins on GPIO0: 2 3 4 5 7 12 13 14 15 20 22 23 26 27 30 31

#define gpio0_bit0 2
#define gpio0_bit1 3
#define gpio0_bit2 4
#define gpio0_bit3 5
#define gpio0_bit4 7
#define gpio0_bit5 12
#define gpio0_bit6 13
#define gpio0_bit7 14
#define gpio0_bit8 15
#define gpio0_bit9 20
#define gpio0_bit10 22
#define gpio0_bit11 23
#define gpio0_bit12 26
#define gpio0_bit13 27
#define gpio0_bit14 30
#define gpio0_bit15 31

// wtf "parameter too long"?  Only 128 bytes allowed.
#define GPIO0_LED_MASK (0\
|(1<<gpio0_bit0)\
|(1<<gpio0_bit1)\
|(1<<gpio0_bit2)\
|(1<<gpio0_bit3)\
|(1<<gpio0_bit4)\
|(1<<gpio0_bit5)\
|(1<<gpio0_bit6)\
|(1<<gpio0_bit7)\
|(1<<gpio0_bit8)\
|(1<<gpio0_bit9)\
|(1<<gpio0_bit10)\
|(1<<gpio0_bit11)\
|(1<<gpio0_bit12)\
|(1<<gpio0_bit13)\
|(1<<gpio0_bit14)\
|(1<<gpio0_bit15)\
)

 // 10 pins on GPIO1: 12 13 14 15 16 17 18 19 28 29
 //  5 pins on GPIO2: 1 2 3 4 5
 //  8 pins on GPIO3: 14 15 16 17 18 19 20 21
 //
 // each pixel is stored in 4 bytes in the order rgbX (4th byte is ignored)
 //
 // while len > 0:
	 // for bit# = 0 to 24:
		 // delay 600 ns
		 // read 16 registers of data, build zero map for gpio0
		 // read 10 registers of data, build zero map for gpio1
		 // read  6 registers of data, build zero map for gpio3
		 //
		 // Send start pulse on all pins on gpio0, gpio1 and gpio3
		 // delay 250 ns
		 // bring zero pins low
		 // delay 300 ns
		 // bring all pins low
	 // increment address by 32

 //*
 //* So to clock this out:
 //*  ____
 //* |  | |______|
 //* 0  250 600  1250 offset
 //*    250 350   625 delta
 //* 
 //*/
.origin 0
.entrypoint START

#include "ws281x.hp"

#define GPIO0 0x44E07000
#define GPIO1 0x4804c000
#define GPIO_CLEARDATAOUT 0x190
#define GPIO_SETDATAOUT 0x194

#define WS821X_ENABLE (0x100)
#define DMX_CHANNELS (0x101)
#define DMX_PIN (0x102)

#define data_addr r0
#define data_len r1
#define gpio0_zeros r2
#define gpio1_zeros r3
#define gpio3_zeros r4
#define bit_num r5
#define sleep_counter r6
// r8 - r24 are used for temp storage and bitmap processing


// Sleep a given number of nanoseconds with 10 ns resolution
.macro SLEEPNS
.mparam ns,inst,lab
    MOV sleep_counter, (ns/10)-1-inst
lab:
    SUB sleep_counter, sleep_counter, 1
    QBNE lab, sleep_counter, 0
.endm


START:
    // Enable OCP master port
    // clear the STANDBY_INIT bit in the SYSCFG register,
    // otherwise the PRU will not be able to write outside the
    // PRU memory space and to the BeagleBon's pins.
    LBCO	r0, C4, 4, 4
    CLR		r0, r0, 4
    SBCO	r0, C4, 4, 4

    // Configure the programmable pointer register for PRU0 by setting
    // c28_pointer[15:0] field to 0x0120.  This will make C28 point to
    // 0x00012000 (PRU shared RAM).
    MOV		r0, 0x00000120
    MOV		r1, CTPPR_0
    ST32	r0, r1

    // Configure the programmable pointer register for PRU0 by setting
    // c31_pointer[15:0] field to 0x0010.  This will make C31 point to
    // 0x80001000 (DDR memory).
    MOV		r0, 0x00100000
    MOV		r1, CTPPR_1
    ST32	r0, r1

    // Wait for the start condition from the main program to indicate
    // that we have a rendered frame ready to clock out.  This also
    // handles the exit case if an invalid value is written to the start
    // start position.
_LOOP:
    // Load the pointer to the buffer from PRU DRAM into r0 and the
    // length (in bytes-bit words) into r1.
    // start command into r2
    LBCO      data_addr, CONST_PRUDRAM, 0, 12

    // Wait for a non-zero command
    QBEQ _LOOP, r2, #0

    // Zero out the start command so that they know we have received it
    // This allows maximum speed frame drawing since they know that they
    // can now swap the frame buffer pointer and write a new start command.
    MOV r3, 0
    SBCO r3, CONST_PRUDRAM, 8, 4

    // Command of 0xFF is the signal to exit
    QBEQ EXIT, r2, #0xFF

WORD_LOOP:
	// for bit in 0 to 24:
	MOV bit_num, 0

	BIT_LOOP:
		// The idle period is 625 ns, but this is where
		// we do all of our work to read the RGB data and
		// repack it into bit slices.  So we subtract out
		// the approximate amount of time that these operations
		// take us.
		SLEEPNS (625 - 400), 1, idle_time
		MOV gpio0_zeros, 0

		// Load 16 registers of data, starting at r8
		LBBO r8, r0, 0, 64

		// For each of these 16 registers, set the
		// corresponding bit in the gpio0_zeros register
#define TEST_BIT(regN,gpioN,bitN) \
	QBBS gpioN##_##regN##_skip, regN, bit_num; \
	SET gpioN##_zeros, gpioN##_zeros, gpioN##_##bitN ; \
	gpioN##_##regN##_skip: \

		TEST_BIT(r8, gpio0, bit0)
		TEST_BIT(r9, gpio0, bit1)
		TEST_BIT(r10, gpio0, bit2)
		TEST_BIT(r11, gpio0, bit3)
		TEST_BIT(r12, gpio0, bit4)
		TEST_BIT(r13, gpio0, bit5)
		TEST_BIT(r14, gpio0, bit6)
		TEST_BIT(r15, gpio0, bit7)
		TEST_BIT(r16, gpio0, bit8)
		TEST_BIT(r17, gpio0, bit9)
		TEST_BIT(r18, gpio0, bit10)
		TEST_BIT(r19, gpio0, bit11)
		TEST_BIT(r20, gpio0, bit12)
		TEST_BIT(r21, gpio0, bit13)
		TEST_BIT(r22, gpio0, bit14)
		TEST_BIT(r23, gpio0, bit15)

		// Turn on all the start bits
		MOV r8, GPIO0 | GPIO_SETDATAOUT
		MOV r9, GPIO0_LED_MASK
		SBBO r9, r8, 0, 4

		// wait for the length of the zero bits (250 ns)
		SLEEPNS 250, 1, wait_zero_time

		// turn off all the zero bits
		MOV r8, GPIO0 | GPIO_CLEARDATAOUT
		SBBO gpio0_zeros, r8, 0, 4

		// Wait until the length of the one bits
		// (600 ns - 250 already waited)
		SLEEPNS 350, 1, wait_one_time

		// Turn all the bits off
		SBBO r9, r8, 0, 4

		ADD bit_num, bit_num, 1
		QBNE BIT_LOOP, bit_num, 24

	// The 32 RGB streams have been clocked out
	// Move to the next pixel on each row
	ADD data_addr, data_addr, 32 * 4
	SUB data_len, data_len, 1
	QBNE WORD_LOOP, data_len, #0

    // Delay at least 50 usec
    SLEEPNS 50000, 1, reset_time

    // Write out that we are done!
    // Store a non-zero response in the buffer so that they know that we are done
    // also write out a quick hack the last word we read
    MOV r2, #1
    SBCO r2, CONST_PRUDRAM, 12, 8

    // Go back to waiting for the next frame buffer
    QBA _LOOP

EXIT:
    // Write a 0xFF into the response field so that they know we're done
    MOV r2, #0xFF
    SBCO r2, CONST_PRUDRAM, 12, 4

#ifdef AM33XX
    // Send notification to Host for program completion
    MOV R31.b0, PRU0_ARM_INTERRUPT+16
#else
    MOV R31.b0, PRU0_ARM_INTERRUPT
#endif

    HALT