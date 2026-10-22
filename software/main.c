#include "xparameters.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xuartps_hw.h"
#include "sleep.h"
#include "xtime_l.h"

#include <stdint.h>

#include "gesture_sdk_params.h"
#include "gesture_stream_v4.h"

#define GESTURE_BASE XPAR_GESTURE_IP_0_BASEADDR

/* Change only this value when testing a different baud rate. */
#ifndef GESTURE_UART_BAUD
#define GESTURE_UART_BAUD 230400u
#endif

static int gesture_uart_init(void)
{
    const uint32_t base = XPAR_PS7_UART_0_BASEADDR;
    const uint32_t clock_hz = XPAR_PS7_UART_0_UART_CLK_FREQ_HZ;
    const uint32_t baud = GESTURE_UART_BAUD;
    uint32_t divider;
    uint32_t generator;
    uint32_t best_divider = 0u;
    uint32_t best_generator = 0u;
    uint32_t actual;
    uint32_t error;
    uint32_t best_error = UINT32_MAX;
    uint32_t retry;

    if (baud < 110u || baud > 921600u || clock_hz == 0u) {
        return -1;
    }

    /* MR.CLKSEL is cleared below: use the full UART reference clock. */
    for (divider = 4u; divider <= 254u; ++divider) {
        uint64_t denominator = (uint64_t)baud * (divider + 1u);
        generator = (uint32_t)(((uint64_t)clock_hz + denominator / 2u)
                              / denominator);
        if (generator == 0u || generator > 65535u) {
            continue;
        }
        actual = clock_hz / (generator * (divider + 1u));
        error = (actual > baud) ? actual - baud : baud - actual;
        if (error < best_error) {
            best_error = error;
            best_generator = generator;
            best_divider = divider;
        }
    }
    /* Use a 1% application acceptance limit, not a stability guarantee. */
    if (best_generator == 0u ||
        (uint64_t)best_error * 100u > (uint64_t)baud) {
        return -1;
    }

    /* Finish any preceding boot output before switching UART settings. */
    for (retry = 0u; retry < 1000000u; ++retry) {
        uint32_t uart_status = XUartPs_ReadReg(base, XUARTPS_SR_OFFSET);
        if ((uart_status & XUARTPS_SR_TXEMPTY) != 0u &&
            (uart_status & XUARTPS_SR_TACTIVE) == 0u) {
            break;
        }
    }
    if (retry == 1000000u) {
        return -1;
    }

    XUartPs_WriteReg(base, XUARTPS_IDR_OFFSET, XUARTPS_IXR_MASK);
    XUartPs_WriteReg(base, XUARTPS_CR_OFFSET,
                    XUARTPS_CR_TX_DIS | XUARTPS_CR_RX_DIS);
    /* Normal mode, full reference clock, 8 data bits, no parity, 1 stop. */
    XUartPs_WriteReg(base, XUARTPS_MR_OFFSET,
                    XUARTPS_MR_CHMODE_NORM | XUARTPS_MR_CHARLEN_8_BIT |
                    XUARTPS_MR_PARITY_NONE | XUARTPS_MR_STOPMODE_1_BIT);
    /* Disable hardware flow control; GST4 uses per-frame ACKs. */
    XUartPs_WriteReg(base, XUARTPS_MODEMCR_OFFSET, 0u);
    XUartPs_WriteReg(base, XUARTPS_BAUDGEN_OFFSET, best_generator);
    XUartPs_WriteReg(base, XUARTPS_BAUDDIV_OFFSET, best_divider);
    XUartPs_WriteReg(base, XUARTPS_CR_OFFSET,
                    XUARTPS_CR_TX_DIS | XUARTPS_CR_RX_DIS |
                    XUARTPS_CR_TXRST | XUARTPS_CR_RXRST);
    for (retry = 0u; retry < 1000000u; ++retry) {
        if ((XUartPs_ReadReg(base, XUARTPS_CR_OFFSET) &
             (XUARTPS_CR_TXRST | XUARTPS_CR_RXRST)) == 0u) {
            break;
        }
    }
    if (retry == 1000000u) {
        return -1;
    }
    XUartPs_WriteReg(base, XUARTPS_ISR_OFFSET, XUARTPS_IXR_MASK);
    XUartPs_WriteReg(base, XUARTPS_CR_OFFSET,
                    XUARTPS_CR_TX_EN | XUARTPS_CR_RX_EN);
    return 0;
}

