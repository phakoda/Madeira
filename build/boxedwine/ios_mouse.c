// Software cursors and coordinate conversion for the pinned SDL UIKit backend.
#include "SDL_internal.h"
#include "ios_mouse.h"
#include <math.h>
#include "events/SDL_mouse_c.h"
#include "render/SDL_sysrender.h"

typedef struct {
    SDL_Surface* surface;
    int hot_x, hot_y;
} MadeiraCursor;

static SDL_Renderer* renderer;
static SDL_Window* window;
static SDL_Cursor* visible_cursor;
static SDL_Texture* texture;
static int dirty;

static void clear_texture(void) {
    if (texture) SDL_DestroyTexture(texture);
    texture = NULL;
}

static SDL_Cursor* create_cursor(SDL_Surface* surface, int x, int y) {
    SDL_Cursor* cursor = SDL_calloc(1, sizeof(*cursor));
    MadeiraCursor* data = SDL_calloc(1, sizeof(*data));
    if (!cursor || !data) { SDL_free(cursor); SDL_free(data); return NULL; }
    data->surface = SDL_ConvertSurfaceFormat(surface, SDL_PIXELFORMAT_ARGB8888, 0);
    if (!data->surface) { SDL_free(cursor); SDL_free(data); return NULL; }
    data->hot_x = x;
    data->hot_y = y;
    cursor->driverdata = data;
    return cursor;
}

static SDL_Cursor* system_cursor(SDL_SystemCursor id) {
    static const char* arrow[] = {
        "X               ", "XX              ", "X.X             ", "X..X            ",
        "X...X           ", "X....X          ", "X.....X         ", "X......X        ",
        "X.......X       ", "X........X      ", "X.........X     ", "X..........X    ",
        "X......XXXXX    ", "X...X..X        ", "X..XX..X        ", "X.X  X..X       ",
        "XX   X..X       ", "X     X..X      ", "      X..X      ", "       XX       "
    };
    SDL_Surface* surface = SDL_CreateRGBSurfaceWithFormat(0, 16, 20, 32, SDL_PIXELFORMAT_ARGB8888);
    SDL_Cursor* result;
    int x, y;
    if (!surface) return NULL;
    SDL_FillRect(surface, NULL, 0);
    for (y = 0; y < 20; ++y) {
        Uint32* row = (Uint32*)((Uint8*)surface->pixels + y * surface->pitch);
        for (x = 0; x < 16; ++x) {
            if (id == SDL_SYSTEM_CURSOR_CROSSHAIR || id == SDL_SYSTEM_CURSOR_IBEAM) {
                if (x == 7 || (id == SDL_SYSTEM_CURSOR_CROSSHAIR ? y == 9 : (y == 0 || y == 19))) row[x] = 0xffffffff;
                else if (x == 6 || x == 8) row[x] = 0xff000000;
            } else if (arrow[y][x] != ' ') row[x] = arrow[y][x] == 'X' ? 0xff000000 : 0xffffffff;
        }
    }
    result = create_cursor(surface, id == SDL_SYSTEM_CURSOR_CROSSHAIR ? 7 : 0,
                           id == SDL_SYSTEM_CURSOR_CROSSHAIR ? 9 : 0);
    SDL_FreeSurface(surface);
    return result;
}

static int show_cursor(SDL_Cursor* cursor) {
    if (visible_cursor != cursor) clear_texture();
    visible_cursor = cursor;
    dirty = 1;
    return 0;
}

static void free_cursor(SDL_Cursor* cursor) {
    MadeiraCursor* data = cursor->driverdata;
    if (visible_cursor == cursor) show_cursor(NULL);
    SDL_FreeSurface(data->surface);
    SDL_free(data);
    SDL_free(cursor);
}

static void warp_in_view(SDL_Window* target, int x, int y) {
    SDL_SendMouseMotion(target, SDL_GetMouse()->mouseID, 0, x, y);
}

