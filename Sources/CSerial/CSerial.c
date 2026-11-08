#include "CSerial.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

int orion_serial_open(const char *path) {
    int fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return -1;
    if (ioctl(fd, TIOCEXCL) < 0) { int e = errno; close(fd); errno = e; return -1; }
    return fd;
}
int orion_serial_configure(int fd, int require_rts) {
    struct termios t;
    if (tcgetattr(fd, &t) < 0) return -1;
    cfmakeraw(&t);
    t.c_cflag &= ~(CSIZE | CSTOPB | PARODD | CRTSCTS);
    t.c_cflag |= CS8 | CLOCAL | CREAD | PARENB | HUPCL;
    t.c_iflag = INPCK;
    t.c_oflag = 0;
    t.c_lflag = 0;
    t.c_cc[VMIN] = 0;
    t.c_cc[VTIME] = 0;
    if (cfsetispeed(&t, B9600) < 0 || cfsetospeed(&t, B9600) < 0) return -1;
    if (tcsetattr(fd, TCSANOW, &t) < 0) return -1;
    if (tcflush(fd, TCIOFLUSH) < 0) return -1;
    if (require_rts) {
        int bits = TIOCM_RTS;
        if (ioctl(fd, TIOCMBIS, &bits) < 0) return -1;
    }
    return 0;
}
int orion_serial_close(int fd) {
    int bits = TIOCM_RTS;
    ioctl(fd, TIOCMBIC, &bits);
    ioctl(fd, TIOCNXCL);
    return close(fd);
}
int orion_serial_wait(int fd, int writing, int milliseconds) {
    struct pollfd p = { .fd = fd, .events = writing ? POLLOUT : POLLIN };
    int r = poll(&p, 1, milliseconds);
    if (r <= 0) return r;
    if (p.revents & (POLLERR | POLLHUP | POLLNVAL)) { errno = ENXIO; return -1; }
    return (p.revents & p.events) ? 1 : 0;
}
ptrdiff_t orion_serial_read(int fd, uint8_t *buffer, size_t size) { return read(fd, buffer, size); }
ptrdiff_t orion_serial_write(int fd, const uint8_t *buffer, size_t size) { return write(fd, buffer, size); }
int orion_serial_flush(int fd) { return tcflush(fd, TCIFLUSH); }
