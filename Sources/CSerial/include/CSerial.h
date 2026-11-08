#ifndef ORION_CSERIAL_H
#define ORION_CSERIAL_H
#include <stddef.h>
#include <stdint.h>
// Functions return -1 on error and leave errno intact.
int orion_serial_open(const char *path);
int orion_serial_configure(int fd, int require_rts);
int orion_serial_close(int fd);
int orion_serial_wait(int fd, int writing, int milliseconds);
ptrdiff_t orion_serial_read(int fd, uint8_t *buffer, size_t size);
ptrdiff_t orion_serial_write(int fd, const uint8_t *buffer, size_t size);
int orion_serial_flush(int fd);
#endif
