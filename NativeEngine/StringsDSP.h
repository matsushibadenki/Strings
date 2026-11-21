#ifndef STRINGS_DSP_H
#define STRINGS_DSP_H

#include <stdbool.h>
#include <stdint.h>

typedef struct StringsDSP StringsDSP;

StringsDSP * _Nonnull strings_dsp_create(double sample_rate);
void strings_dsp_destroy(StringsDSP * _Nonnull strings);
void strings_dsp_note_on(StringsDSP * _Nonnull strings, uint32_t note, float velocity, bool pizzicato);
void strings_dsp_note_off(StringsDSP * _Nonnull strings, uint32_t note);
void strings_dsp_sustain(StringsDSP * _Nonnull strings, float position);
void strings_dsp_all_off(StringsDSP * _Nonnull strings);
void strings_dsp_set_spiccato(StringsDSP * _Nonnull strings, bool enabled);
void strings_dsp_set_legato(StringsDSP * _Nonnull strings, bool enabled);
void strings_dsp_set_bow_position(StringsDSP * _Nonnull strings, float position);
void strings_dsp_set_brightness(StringsDSP * _Nonnull strings, float amount);
void strings_dsp_set_expression(StringsDSP * _Nonnull strings, float amount);
void strings_dsp_set_reverb(StringsDSP * _Nonnull strings, float amount);
void strings_dsp_render(StringsDSP * _Nonnull strings, float * _Nonnull left,
                     float * _Nonnull right, uint32_t frames);

#endif