/* AXI register offsets */
#define REG_CONTROL      0x00u
#define REG_STATUS       0x04u
#define REG_RESULT       0x08u
#define REG_FRAME_INDEX  0x0Cu
#define REG_COUNT_INDEX  0x10u
#define REG_COUNT_DATA   0x14u
#define REG_MEMBRANE_INDEX 0x18u
#define REG_MEMBRANE_DATA  0x1Cu

#define REG_LOAD_TARGET  0x20u
#define REG_LOAD_ADDR    0x24u

#define REG_DATA0        0x28u
#define REG_DATA1        0x2Cu
#define REG_DATA2        0x30u
#define REG_DATA3        0x34u
#define REG_DATA4        0x38u
#define REG_DATA5        0x3Cu
#define REG_DATA6        0x40u
#define REG_DATA7        0x44u

#define REG_COMMIT       0x48u
#define REG_VERSION      0x4Cu

/* CONTROL bits */
#define CTRL_START       (1u << 0)
#define CTRL_CLEAR       (1u << 1)
#define CTRL_SEQ_START   (1u << 2)
#define CTRL_SEQ_END     (1u << 3)

/* STATUS bits */
#define STATUS_BUSY          (1u << 2)
#define STATUS_FRAME_DONE    (1u << 3)
#define STATUS_ERROR         (1u << 4)
#define STATUS_SEQUENCE_DONE (1u << 5)
#define STATUS_RESULT_VALID  (1u << 6)
#define STATUS_LOAD_REJECT   (1u << 7)

/* LOAD_TARGET */
#define TARGET_FEATURE       0u
#define TARGET_CONV_WEIGHT   1u
#define TARGET_QUANT         2u
#define TARGET_DESC          3u
#define TARGET_LAYER_PARAM   4u
#define TARGET_FC_WEIGHT     5u
#define TARGET_FC_BIAS       6u

#define WAIT_STEP_US         100u
#define WAIT_TIMEOUT_LOOPS   1200000u

/* PC-to-board streaming protocol */
#define STREAM_MAGIC         0x34545347u
#define RESPONSE_MAGIC       0x34505352u
#define STREAM_VERSION       4u
#define EXPECTED_IP_VERSION  0x00040001u

#define STREAM_ENCODING_DENSE    0u
#define STREAM_ENCODING_ZERO_RLE 1u

#define STREAM_ACK            0x41u
#define STREAM_NAK            0x4Eu
#define STREAM_EARLY_ACK      0x45u

#define STREAM_STATUS_OK       0u
#define STREAM_STATUS_BAD_CRC  1u
#define STREAM_STATUS_HW_ERROR 2u
#define STREAM_STATUS_BAD_HEADER 3u
#define STREAM_STATUS_BAD_ENCODING 4u
#define STREAM_STATUS_BAD_LENGTH 5u
#define STREAM_STATUS_CAPACITY 6u
#define STREAM_STATUS_DECODE_ERROR 7u
#define STREAM_STATUS_BAD_COUNTS 8u

#define HWC16_LANES 16u
#define STREAM_FRAME_BUFFER_BYTES (2u * GESTURE_FEATURE_DEPTH_WORDS * HWC16_LANES)
#define STREAM_RX_TIMEOUT_SECONDS 10u

static uint8_t stream_frame_buffer[STREAM_FRAME_BUFFER_BYTES];

typedef struct {
    uint16_t version;
    uint16_t encoding;
    uint16_t width;
    uint16_t height;
    uint16_t channels;
    uint16_t time_steps;
    uint32_t sample_index;
    uint32_t payload_bytes;
    uint32_t early_stop;
    uint32_t header_crc;
    uint32_t channel_blocks;
    uint32_t feature_words_per_frame;
    uint32_t dense_bytes_per_frame;
} stream_header_t;

static uint32_t stream_processed_frames;
static uint16_t stream_counts[11];


static inline void reg_write(uint32_t offset, uint32_t value)
{
    Xil_Out32(GESTURE_BASE + offset, value);
}


static inline uint32_t reg_read(uint32_t offset)
{
    return Xil_In32(GESTURE_BASE + offset);
}


