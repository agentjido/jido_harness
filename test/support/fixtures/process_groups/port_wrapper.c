#include <stdlib.h>
#include <unistd.h>

int main(int argc, char* argv[])
{
    (void)argc;
    const char* executable = getenv("ERLEXEC_TEST_PORT");
    const char* library = getenv("ERLEXEC_TEST_LIBRARY");
    const char* variable = getenv("ERLEXEC_TEST_LOADER");
    if (!executable || !library || !variable || setenv(variable, library, 1) < 0)
        return 127;
    argv[0] = (char*)executable;
    execv(executable, argv);
    return 127;
}
