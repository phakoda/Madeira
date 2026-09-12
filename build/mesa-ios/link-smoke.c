#include <GL/osmesa.h>
#include <GL/gl.h>
#include <stddef.h>

/* Link the completed static archive, rather than just checking its filename.
 * This can also be called by a Simulator/device test host to verify rendering. */
int main(void)
{
    unsigned char pixels[4 * 4 * 4] = {0};
    OSMesaContext context = OSMesaCreateContextExt(OSMESA_RGBA, 24, 8, 0, NULL);
    if (!context) return 1;
    if (!OSMesaMakeCurrent(context, pixels, GL_UNSIGNED_BYTE, 4, 4)) {
        OSMesaDestroyContext(context);
        return 2;
    }
    glClearColor(1.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glFinish();
    int failed = pixels[0] != 255 || pixels[1] != 0 || pixels[2] != 0 || pixels[3] != 255;
    OSMesaDestroyContext(context);
    return failed;
}