static uint32_t read_u32_le(const uint8_t *p)
{
    return ((uint32_t)p[0]) |
           ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) |
           ((uint32_t)p[3] << 24);
}


static uint64_t read_u64_le(const uint8_t *p)
{
    uint64_t low;
    uint64_t high;

    low = read_u32_le(p);
    high = read_u32_le(p + 4);

    return low | (high << 32);
}


static void write_data_register(uint32_t index, uint32_t value)
{
    reg_write(REG_DATA0 + index * 4u, value);
}


static void set_target_and_address(
    uint32_t target,
    uint32_t address
)
{
    reg_write(REG_LOAD_TARGET, target);
    reg_write(REG_LOAD_ADDR, address);
}


static void commit_write(void)
{
    reg_write(REG_COMMIT, 1u);
}


/* User-owned model data generated by gesture_data_blob.S */
extern const uint8_t gesture_conv_weights[];
extern const uint8_t gesture_fc_weights[];
extern const uint8_t gesture_layer_desc[];
extern const uint8_t gesture_layer_param[];


static int check_load_status(void)
{
    uint32_t status;

    status = reg_read(REG_STATUS);

    if (status & STATUS_LOAD_REJECT) {
        xil_printf("ERROR: hardware rejected a load\r\n");
        return -1;
    }

    if (status & STATUS_ERROR) {
        xil_printf("ERROR: hardware error during load\r\n");
        return -1;
    }

    return 0;
}


/* Load one 128-bit feature word */
static void load_feature_word(
    uint32_t address,
    const uint8_t *src
)
{
    set_target_and_address(
        TARGET_FEATURE,
        address
    );

    write_data_register(0, read_u32_le(src + 0));
    write_data_register(1, read_u32_le(src + 4));
    write_data_register(2, read_u32_le(src + 8));
    write_data_register(3, read_u32_le(src + 12));

    commit_write();
}


/* Load convolution weights */
static int load_conv_weights(void)
{
    uint32_t i;
    const uint8_t *src;

    xil_printf("Loading convolution weights...\r\n");

    src = gesture_conv_weights;

    for (i = 0; i < GESTURE_CONV_WORD_COUNT; ++i) {
        set_target_and_address(
            TARGET_CONV_WEIGHT,
            i
        );

        write_data_register(0, read_u32_le(src + 0));
        write_data_register(1, read_u32_le(src + 4));
        write_data_register(2, read_u32_le(src + 8));
        write_data_register(3, read_u32_le(src + 12));

        commit_write();

        src += 16;
    }

    return check_load_status();
}


/* Load quantization parameters */
static int load_quant_params(void)
{
    uint32_t i;

    xil_printf("Loading quantization parameters...\r\n");

    for (i = 0; i < GESTURE_QUANT_COUNT; ++i) {
        uint32_t packed;

        set_target_and_address(
            TARGET_QUANT,
            i
        );

        write_data_register(
            0,
            (uint32_t)gesture_quant_params[i].bias
        );

        packed =
            ((uint32_t)(uint16_t)
                gesture_quant_params[i].multiplier) |
            ((uint32_t)gesture_quant_params[i].shift << 16);

        write_data_register(1, packed);

        commit_write();
    }

    return check_load_status();
}


/* Load three layer descriptors */
static int load_layer_descriptors(void)
{
    uint32_t layer;
    uint32_t word;
    const uint8_t *src;

    xil_printf("Loading layer descriptors...\r\n");

    src = gesture_layer_desc;

    for (layer = 0;
         layer < GESTURE_LAYER_COUNT;
         ++layer) {

        set_target_and_address(
            TARGET_DESC,
            layer
        );

        for (word = 0; word < 8u; ++word) {
            write_data_register(
                word,
                read_u32_le(src + word * 4u)
            );
        }

        commit_write();

        src += 32;
    }

    return check_load_status();
}


/* Load three layer parameter records */
static int load_layer_params(void)
{
    uint32_t layer;
    uint32_t word;
    const uint8_t *src;

    xil_printf("Loading layer parameters...\r\n");

    src = gesture_layer_param;

    for (layer = 0;
         layer < GESTURE_LAYER_COUNT;
         ++layer) {

        set_target_and_address(
            TARGET_LAYER_PARAM,
            layer
        );

        for (word = 0; word < 3u; ++word) {
            write_data_register(
                word,
                read_u32_le(src + word * 4u)
            );
        }

        commit_write();

        src += 12;
    }

    return check_load_status();
}


