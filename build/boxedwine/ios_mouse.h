#ifndef MADEIRA_IOS_MOUSE_H
#define MADEIRA_IOS_MOUSE_H
#include <SDL.h>
#ifdef __cplusplus
extern "C" {
#endif
void madeiraWine32MouseRenderer(SDL_Renderer*, SDL_Window*);
void madeiraWine32MouseClearRenderer(void);
void madeiraWine32MouseDraw(void);
int madeiraWine32MouseChanged(void);
void madeiraWine32MousePosition(int* x, int* y);
void madeiraWine32MouseWarp(int x, int y);
// Normalized UIKit view coordinates; down=-1 moves without changing buttons.
void madeira_wine32_pointer(float x, float y, int button, int down);
#ifdef __cplusplus
}
#endif
#endif