static void move_cursor(SDL_Cursor* cursor) { (void)cursor; dirty = 1; }

int madeiraWine32MouseChanged(void) {
    int changed = dirty;
    dirty = 0;
    return changed;
}

void madeiraWine32MouseRenderer(SDL_Renderer* target, SDL_Window* target_window) {
    SDL_Mouse* mouse = SDL_GetMouse();
    clear_texture();
    renderer = target;
    window = target_window;
    if (mouse->CreateCursor != create_cursor) {
        mouse->CreateCursor = create_cursor;
        mouse->CreateSystemCursor = system_cursor;
        mouse->ShowCursor = show_cursor;
        mouse->MoveCursor = move_cursor;
        mouse->FreeCursor = free_cursor;
        mouse->WarpMouse = warp_in_view;
        SDL_SetDefaultCursor(system_cursor(SDL_SYSTEM_CURSOR_ARROW));
    }
}

void madeiraWine32MouseClearRenderer(void) {
    clear_texture();
    renderer = NULL;
    window = NULL;
    dirty = 0;
}

void madeiraWine32MousePosition(int* x, int* y) {
    SDL_GetMouseState(x, y);
    if (renderer && renderer->logical_w) {
        *x = (int)((*x - renderer->viewport.x * renderer->dpi_scale.x) /
                   (renderer->scale.x * renderer->dpi_scale.x));
        *y = (int)((*y - renderer->viewport.y * renderer->dpi_scale.y) /
                   (renderer->scale.y * renderer->dpi_scale.y));
        *x = SDL_max(0, SDL_min(*x, renderer->logical_w - 1));
        *y = SDL_max(0, SDL_min(*y, renderer->logical_h - 1));
    }
}

void madeiraWine32MouseWarp(int x, int y) {
    if (!renderer || !window) return;
    if (renderer->logical_w) {
        x = (int)lroundf((x * renderer->scale.x + renderer->viewport.x) * renderer->dpi_scale.x);
        y = (int)lroundf((y * renderer->scale.y + renderer->viewport.y) * renderer->dpi_scale.y);
    }
    SDL_WarpMouseInWindow(window, x, y);
}

void madeira_wine32_pointer(float x, float y, int button, int down) {
    int width, height;
    if (!window || !isfinite(x) || !isfinite(y)) return;
    SDL_GetWindowSize(window, &width, &height);
    SDL_SendMouseMotion(window, SDL_GetMouse()->mouseID, 0,
        (int)(fminf(fmaxf(x, 0.0f), 1.0f) * (width - 1)),
        (int)(fminf(fmaxf(y, 0.0f), 1.0f) * (height - 1)));
    if ((button == SDL_BUTTON_LEFT || button == SDL_BUTTON_RIGHT) && (down == 0 || down == 1))
        SDL_SendMouseButton(window, SDL_GetMouse()->mouseID, down ? SDL_PRESSED : SDL_RELEASED, button);
}

void madeiraWine32MouseDraw(void) {
    MadeiraCursor* data;
    SDL_Rect dest;
    float magnification;
    int x, y;
    if (!renderer || !visible_cursor) return;
    data = visible_cursor->driverdata;
    if (!texture) {
        texture = SDL_CreateTextureFromSurface(renderer, data->surface);
        if (!texture) return;
        SDL_SetTextureBlendMode(texture, SDL_BLENDMODE_BLEND);
    }
    madeiraWine32MousePosition(&x, &y);
    // Keep the pointer legible when a large desktop is fitted to a phone.
    magnification = SDL_max(1.0f, 24.0f / (data->surface->h * renderer->scale.y * renderer->dpi_scale.y));
    dest.x = x - (int)(data->hot_x * magnification);
    dest.y = y - (int)(data->hot_y * magnification);
    dest.w = (int)(data->surface->w * magnification);
    dest.h = (int)(data->surface->h * magnification);
    SDL_RenderCopy(renderer, texture, NULL, &dest);
}