/* Load FC weights */
static int load_fc_weights(void)
{
    uint32_t class_index;
    uint32_t word_index;
    const uint8_t *src;

    xil_printf("Loading FC weights...\r\n");

    src = gesture_fc_weights;

    for (class_index = 0;
         class_index < GESTURE_FC_CLASS_COUNT;
         ++class_index) {

        for (word_index = 0;
             word_index < 8u;
             ++word_index) {

            uint32_t load_address;
            uint64_t value;

            load_address =
                (class_index & 0x0Fu) |
                ((word_index & 0x07u) << 16);

            value = read_u64_le(
                src + (class_index * 8u + word_index) * 8u
            );

            set_target_and_address(
                TARGET_FC_WEIGHT,
                load_address
            );

            write_data_register(
                0,
                (uint32_t)value
            );

            write_data_register(
                1,
                (uint32_t)(value >> 32)
            );

            commit_write();
        }
    }

    return check_load_status();
}


/* Load FC biases */
static int load_fc_bias(void)
{
    uint32_t class_index;

    xil_printf("Loading FC biases...\r\n");

    for (class_index = 0;
         class_index < GESTURE_FC_CLASS_COUNT;
         ++class_index) {

        set_target_and_address(
            TARGET_FC_BIAS,
            class_index
        );

        write_data_register(
            0,
            (uint32_t)gesture_fc_bias[class_index]
        );

        commit_write();
    }

    return check_load_status();
}


/* Wait for an AXI status bit */
static int wait_status(
    uint32_t mask,
    uint32_t expected
)
{
    uint32_t i;

    for (i = 0;
         i < WAIT_TIMEOUT_LOOPS;
         ++i) {

        uint32_t status;

        status = reg_read(REG_STATUS);

        if (status & STATUS_ERROR) {
            xil_printf(
                "ERROR: hardware status=0x%08x\r\n",
                status
            );
            return -1;
        }

        if ((status & mask) == expected) {
            return 0;
        }

        usleep(WAIT_STEP_US);
    }

    xil_printf(
        "ERROR: timeout, status=0x%08x\r\n",
        reg_read(REG_STATUS)
    );

    return -1;
}


/* Start and wait for one frame */
static int run_one_frame(uint32_t frame_index)
{
    uint32_t control_value;

    control_value = CTRL_START;

    if (frame_index == 0u) {
        control_value |= CTRL_SEQ_START;
    }

    if (frame_index == GESTURE_FRAME_COUNT - 1u) {
        control_value |= CTRL_SEQ_END;
    }

    reg_write(
        REG_FRAME_INDEX,
        frame_index
    );

    reg_write(
        REG_CONTROL,
        control_value
    );

    return wait_status(
        STATUS_FRAME_DONE,
        STATUS_FRAME_DONE
    );
}


/* UART receive one byte */
static uint8_t uart_recv_byte_blocking(void)
{
    return XUartPs_RecvByte(STDIN_BASEADDRESS);
}


/* UART send one byte */
static void uart_send_byte(uint8_t value)
{
    XUartPs_SendByte(
        STDOUT_BASEADDRESS,
        value
    );
}


/* UART receive little-endian uint32 */
static uint32_t uart_recv_u32_le(void)
{
    uint32_t value;
    uint32_t i;

    value = 0;

    for (i = 0; i < 4u; ++i) {
        value |=
            ((uint32_t)uart_recv_byte_blocking())
            << (8u * i);
    }

    return value;
}


/* UART receive little-endian uint16 */
static uint16_t uart_recv_u16_le(void)
{
    uint16_t value;

    value = (uint16_t)uart_recv_byte_blocking();
    value |= (uint16_t)uart_recv_byte_blocking() << 8;

    return value;
}


/* Receive a bounded frame before AXI writes, with a no-progress timeout. */
static int uart_receive_frame(uint32_t length)
{
    uint32_t position = 0u;
    XTime last_progress;
    XTime now;

    XTime_GetTime(&last_progress);
    while (position < length) {
        if (XUartPs_IsReceiveData(STDIN_BASEADDRESS)) {
            stream_frame_buffer[position++] =
                (uint8_t)XUartPs_ReadReg(STDIN_BASEADDRESS, XUARTPS_FIFO_OFFSET);
            XTime_GetTime(&last_progress);
        } else {
            XTime_GetTime(&now);
            if (now - last_progress >
                (XTime)COUNTS_PER_SECOND * STREAM_RX_TIMEOUT_SECONDS) {
                return -1;
            }
        }
    }
    return 0;
}


