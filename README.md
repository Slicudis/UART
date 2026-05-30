# Introduction
These modules were made in System Verilog for FPGA stuff. Beware of my cursed hardware.

# Transmitter

## Parameters
- ``CLK_FREQ``: Internal system clock speed.
- ``BAUD_RATE``: UART baud rate.

## Behaviour
A send request by the master is performed if ``i_send_req`` is 1 and if ``o_send_busy`` is 0 (otherwise it will be ignored). If the send request is succesful then the transmitter will take the data from ``i_send_data`` and transmit using ``o_tx`` as the UART TX channel.

# Receiver

## Parameters
- ``CLK_FREQ``: Internal system clock speed.
- ``BAUD_RATE``: UART baud rate.
- ``BADDRWIDTH``: Receiver FIFO size specified as an exponent (size = 2**BADDRWIDTH).
- ``SAMPLE_EXP``: Amount of samples taken per bit specified as an exponent (samples/bit = 2**SAMPLE_EXP)

## Behaviour

The master will be notified whether data has been received through the ``o_data_available`` pin (if 1, there is data available). To access the data stored in the FIFO, the master must send a 1 through ``i_read_req`` and wait until the next clock cycle, in which the least recent received data will be output through ``o_data``. \
It should be taken into account that FIFO overflows may cause undefined behaviour, so it is the master's responsibility to avoid them.
