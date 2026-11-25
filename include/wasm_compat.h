#include <assert.h>
#include <time.h>

#if defined(__wasi__) && !defined(__cplusplus)
int getentropy(void *buffer, size_t length);
#endif