/*
 * Read and validate the fixed GST4 header after STREAM_MAGIC.  The current
 * bitstream describes one model, so dimensions must match the loaded model.
 * The protocol remains generic: a future model only changes generated limits.
 */
static uint32_t receive_stream_header(stream_header_t *header)
{
    uint64_t feature_words;
    uint64_t dense_bytes;
    uint64_t maximum_payload_bytes;
    uint32_t crc = 0xFFFFFFFFu;

    header->version = uart_recv_u16_le();
    header->encoding = uart_recv_u16_le();
    header->width = uart_recv_u16_le();
    header->height = uart_recv_u16_le();
    header->channels = uart_recv_u16_le();
    header->time_steps = uart_recv_u16_le();
    header->sample_index = uart_recv_u32_le();
    header->payload_bytes = uart_recv_u32_le();
    header->early_stop = uart_recv_u32_le();
    header->header_crc = uart_recv_u32_le();

    crc = stream_crc_u32(crc, STREAM_MAGIC);
    crc = stream_crc_u16(crc, header->version);
    crc = stream_crc_u16(crc, header->encoding);
    crc = stream_crc_u16(crc, header->width);
    crc = stream_crc_u16(crc, header->height);
    crc = stream_crc_u16(crc, header->channels);
    crc = stream_crc_u16(crc, header->time_steps);
    crc = stream_crc_u32(crc, header->sample_index);
    crc = stream_crc_u32(crc, header->payload_bytes);
    crc = stream_crc_u32(crc, header->early_stop);
    if ((crc ^ 0xFFFFFFFFu) != header->header_crc) {
        return STREAM_STATUS_BAD_CRC;
    }

    if (header->version != STREAM_VERSION ||
        header->width == 0u ||
        header->height == 0u ||
        header->channels == 0u ||
        header->time_steps == 0u || header->early_stop > 1u) {
        return STREAM_STATUS_BAD_HEADER;
    }

    if (header->encoding != STREAM_ENCODING_DENSE &&
        header->encoding != STREAM_ENCODING_ZERO_RLE) {
        return STREAM_STATUS_BAD_ENCODING;
    }

    /* The loaded descriptors and weights are specific to these dimensions. */
    if (header->width != GESTURE_INPUT_WIDTH ||
        header->height != GESTURE_INPUT_HEIGHT ||
        header->channels != GESTURE_INPUT_CHANNELS ||
        header->time_steps != GESTURE_FRAME_COUNT) {
        return STREAM_STATUS_BAD_HEADER;
    }

    header->channel_blocks =
        ((uint32_t)header->channels + HWC16_LANES - 1u) /
        HWC16_LANES;

    feature_words =
        (uint64_t)header->width *
        (uint64_t)header->height *
        (uint64_t)header->channel_blocks;

    dense_bytes =
        (uint64_t)header->width *
        (uint64_t)header->height *
        (uint64_t)header->channels;

    if (feature_words > GESTURE_FEATURE_DEPTH_WORDS ||
        feature_words > 0xFFFFFFFFu ||
        dense_bytes > 0xFFFFFFFFu) {
        return STREAM_STATUS_CAPACITY;
    }

    header->feature_words_per_frame = (uint32_t)feature_words;
    header->dense_bytes_per_frame = (uint32_t)dense_bytes;

    maximum_payload_bytes =
        dense_bytes * (uint64_t)header->time_steps * 2u;

    if (header->payload_bytes == 0u ||
        (uint64_t)header->payload_bytes > maximum_payload_bytes) {
        return STREAM_STATUS_BAD_LENGTH;
    }

    if (header->encoding == STREAM_ENCODING_DENSE &&
        (uint64_t)header->payload_bytes !=
            dense_bytes * (uint64_t)header->time_steps) {
        return STREAM_STATUS_BAD_LENGTH;
    }

    return STREAM_STATUS_OK;
}


