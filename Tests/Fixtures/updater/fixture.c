#include <signal.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--hold") == 0) {
        for (;;) pause();
    }
    return 0;
}
