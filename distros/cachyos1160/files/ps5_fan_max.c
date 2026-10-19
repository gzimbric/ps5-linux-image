/* SPDX-License-Identifier: 0BSD */

/*
 * Request the tested maximum PS5 fan servo pattern through the patched
 * kernel's /dev/icc ioctl interface.
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define ICC_FAN_CHANGE_SERVO_PATTERN _IOW('I', 1, uint8_t)
#define PS5_FAN_SERVO_PATTERN_MAXIMUM 3

_Static_assert(ICC_FAN_CHANGE_SERVO_PATTERN == 0x40014901UL,
               "unexpected PS5 ICC ioctl encoding");

int main(void)
{
    uint8_t pattern = PS5_FAN_SERVO_PATTERN_MAXIMUM;
    int fd = open("/dev/icc", O_RDWR);

    if (fd == -1) {
        perror("open /dev/icc");
        return EXIT_FAILURE;
    }
    if (ioctl(fd, ICC_FAN_CHANGE_SERVO_PATTERN, &pattern) == -1) {
        perror("ioctl ICC_FAN_CHANGE_SERVO_PATTERN");
        close(fd);
        return EXIT_FAILURE;
    }
    if (close(fd) == -1) {
        perror("close /dev/icc");
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}