/* UART send little-endian uint16 */
static void uart_send_u16_le(uint16_t value)
{
    uart_send_byte((uint8_t)(value & 0xFFu));
    uart_send_byte((uint8_t)((value >> 8) & 0xFFu));
}


/* UART send little-endian uint32 */
static void uart_send_u32_le(uint32_t value)
{
    uart_send_byte((uint8_t)(value & 0xFFu));
    uart_send_byte((uint8_t)((value >> 8) & 0xFFu));
    uart_send_byte((uint8_t)((value >> 16) & 0xFFu));
    uart_send_byte((uint8_t)((value >> 24) & 0xFFu));
}


/* Send one sample result to the PC */
static void send_stream_response(
    uint32_t sample_index,
    uint32_t predicted_class,
    uint32_t status,
    uint32_t reason
)
{
    uint32_t class_index;
    uint32_t count;
    uint32_t membrane;
    uint32_t crc = 0xFFFFFFFFu;

    crc = stream_crc_u32(crc, RESPONSE_MAGIC);
    crc = stream_crc_u32(crc, sample_index);
    crc = stream_crc_u32(crc, predicted_class);
    crc = stream_crc_u32(crc, status);
    crc = stream_crc_u32(crc, stream_processed_frames);
    crc = stream_crc_u32(crc, reason);

    uart_send_u32_le(RESPONSE_MAGIC);
    uart_send_u32_le(sample_index);
    uart_send_u32_le(predicted_class);
    uart_send_u32_le(status);
    uart_send_u32_le(stream_processed_frames);
    uart_send_u32_le(reason);

    for (class_index = 0;
         class_index < GESTURE_FC_CLASS_COUNT;
         ++class_index) {

        reg_write(
            REG_COUNT_INDEX,
            class_index
        );

        count =
            reg_read(REG_COUNT_DATA) &
            0xFFFFu;

        uart_send_u16_le((uint16_t)count);
        crc = stream_crc_u16(crc, (uint16_t)count);
    }
    for (class_index = 0;
         class_index < GESTURE_FC_CLASS_COUNT;
         ++class_index) {

        reg_write(
            REG_MEMBRANE_INDEX,
            class_index
        );

        membrane = reg_read(REG_MEMBRANE_DATA);
        uart_send_u32_le(membrane);
        crc = stream_crc_u32(crc, membrane);
    }
    uart_send_u32_le(crc ^ 0xFFFFFFFFu);
}


static void store_stream_value(
    const stream_header_t *header,
    uint32_t decoded_index,
    uint8_t value,
    uint8_t *feature_word,
    uint32_t *feature_address
)
{
    uint32_t channel;
    uint32_t lane;

    channel = decoded_index % header->channels;
    lane = channel & (HWC16_LANES - 1u);
    feature_word[lane] = value;

    if (lane == HWC16_LANES - 1u ||
        channel == (uint32_t)header->channels - 1u) {
        load_feature_word(*feature_address, feature_word);
        ++(*feature_address);

        for (lane = 0u; lane < HWC16_LANES; ++lane) {
            feature_word[lane] = 0u;
        }
    }
}


/* Decode one compact frame directly into the accelerator's HWC16 buffer. */
static uint32_t receive_and_load_frame(
    const stream_header_t *header,
    uint32_t encoded_bytes
)
{
    uint8_t feature_word[HWC16_LANES];
    uint32_t feature_address;
    uint32_t decoded_bytes;
    uint32_t consumed_bytes;
    uint32_t i;

    feature_address = 0u;
    decoded_bytes = 0u;
    consumed_bytes = 0u;

    for (i = 0u; i < HWC16_LANES; ++i) {
        feature_word[i] = 0u;
    }

    if (header->encoding == STREAM_ENCODING_DENSE) {
        if (encoded_bytes != header->dense_bytes_per_frame) {
            return STREAM_STATUS_BAD_LENGTH;
        }

        while (consumed_bytes < encoded_bytes) {
            uint8_t value;

            value = stream_frame_buffer[consumed_bytes];
            ++consumed_bytes;
            store_stream_value(
                header,
                decoded_bytes,
                value,
                feature_word,
                &feature_address
            );
            ++decoded_bytes;
        }
    }
    else {
        while (consumed_bytes < encoded_bytes &&
               decoded_bytes < header->dense_bytes_per_frame) {
            uint8_t command;
            uint32_t run_length;
            uint32_t run_index;

            command = stream_frame_buffer[consumed_bytes];
            ++consumed_bytes;
            run_length = ((uint32_t)command & 0x7Fu) + 1u;

            if (run_length >
                header->dense_bytes_per_frame - decoded_bytes) {
                return STREAM_STATUS_DECODE_ERROR;
            }

            if ((command & 0x80u) != 0u) {
                if (run_length > encoded_bytes - consumed_bytes) {
                    return STREAM_STATUS_DECODE_ERROR;
                }

                for (run_index = 0u;
                     run_index < run_length;
                     ++run_index) {
                    uint8_t value;

                    value = stream_frame_buffer[consumed_bytes];
                    ++consumed_bytes;
                    store_stream_value(
                        header,
                        decoded_bytes,
                        value,
                        feature_word,
                        &feature_address
                    );
                    ++decoded_bytes;
                }
            }
            else {
                for (run_index = 0u;
                     run_index < run_length;
                     ++run_index) {
                    store_stream_value(
                        header,
                        decoded_bytes,
                        0u,
                        feature_word,
                        &feature_address
                    );
                    ++decoded_bytes;
                }
            }
        }
    }

    if (consumed_bytes != encoded_bytes ||
        decoded_bytes != header->dense_bytes_per_frame ||
        feature_address != header->feature_words_per_frame) {
        return STREAM_STATUS_DECODE_ERROR;
    }

    return check_load_status() == 0
        ? STREAM_STATUS_OK
        : STREAM_STATUS_HW_ERROR;
}


/* Receive a dimension-described GST4 sample; stop only on a proven winner. */
static uint32_t process_stream_sample(
    const stream_header_t *header
)
{
	uint32_t frame;
	uint32_t received_payload_bytes;
	uint32_t status;
	uint32_t previous_winner;
	uint32_t winner_streak;

	received_payload_bytes = 0u;
	previous_winner = 0xFFFFFFFFu;
	winner_streak = 0u;

	reg_write(
        REG_CONTROL,
        CTRL_CLEAR
    );

    usleep(1000);

    for (frame = 0;
         frame < header->time_steps;
         ++frame) {
        uint32_t encoded_bytes;
        uint32_t expected_crc;
        uint32_t crc;
        uint32_t byte_index;
        uint32_t winner;
        uint32_t class_index;
        int decision;

        encoded_bytes = uart_recv_u32_le();
        expected_crc = uart_recv_u32_le();

        if (encoded_bytes == 0u ||
            encoded_bytes > header->payload_bytes - received_payload_bytes ||
            encoded_bytes > STREAM_FRAME_BUFFER_BYTES ||
            encoded_bytes > 2u * header->dense_bytes_per_frame) {
            uart_send_byte(STREAM_NAK);
            return STREAM_STATUS_BAD_LENGTH;
        }

        /* Sender waits for length approval before sending this frame. */
        uart_send_byte(STREAM_ACK);
        if (uart_receive_frame(encoded_bytes) != 0) {
            uart_send_byte(STREAM_NAK);
            return STREAM_STATUS_BAD_LENGTH;
        }
        received_payload_bytes += encoded_bytes;
        crc = stream_crc_u32(0xFFFFFFFFu, header->sample_index);
        crc = stream_crc_u32(crc, frame);
        crc = stream_crc_u32(crc, encoded_bytes);
        for (byte_index = 0u; byte_index < encoded_bytes; ++byte_index) {
            crc = stream_crc_byte(crc, stream_frame_buffer[byte_index]);
        }
        if ((crc ^ 0xFFFFFFFFu) != expected_crc) {
            uart_send_byte(STREAM_NAK);
            return STREAM_STATUS_BAD_CRC;
        }
        status = receive_and_load_frame(
            header,
            encoded_bytes
        );

        if (status != STREAM_STATUS_OK) {
            uart_send_byte(STREAM_NAK);
            return status;
        }

        if (run_one_frame(frame) != 0) {
            uart_send_byte(STREAM_NAK);
            return STREAM_STATUS_HW_ERROR;
        }

        stream_processed_frames = frame + 1u;
        for (class_index = 0u; class_index < 11u; ++class_index) {
            reg_write(REG_COUNT_INDEX, class_index);
            stream_counts[class_index] = (uint16_t)(reg_read(REG_COUNT_DATA) & 0xFFFFu);
        }
        decision = stream_early_decision(
            stream_counts,
            stream_processed_frames,
            header->time_steps,
            &previous_winner,
            &winner_streak,
            &winner
        );
        if (decision < 0) {
            uart_send_byte(STREAM_NAK);
            return STREAM_STATUS_BAD_COUNTS;
        }
        if (header->early_stop == 1u && decision == 1 &&
            stream_processed_frames < header->time_steps) {
            /* Do not await final RTL result: sequence_end was not requested. */
            uart_send_byte(STREAM_EARLY_ACK);
            send_stream_response(header->sample_index, winner, STREAM_STATUS_OK, 1u);
            return STREAM_STATUS_OK;
        }

        uart_send_byte(STREAM_ACK);
    }

    if (received_payload_bytes != header->payload_bytes) {
        return STREAM_STATUS_BAD_LENGTH;
    }

    if (wait_status(
            STATUS_SEQUENCE_DONE,
            STATUS_SEQUENCE_DONE
        ) != 0) {
        return STREAM_STATUS_HW_ERROR;
    }

    if (wait_status(
            STATUS_RESULT_VALID,
            STATUS_RESULT_VALID
        ) != 0) {
        return STREAM_STATUS_HW_ERROR;
    }

    send_stream_response(
        header->sample_index,
        reg_read(REG_RESULT) & 0x0Fu,
        STREAM_STATUS_OK,
        0u
    );

    return STREAM_STATUS_OK;
}


int main(void)
{
    uint32_t magic;
    uint32_t status;
    uint32_t version;
    stream_header_t header;

    if (gesture_uart_init() != 0) {
        /* UART settings are not trusted; inspect with the SDK debugger. */
        return -1;
    }
    xil_printf("UART target baud = %u\r\n", GESTURE_UART_BAUD);
    xil_printf("UART BRGR = %u, BDIV = %u\r\n",
               XUartPs_ReadReg(STDIN_BASEADDRESS, XUARTPS_BAUDGEN_OFFSET),
               XUartPs_ReadReg(STDIN_BASEADDRESS, XUARTPS_BAUDDIV_OFFSET));
    xil_printf("\r\n");
    xil_printf("Gesture CNN + LIF GST4 membrane capture test\r\n");

    version = reg_read(REG_VERSION);

    xil_printf(
        "Gesture IP version = 0x%08x\r\n",
        version
    );
    if (version != EXPECTED_IP_VERSION) {
        xil_printf(
            "IP version mismatch: expected 0x%08x\r\n",
            EXPECTED_IP_VERSION
        );
        return -1;
    }

    reg_write(
        REG_CONTROL,
        CTRL_CLEAR
    );

    usleep(1000);

    if (load_layer_descriptors() != 0) {
        xil_printf("Descriptor loading failed\r\n");
        return -1;
    }

    if (load_layer_params() != 0) {
        xil_printf("Layer parameter loading failed\r\n");
        return -1;
    }

    if (load_quant_params() != 0) {
        xil_printf("Quantization loading failed\r\n");
        return -1;
    }

    if (load_conv_weights() != 0) {
        xil_printf("Convolution weight loading failed\r\n");
        return -1;
    }

    if (load_fc_weights() != 0) {
        xil_printf("FC weight loading failed\r\n");
        return -1;
    }

    if (load_fc_bias() != 0) {
        xil_printf("FC bias loading failed\r\n");
        return -1;
    }

    xil_printf("MODEL_READY\r\n");
    xil_printf("Waiting for test samples...\r\n");

    while (1) {
        stream_processed_frames = 0u;
        magic = uart_recv_u32_le();

        if (magic != STREAM_MAGIC) {
            uart_send_byte(STREAM_NAK);
            continue;
        }

        status = receive_stream_header(&header);

        if (status == STREAM_STATUS_OK) {
            /* The PC sends frame payloads only after this header ACK. */
            uart_send_byte(STREAM_ACK);
            status = process_stream_sample(&header);
        }
        else {
            /* Sender is waiting for ACK and has not sent any frame yet. */
            uart_send_byte(STREAM_NAK);
        }

        if (status != STREAM_STATUS_OK) {
            send_stream_response(
                header.sample_index,
                0xFFFFFFFFu,
                status,
                2u
            );
        }
    }

    return 0;
}
